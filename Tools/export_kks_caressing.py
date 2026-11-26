"""Resolve the original H-Caressing menu rows to Unity clips and Godot KMA."""

import argparse
import csv
import json
from pathlib import Path

import UnityPy

from decode_kks_motions import decode, rig_by_hash


STUDIO_INFO = "abdata/studio/info/00.unity3d"
STUDIO_BASE = "abdata/h/anim/female/00_01_00.unity3d"


def lists(env, name):
    obj = next(o for o in env.objects if o.type.name == "MonoBehaviour" and o.peek_name() == name)
    return obj.path_id, [r["list"] for r in obj.read_typetree()["list"] if r["list"][0].isdigit()]


class Sources:
    def __init__(self, game, project):
        self.game = game
        self.output = project / "KksPrototype/Content/F7/States"
        index = json.loads((project / "KksPrototype/Content/pair_catalog.json").read_text(encoding="utf-8"))
        self.ids = {(c["bundle"].lower(), str(c["object_id"])): c["id"] for c in index["clips"] if not c["archive"]}
        self.folders = [self.output, project / "Build/KKS/Motions", project / "KksPrototype/Content/Motions"]
        self.bundles = {}
        self.clips = {}
        self.rig = None

    def bundle(self, path):
        if path not in self.bundles:
            self.bundles[path] = UnityPy.load(str(self.game / path))
        return self.bundles[path]

    def controller(self, path, name):
        return next(o for o in self.bundle(path).objects
                    if o.type.name == "AnimatorController" and o.peek_name() == name)

    def leaves(self, base, variant, motion):
        tree = base.read_typetree()
        graph = tree["m_Controller"]
        strings = dict(tree["m_TOS"])
        layer = graph["m_LayerArray"][0]["data"]
        machine = graph["m_StateMachineArray"][layer["m_StateMachineIndex"]]["data"]
        base_refs = clip_refs(base)
        variants = {}
        for clip in clip_refs(variant):
            label = clip.peek_name()
            if label in variants and variants[label].path_id != clip.path_id:
                raise ValueError(f"Ambiguous override {variant.peek_name()}: {label}")
            variants[label] = clip
        values = {"height": 0.5, "motion": motion}
        out = {}
        for state in machine["m_StateConstantArray"]:
            state = state["data"]
            tree_index = state["m_BlendTreeConstantIndexArray"][layer["m_StateMachineSynchronizedLayerIndex"]]
            nodes = state["m_BlendTreeConstantArray"][tree_index]["data"]["m_NodeArray"]
            node = nodes[0]["data"]
            while node["m_ChildIndices"]:
                selector = strings[node["m_BlendEventID"]]
                thresholds = node["m_Blend1dData"]["data"]["m_ChildThresholdArray"]
                branch = thresholds.index(values[selector])
                node = nodes[node["m_ChildIndices"][branch]]["data"]
            clip = base_refs[node["m_ClipID"]]
            out[strings[state["m_NameID"]]] = (clip, variants.get(clip.peek_name()), state, node)
        return out

    def to_kma(self, obj, path):
        key = (path, str(obj.path_id))
        if key in self.clips:
            return self.clips[key]
        kma = self.ids.get(key, f"h_caress_{obj.path_id}")
        result = "available"
        if not any((folder / (kma + ".kma")).is_file() for folder in self.folders):
            if self.rig is None:
                self.rig = rig_by_hash(self.game)
            self.output.mkdir(parents=True, exist_ok=True)
            result = decode(obj.read(), self.rig, self.output / (kma + ".kma"))
            if result == "converted":
                result = "available"
        entry = {"clip": obj.peek_name(), "bundle": path, "path_id": key[1], "kma": kma,
                 "status": result}
        self.clips[key] = entry
        return entry

    def trace(self, base, variant, base_path, variant_path, motion, menu=None):
        output = {}
        for name, (slot, override, state, node) in self.leaves(base, variant, motion).items():
            if menu is not None and name not in menu:
                continue
            leaf = self.to_kma(override or slot, variant_path if override else base_path)
            output[name] = {**leaf, "slot": slot.peek_name(),
                            "speed": state["m_Speed"], "loop": bool(state["m_Loop"]),
                            "offset": (state["m_CycleOffset"] + node["m_CycleOffset"]) % 1}
        return output


