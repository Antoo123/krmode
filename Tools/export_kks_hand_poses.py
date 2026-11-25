"""Export finger rotations from the stock KKS HandCtrl item animation clips."""

import argparse
import json
from pathlib import Path
import re
from zlib import crc32

import numpy as np
import UnityPy

from decode_kks_motions import FLOATS_PER_BINDING, euler_to_quaternion, multiply, samples_for


CLIPS = {
    "chest": ("Te_muneM_sawari", "Te_muneM_D_momu4"),
    "lap": ("Te_kokan_sawari", "Te_kokan_D_kosuru4"),
    "seat": ("Te_siri_sawari", "Te_siri_C_momu"),
}
FINGER = re.compile(r"cf_j_(?:thumb|index|middle|ring|little)0[123]_[LR]")


def item_fingers(common):
    paths = {}
    for obj in common.objects:
        if obj.type.name != "Transform":
            continue
        transform = obj.read()
        name = transform.m_GameObject.read().m_Name
        if not FINGER.fullmatch(name):
            continue
        q = transform.m_LocalRotation
        rest = np.array((q.x, q.y, q.z, q.w))
        names = [name]
        while transform.m_Father and len(names) <= 14:
            transform = transform.m_Father.read()
            names.insert(0, transform.m_GameObject.read().m_Name)
        if not any(n.startswith("cf_j_handroot_") for n in names):
            continue
        for start, parent in enumerate(names):
            if parent.startswith("cf_j_handroot_"):
                path = "/".join(names[start:])
                paths[crc32(path.encode())] = (name, rest)
    return paths


def finger_pose(clip, rig):
    refs = []
    offset = 0
    for binding in clip.m_ClipBindingConstant.genericBindings:
        width = FLOATS_PER_BINDING.get(binding.attribute, 1) if binding.typeID == 4 else 1
        if binding.typeID == 4 and binding.attribute in (2, 4) and binding.path in rig:
            refs.append((rig[binding.path], binding.attribute, offset, width))
        offset += width
    stop = clip.m_MuscleClip.m_StopTime
    start = clip.m_MuscleClip.m_StartTime
    times = np.linspace(start, stop, 5)
    curves = samples_for(clip.m_MuscleClip.m_Clip.data, [(offset, width) for _, _, offset, width in refs], times)
    fingers = {}
    for (name, rest), attr, offset, width in refs:
        if not all(i in curves for i in range(offset, offset + width)):
            continue
        q = np.stack([curves[i] for i in range(offset, offset + width)], axis=1)
        if attr == 4:
            q = euler_to_quaternion(q)
        q = multiply(rest * (-1, -1, -1, 1), q)
        lengths = np.linalg.norm(q, axis=1, keepdims=True)
        if not np.isfinite(q).all() or (lengths < 1e-6).any():
            continue
        fingers[name] = ((q / lengths) * (-1, -1, 1, 1)).round(6).tolist()
    if len(fingers) != 15:
        raise ValueError(f"{clip.m_Name}: expected 15 finger tracks, found {len(fingers)}")
    return fingers


def export(game, output):
    bundle_path = "abdata/h/anim/parts/01_00.unity3d"
    keys = {f"{name}_{side}" for stem in CLIPS.values() for name in stem for side in ("L", "R")}
    source = UnityPy.load(str(game / bundle_path))
    rig = item_fingers(UnityPy.load(str(game / "abdata/h/common/01.unity3d")))
    clips = {}
    for obj in source.objects:
        if obj.type.name == "AnimationClip":
            clip = obj.read()
            if clip.m_Name in keys:
                clips[clip.m_Name] = finger_pose(clip, rig)
    if keys - clips.keys():
        raise ValueError(f"Missing KKS clips: {sorted(keys - clips.keys())}")
    profiles = {kind: {side: [clips[f"{name}_{side}"] for name in stems] for side in ("L", "R")}
                for kind, stems in CLIPS.items()}
    output.write_text(json.dumps({"bundle": bundle_path, "clips": CLIPS, "profiles": profiles}), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    export(args.game, args.output)
