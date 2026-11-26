"""Build the F7 reference index from AnimationInfo and the installed Unity controllers."""

import argparse
from collections import defaultdict
import csv
import gc
import json
from pathlib import Path

import UnityPy

from decode_kks_motions import rig_by_hash


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def posture(row, standing):
    raw = row["raw"]
    name = raw["nameAnimation"]
    categories = {entry["category"] for entry in raw["lstCategory"]}
    if (row["group"], raw["id"]) in standing or 8 in categories or "立ち" in name:
        return "Стоя"
    if "四つん這" in name or "四つんば" in name:
        return "На четвереньках"
    if any(word in name for word in ("座", "椅子", "しゃが", "胡坐")):
        return "Сидя / на корточках"
    if any(word in name for word in ("仰向", "うつ伏", "寝", "横臥")):
        return "Лёжа"
    if "机" in name or raw["useDesk"]:
        return "У стола"
    if "壁" in name:
        return "У стены"
    return f"Другая · posture {raw['posture']}"


class Controllers:
    def __init__(self, game, motions):
        self.game = game
        self.motion_ids = {(row["bundle"].lower(), int(row["object_id"])): row["id"]
                           for row in motions["clips"] if not row["archive"]}
        self.clips = {}
        self.rig = rig_by_hash(game)
        self.controllers = {}

    def prepare(self, rows):
        requests = defaultdict(dict)
        for entry in rows:
            raw = entry["raw"]
            for role in (("paramMale", "pathMaleBase"), ("paramFemale", "pathFemaleBase"),
                         ("paramSecondChar", "pathSecondChar")):
                variant, base = raw[role[0]]["path"], raw[role[1]]
                if not variant["file"]:
                    continue
                targets = [(variant, 0 if base["file"] else 1)] if variant["assetpath"].strip() else []
                if base["file"]:
                    targets.append((base, 2 if entry["group"] == 0 else 1))
                for path, mode in targets:
                    bucket = requests["abdata/" + path["assetpath"]]
                    bucket[path["file"]] = max(bucket.get(path["file"], 0), mode)
        for path, specs in requests.items():
            try:
                self.read_bundle(path, specs)
            except (OSError, ValueError) as error:
                for name in specs:
                    self.controllers[path, name] = str(error)
            gc.collect()
            print(f"Indexed {len(specs)} controllers in {path}", flush=True)

    def read_bundle(self, path, specs):
        source = self.game / path
        if not source.is_file():
            raise ValueError(f"Animation bundle is missing: {path}")
        env = UnityPy.load(str(source))
        items = {item.peek_name(): item for item in env.objects if item.type.name == "AnimatorController"}
        for name, mode in specs.items():
            try:
                self.controllers[path, name] = self.read_controller(path, name, items.get(name), mode)
            except (ValueError, KeyError, IndexError) as error:
                self.controllers[path, name] = str(error)

    def read_controller(self, path, name, item, mode):
        if item is None:
            raise ValueError(f"{path} · {name}: AnimatorController was not found")
        tree = item.read_typetree() if mode else {}
        pointers = [(clip["m_FileID"], clip["m_PathID"]) for clip in tree["m_AnimationClips"]] if mode else [
            (clip.m_FileID, clip.m_PathID) for clip in item.read().m_AnimationClips]
        object_refs = []
        names = defaultdict(set)
        for file_id, path_id in pointers:
            clip = item.assets_file.objects.get(path_id) if file_id == 0 else None
            if not clip or clip.type.name != "AnimationClip":
                object_refs.append(None)
                continue
            key = self.motion_ids.get((path.lower(), clip.path_id), f"{path}#{clip.path_id}")
            if key not in self.clips:
                self.clips[key] = {"name": clip.peek_name(), "bundle": path, "path_id": str(clip.path_id),
                                   "kma": self.motion_ids.get((path.lower(), clip.path_id), "")}
            clip_name = self.clips[key]["name"]
            object_refs.append((clip_name, key))
            names[clip_name].add(key)
        if not mode:
            return {}, dict(names)
        graph = tree["m_Controller"]
        strings = dict(tree["m_TOS"])
        layers = {}
        for index, layer in enumerate(graph["m_LayerArray"]):
            if index and mode < 2:
                break
            layer = layer["data"]
            machine = graph["m_StateMachineArray"][layer["m_StateMachineIndex"]]["data"]
            states = {}
            for state_index, state in enumerate(machine["m_StateConstantArray"]):
                state = state["data"]
                trees = state["m_BlendTreeConstantArray"]
                tree_ids = state["m_BlendTreeConstantIndexArray"]
                branch = layer["m_StateMachineSynchronizedLayerIndex"]
                if branch >= len(tree_ids) or not 0 <= tree_ids[branch] < len(trees):
                    continue
                nodes = trees[tree_ids[branch]]["data"]["m_NodeArray"]
                leaves = {}
                for node in nodes:
                    node = node["data"]
                    slot = node["m_ClipID"]
                    if not 0 <= slot < len(object_refs) or not object_refs[slot]:
                        continue
                    clip_name, key = object_refs[slot]
                    parameters = [state["m_Speed"], (state["m_CycleOffset"] + node["m_CycleOffset"]) % 1,
                                  bool(state["m_Loop"])]
                    if state["m_Mirror"] or node["m_Mirror"] or state["m_TimeParamID"]:
                        parameters.append("Mirror / Time Parameter")
                    leaves[clip_name] = [key, *parameters]
                if leaves:
                    state_name = strings.get(state["m_NameID"], str(state["m_NameID"]))
                    states[state_name] = {"clips": leaves, "default": state_index == machine["m_DefaultState"]}
            mask = layer["m_SkeletonMask"]["data"]["m_Data"]
            bones = sorted({self.rig[row["m_PathHash"]][0] for row in mask
                            if row["m_Weight"] > 0 and row["m_PathHash"] in self.rig})
            layers[index] = {"name": strings.get(layer["m_Binding"], str(index)), "states": states,
                             "mode": layer["(int&)m_LayerBlendingMode"],
                             "mask": bones}
        return layers, dict(names)

    def controller(self, path, name):
        result = self.controllers[path, name]
        if isinstance(result, str):
            raise ValueError(result)
        return result

    def resolve(self, path, base, green=False):
        variant_path = ("abdata/" + path["assetpath"], path["file"])
        if not variant_path[1]:
            return {}, []
        variants, replacements = self.controller(*variant_path) if path["assetpath"].strip() else ({}, {})
        base_layers, _ = self.controller("abdata/" + base["assetpath"], base["file"]) if base["file"] else (variants, {})
        states = {}
        extras = []
        for layer_id, layer in base_layers.items():
            options = []
            for state_name, state in layer["states"].items():
                for slot_name, leaf in state["clips"].items():
                    override_ids = replacements.get(slot_name, ())
                    if len(override_ids) > 1:
                        option = ["", *leaf[1:4], f"Ambiguous override {slot_name}"]
                    else:
                        option = [next(iter(override_ids)) if override_ids else leaf[0], *leaf[1:]]
                    if layer_id == 0:
                        states[(state_name, slot_name)] = option
                    elif state["default"]:
                        options.append(option[0])
            if layer_id and options and green:
                extras.append([layer_id, layer["name"], layer["mode"], layer["mask"], list(dict.fromkeys(options))])
        return states, extras


