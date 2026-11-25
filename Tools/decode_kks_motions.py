"""Convert KKS generic skeleton animation curves straight from the serialized bundles."""

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import struct
from zipfile import ZipFile
from zlib import crc32

import numpy as np
import UnityPy


IDENTITY = np.array([0, 0, 0, 1], dtype=np.float32)
FLOATS_PER_BINDING = {1: 3, 2: 4, 3: 3, 4: 3}


def rig_by_hash(game):
    bundle = UnityPy.load(str(game / "abdata/chara/oo_base.unity3d"))
    actor = next(value.read() for key, value in bundle.container.items() if key.endswith("/p_cf_body_bone.prefab"))
    root = next(c.component.read() for c in actor.m_Component if c.component.deref().type.name == "Transform")
    bones = {}

    def visit(transform, ancestry):
        name = transform.m_GameObject.read().m_Name
        levels = ancestry + [name]
        if name.startswith("cf_j_"):
            p, q = transform.m_LocalPosition, transform.m_LocalRotation
            rest = (name, np.array((p.x, p.y, p.z)), np.array((q.x, q.y, q.z, q.w)))
            for index in range(len(levels)):
                key = crc32("/".join(levels[index:]).encode())
                bones.setdefault(key, rest)
        for child in transform.m_Children:
            visit(child.read(), levels)

    visit(root, [])
    return bones


def multiply(a, b):
    xyz = a[..., 3:] * b[..., :3] + b[..., 3:] * a[..., :3] + np.cross(a[..., :3], b[..., :3])
    w = a[..., 3] * b[..., 3] - (a[..., :3] * b[..., :3]).sum(axis=-1)
    return np.concatenate((xyz, w[..., None]), axis=-1)


def euler_to_quaternion(angles):
    halves = np.radians(angles * 0.5)
    parts = []
    for axis in range(3):
        q = np.zeros((len(angles), 4), dtype=np.float32)
        q[:, axis] = np.sin(halves[:, axis])
        q[:, 3] = np.cos(halves[:, axis])
        parts.append(q)
    return multiply(multiply(parts[1], parts[0]), parts[2])


def streamed_keys(words, wanted):
    raw = memoryview(np.asarray(words, dtype="<u4")).cast("B")
    by_curve = defaultdict(list)
    offset = 0
    while offset < len(raw):
        at, count = struct.unpack_from("<fi", raw, offset)
        offset += 8
        size = 20 * count
        if count < 0 or offset + size > len(raw):
            raise ValueError("Invalid streamed animation key count")
        if math.isfinite(at):
            for index, a, b, c, d in struct.iter_unpack("<iffff", raw[offset:offset + size]):
                if index in wanted:
                    by_curve[index].append((at, a, b, c, d))
        offset += size
    return by_curve


def samples_for(clip, bindings, times):
    needed = {i for start, width in bindings for i in range(start, start + width)}
    curves = {}
    stream = clip.m_StreamedClip
    dense = clip.m_DenseClip
    stream_count, dense_count = stream.curveCount, dense.m_CurveCount
    if stream_count and any(i < stream_count for i in needed):
        entries = streamed_keys(stream.data, needed)
        for index, keys in entries.items():
            keys = np.asarray(keys)
            indices = np.searchsorted(keys[:, 0], times, side="right").clip(1, len(keys)) - 1
            key = keys[indices]
            elapsed = (times - key[:, 0]).clip(0, None)
            curves[index] = ((key[:, 1] * elapsed + key[:, 2]) * elapsed + key[:, 3]) * elapsed + key[:, 4]
    dense_indices = [i for i in needed if stream_count <= i < stream_count + dense_count]
    if dense_indices:
        values = np.asarray(dense.m_SampleArray, dtype=np.float32).reshape(dense.m_FrameCount, dense_count)
        fractional = ((times - dense.m_BeginTime) * dense.m_SampleRate).clip(0, dense.m_FrameCount - 1)
        frame = fractional.astype(int)
        following = np.minimum(frame + 1, dense.m_FrameCount - 1)
        weights = fractional - frame
        for index in dense_indices:
            column = index - stream_count
            curves[index] = values[frame, column] * (1 - weights) + values[following, column] * weights
    constants = clip.m_ConstantClip.data if clip.m_ConstantClip else []
    first_constant = stream_count + dense_count
    for index in needed:
        constant = index - first_constant
        if 0 <= constant < len(constants):
            curves[index] = np.full(len(times), constants[constant], dtype=np.float32)
    return curves