def clip_refs(controller):
    output = []
    for ref in controller.read().m_AnimationClips:
        if ref.m_FileID:
            raise ValueError(f"External clip pointer in {controller.peek_name()}: {ref.m_PathID}")
        output.append(controller.assets_file.objects[ref.m_PathID])
    return output


def export(game, project, poses):
    sources = Sources(game, project)
    registry = json.loads((project / "kks_animation_catalog/animation_registry_effective.json").read_text(encoding="utf-8"))
    green = {e["raw"]["id"]: e["raw"] for e in registry if e["group"] == 0}
    studio = sources.bundle(STUDIO_INFO)
    category = dict(lists(studio, "AnimeCategory_00_01")[1])
    translation = game / "BepInEx/translation/ru/Text/Studio.txt"
    translated = dict(line.split("=", 1) for line in translation.read_text(encoding="utf-8-sig").splitlines()
                      if "=" in line and not line.startswith("//")) if translation.is_file() else {}
    output = {}
    studio_base = sources.controller(STUDIO_BASE, "kha_f_base")
    for pose_id in poses:
        raw = green[pose_id]
        key = str(100 + pose_id)
        table_name = f"HAnime_00_01_{key}"
        table_id, menu = lists(studio, table_name)
        by_state = {r[8]: r for r in menu}
        variant_path = "abdata/" + menu[0][6]
        variant = sources.controller(variant_path, menu[0][7])
        studio_clips = sources.trace(studio_base, variant, STUDIO_BASE, variant_path, 0, by_state)
        base_path = "abdata/" + raw["pathFemaleBase"]["assetpath"]
        game_variant_path = "abdata/" + raw["paramFemale"]["path"]["assetpath"]
        game_base = sources.controller(base_path, raw["pathFemaleBase"]["file"])
        game_variant = sources.controller(game_variant_path, raw["paramFemale"]["path"]["file"])
        game_clips = sources.trace(game_base, game_variant, base_path, game_variant_path, 0)
        loops = sources.trace(game_base, game_variant, base_path, game_variant_path, 1)
        options = []
        reference_menu = {r[8]: r for r in lists(studio, "HAnime_00_01_100")[1]}
        for name, clip in game_clips.items():
            row = by_state.get(name)
            original = row[3] if row else reference_menu[name][3]
            if row and row[4:8] != menu[0][4:8]:
                raise ValueError(f"Unexpected controller for {table_name}/{name}")
            options.append({"state": name, "japanese": original,
                            "label": "Idle" if name == "Idle" else translated.get(original, original),
                            "studio_number": int(row[0]) if row else None, "studio": studio_clips[name] if row else None,
                            "game": clip, "hold": loops[name] if loops[name] != clip else None})
        options.sort(key=lambda row: int(reference_menu[row["state"]][0]))
        output[str(pose_id)] = {"position": translated.get(category[key], category[key]) if pose_id else "Standing",
                                "japanese": category[key], "id": pose_id, "menu": table_name, "menu_path_id": str(table_id),
                                "studio_base": STUDIO_BASE, "studio_override": variant_path,
                                "studio_controller_path_id": str(variant.path_id),
                                "game_base": base_path, "game_override": game_variant_path,
                                "controller": game_variant.peek_name(), "states": options}
    path = project / "KksPrototype/Content/F7/h_caressing.json"
    path.write_text(json.dumps({"studio_info": STUDIO_INFO, "reference_parameters": {"height": 0.5, "motion": 0},
                                "positions": output}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if len(output) == 11:
        with (project / "kks_animation_catalog/h_caressing.csv").open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["position_id", "position", "menu", "controller", "studio_label", "japanese",
                             "state", "source", "clip", "bundle", "path_id", "kma", "status"])
            for position in output.values():
                for entry in position["states"]:
                    for origin in ("studio", "game", "hold"):
                        clip = entry[origin]
                        if clip:
                            writer.writerow([position["id"], position["position"], position["menu"],
                                             position["controller"], entry["label"], entry["japanese"],
                                             entry["state"], origin, clip["clip"], clip["bundle"],
                                             clip["path_id"], clip["kma"] + ".kma", clip["status"]])
    print(f"{sum(len(row['states']) for row in output.values())} states, {len(sources.clips)} unique clip references")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("--standing", action="store_true")
    args = parser.parse_args()
    export(args.game, args.project, [0] if args.standing else range(11))