def generate(game, source, motion_catalog, output):
    reference = Controllers(game, load(motion_catalog))
    entries = load(source / "animation_registry_effective.json")
    reference.prepare(entries)
    with (source / "standing_paired.csv").open(encoding="utf-8-sig") as stream:
        standing = {(int(row["group"]), int(row["id"])) for row in csv.DictReader(stream)}
    with (source / "green_caress.csv").open(encoding="utf-8-sig") as stream:
        translations = {int(row["id"]): row["name_ru_green"] for row in csv.DictReader(stream)}
    rows = []
    for entry in entries:
        raw, group = entry["raw"], entry["group"]
        controllers = [raw["paramMale"]["path"], raw["paramFemale"]["path"], raw["paramSecondChar"]["path"]]
        bases = [raw["pathMaleBase"], raw["pathFemaleBase"], raw["pathSecondChar"]]
        roles = []
        extras = []
        issues = []
        for role, (path, base) in enumerate(zip(controllers, bases)):
            try:
                states, layers = reference.resolve(path, base, green=group == 0 and role == 1)
            except (OSError, ValueError, KeyError, IndexError) as error:
                states, layers = {}, []
                issues.append(str(error))
            roles.append(states)
            extras.extend(layers)
        keys = sorted(set().union(*roles))
        options = [[state, slot, *(tracks.get((state, slot), []) for tracks in roles)] for state, slot in keys]
        rows.append({
            "group": group, "id": raw["id"], "name": raw["nameAnimation"],
            "label": translations.get(raw["id"], "") if group == 0 else "",
            "posture": posture(entry, standing), "posture_id": raw["posture"],
            "paired": bool(controllers[0]["file"] and controllers[1]["file"]),
            "roles": controllers, "bases": bases, "options": options, "issues": issues,
            "categories": raw["lstCategory"],
            "prop": raw["paramFemale"]["fileItem"], "desk": bool(raw["useDesk"]),
            "chair": bool(raw["useChair"]), "permission": raw["paramFemale"]["fileAibuEnableMotion"],
            "layers": extras,
        })
    offsets = {row["preset"]: [[row[f"pos_{axis}"] for axis in "xyz"],
                               [row[f"rot_{axis}"] for axis in "xyz"]]
               for row in load(source / "move_offsets.json")}
    output.parent.mkdir(parents=True, exist_ok=True)
    # Layer definitions are shared by the 11 green rows.
    layer_sets = []
    for row in rows:
        layers = row.pop("layers")
        if layers:
            if layers not in layer_sets:
                layer_sets.append(layers)
            row["layer_set"] = layer_sets.index(layers)
    used = {slot[0] for row in rows for option in row["options"] for slot in option[2:] if slot and slot[0]}
    used.update(clip for layers in layer_sets for layer in layers for clip in layer[4] if clip)
    result = {"version": 1, "rows": rows, "clips": {key: clip for key, clip in reference.clips.items() if key in used}, "offsets": offsets,
              "layer_sets": layer_sets,
              "actions": load(source / "aibu_layers_effective.json"),
              "permissions": load(source / "aibu_motion_permissions.json"),
              "tools": load(source / "aibu_tools.json")}
    output.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"{len(rows)} records, {sum(row['paired'] for row in rows)} pairs, {len(used)} referenced clips")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("motion_catalog", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    generate(args.game, args.source, args.motion_catalog, args.output)
