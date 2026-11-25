"""Index H-scene controller pairs without relying on duplicate animation names alone."""

from collections import defaultdict
import argparse
import json
from pathlib import Path
import re
from zipfile import ZipFile

import UnityPy


def is_h_clip(bundle):
    key = "/" + bundle.replace("\\", "/").lower()
    return "/h/anim/" in key or "/anim_imports/" in key


def catalog_pairs(game, motion_catalog, output):
    catalog = json.loads(motion_catalog.read_text(encoding="utf-8"))["clips"]
    clips = [row for row in catalog if is_h_clip(row["bundle"])]
    by_bundle = defaultdict(dict)
    for row in clips:
        by_bundle[(row["archive"], row["bundle"])][int(row["object_id"])] = row["id"]
    states = defaultdict(lambda: [set(), set()])
    errors = []
    for (archive, bundle), by_id in by_bundle.items():
        if "/parts/" in bundle.lower():
            continue
        try:
            if archive:
                with ZipFile(game / archive) as source:
                    env = UnityPy.load(source.read(bundle))
            else:
                env = UnityPy.load(str(game / bundle))
            for item in env.objects:
                if item.type.name != "AnimatorController":
                    continue
                controller = item.read()
                name = controller.m_Name
                marker = re.search(r"_([mf])_", name, re.IGNORECASE)
                if marker is None:
                    continue
                role = 0 if marker.group(1).lower() == "m" else 1
                pair = name[:marker.start()] + "_" + name[marker.end():]
                for clip in controller.m_AnimationClips:
                    if clip.m_FileID != 0 or clip.m_PathID not in by_id:
                        continue
                    state = clip.deref().peek_name()
                    key = (archive or "", pair.lower(), state)
                    states[key][role].add(by_id[clip.m_PathID])
        except (OSError, ValueError, KeyError) as error:
            errors.append({"bundle": bundle, "archive": archive, "error": str(error)})
    pairs = []
    for (source, controller, state), (male, female) in sorted(states.items()):
        if len(male) == len(female) == 1:
            pairs.append({"name": f"{controller} | {state}", "source": source,
                          "male": next(iter(male)), "female": next(iter(female))})
    output.write_text(json.dumps({"pairs": pairs, "clips": clips, "errors": errors},
                                 ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(pairs)} controller pairs, {len(clips)} source clips, {len(errors)} bundle errors")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("motion_catalog", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    catalog_pairs(args.game, args.motion_catalog, args.output)