def decode(anim, rig, output):
    if not anim.m_MuscleClip or not anim.m_ClipBindingConstant:
        return "no generic binding"
    references = []
    offset = 0
    for bind in anim.m_ClipBindingConstant.genericBindings:
        width = FLOATS_PER_BINDING.get(bind.attribute, 1) if bind.typeID == 4 else 1
        if bind.typeID == 4 and bind.attribute in (1, 2, 4) and bind.path in rig:
            references.append((rig[bind.path], bind.attribute, offset, width))
        offset += width
    if not references:
        return "no compatible body tracks"
    duration = anim.m_MuscleClip.m_StopTime - anim.m_MuscleClip.m_StartTime
    if not 0 < duration < 3600:
        return "invalid duration"
    times = np.linspace(0, duration, min(1801, math.ceil(duration * 15) + 1))
    curves = samples_for(anim.m_MuscleClip.m_Clip.data, [(i, n) for _, _, i, n in references], times)
    slots = defaultdict(dict)
    for (bone, rest_position, rest_rotation), attr, begin, width in references:
        if not all(i in curves for i in range(begin, begin + width)):
            continue
        values = np.stack([curves[i] for i in range(begin, begin + width)], axis=1)
        if not np.isfinite(values).all():
            continue
        if attr == 1:
            values = values - rest_position
            if (np.square(values).sum(axis=1) > 0.000004).any():
                slots[bone]["position"] = values * (1, 1, -1)
        else:
            if attr == 4:
                values = euler_to_quaternion(values)
            values = multiply(rest_rotation * (-1, -1, -1, 1), values)
            norms = np.linalg.norm(values, axis=1, keepdims=True)
            values = values / np.maximum(0.000001, norms)
            values[norms[:, 0] < 0.000001] = IDENTITY
            if (np.abs(values[:, 3]) < 0.999999).any():
                slots[bone]["rotation"] = values * (-1, -1, 1, 1)
    if not slots:
        return "no compatible body tracks"
    partial = output.with_suffix(".decode-partial")
    with partial.open("wb") as stream:
        stream.write(struct.pack("<4sfII", b"KMA1", duration, len(times), len(slots)))
        for name, track in slots.items():
            key = name.encode()
            stream.write(struct.pack("<I", len(key)) + key)
            position = track.get("position")
            stream.write(b"\1" if position is not None else b"\0")
            q = track.get("rotation", np.broadcast_to(IDENTITY, (len(times), 4)))
            q = np.rint(q.clip(-1, 1) * 32767).astype("<i2")
            if position is None:
                stream.write(q.tobytes())
            else:
                packed = np.empty(len(times), dtype=[("q", "<i2", 4), ("p", "<f4", 3)])
                packed["q"], packed["p"] = q, position
                stream.write(packed.tobytes())
    partial.replace(output)
    return "converted"


def run(game, catalog, output, ids):
    rigs = rig_by_hash(game)
    output.mkdir(parents=True, exist_ok=True)
    rows = json.loads(catalog.read_text(encoding="utf-8"))["clips"]
    bundles = defaultdict(list)
    for row in rows:
        if (not ids or row["id"] in ids) and not (output / (row["id"] + ".kma")).is_file():
            bundles[(row["bundle"], row["archive"])].append(row)
    converted = 0
    with (output / "conversion-decoded.tsv").open("a", encoding="utf-8") as report:
        for (path, archive), members in bundles.items():
            try:
                if archive:
                    with ZipFile(game / archive) as zipped:
                        env = UnityPy.load(zipped.read(path))
                else:
                    env = UnityPy.load(str(game / path))
                objects = {str(obj.path_id): obj for obj in env.objects if obj.type.name == "AnimationClip"}
                for row in members:
                    clip_id = row["id"]
                    try:
                        result = decode(objects[row["object_id"]].read(), rigs, output / (clip_id + ".kma"))
                    except Exception as error:
                        result = str(error).replace("\n", " ")
                    converted += result == "converted"
                    report.write(f"{clip_id}\t{result}\n")
            except Exception as error:
                for row in members:
                    report.write(f"{row['id']}\t{str(error).replace(chr(10), ' ')}\n")
            report.flush()
            print(f"{converted} decoded · {path}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--id", action="append", default=[])
    args = parser.parse_args()
    run(args.game, args.catalog, args.output, set(args.id))
