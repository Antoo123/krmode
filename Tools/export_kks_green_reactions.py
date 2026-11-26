"""Export the local KKS green reaction tables and female FBS meshes for F7."""

import argparse
import gzip
import json
from pathlib import Path
import struct

import UnityPy
from UnityPy.helpers.MeshHelper import MeshHandler


def read_tables(game):
    tables = {}
    requested = {"AnimationInfo_00", "eyeneckbase", "breath_00_00", "shortbreath_00",
                 "personality_breath_c00", "personality_shortbreath_c00_00",
                 "HFaceList_c00_00_00"}
    prefixes = ("reaction_kha_", "neck_kha_f_", "aibuaction_kha_")
    for bundle in ("01", "71"):
        env = UnityPy.load(str(game / f"abdata/h/list/{bundle}.unity3d"))
        for item in env.objects:
            if item.type.name != "MonoBehaviour":
                continue
            name = item.peek_name() or ""
            if name in requested or name.startswith(prefixes):
                previous = tables.get(name, {})
                entries = item.read_typetree()["param"]
                tables[name] = {"bundle": bundle, "rows": entries, "previous": previous}
    return tables


def reaction_data(tables):
    def rows(name):
        return tables[name]["rows"]

    poses = {}
    for clip in rows("AnimationInfo_00"):
        female = clip["paramFemale"]
        reaction, neck = female["fileReaction"], female["fileMotionNeck"]
        permission = female["fileAibuEnableMotion"]
        poses[str(clip["id"])] = {
            "reaction": reaction,
            "neck": neck,
            "permission": permission,
            "reactions": {f"{r['anim']}/{r['areaID']}": r for r in rows(reaction)},
            "look": {r["anim"]: r for r in rows(neck)},
        }

    personality = next(row["data"] for row in rows("personality_breath_c00") if row["mode"] == 0)
    voice_faces = {v["id"]: v["info"][0]["lstFaceNormal"][0] for v in personality}
    # Use the first eligible choice for the ordinary (non-weak-point) c00 profile.
    # F7 does not play voices or emulate the random breath/short-voice scheduler.
    breath = {r["anim"]: voice_faces[r["lstInfo"][0]["lstVoice"][0]]
              for r in rows("breath_00_00")}
    short_faces = {r["id"]: r["infos"][0]["face"]
                   for r in rows("personality_shortbreath_c00_00")}
    short = {str(r["id"]): short_faces[r["lstInfo"][0]["lstVoice"][0]]
             for r in rows("shortbreath_00")}
    return {
        "poses": poses, "look": {str(r["id"]): r for r in rows("eyeneckbase")},
        "face_table": "HFaceList_c00_00_00",
        "faces": {str(r["id"]): r for r in rows("HFaceList_c00_00_00")},
        "breath": breath, "short": short,
        "sources": {name: t["bundle"] for name, t in tables.items()},
    }


def read_morphs(game):
    env = UnityPy.load(str(game / "abdata/chara/bo_head_00.unity3d"))
    renderers = {}
    for item in env.objects:
        if item.type.name != "MonoBehaviour":
            continue
        tree = item.read_typetree()
        if "EyesCtrl" not in tree or "MouthCtrl" not in tree:
            continue
        for name, channel in (("eye", "EyesCtrl"), ("mouth", "MouthCtrl"), ("eyebrow", "EyebrowCtrl")):
            for target in tree[channel]["FBSTarget"]:
                obj = item.assets_file.objects[target["ObjTarget"]["m_PathID"]].read()
                renderer = next(p.component.read() for p in obj.m_Component
                                if p.component.type.name == "SkinnedMeshRenderer")
                key = (obj.m_Name, renderer.m_Mesh.path_id)
                if key not in renderers:
                    renderers[key] = mesh_data(obj.m_Name, renderer)
                renderers[key]["patterns"][name] = [[p["Close"], p["Open"]] for p in target["PtnSet"]]
    return list(renderers.values())


def hit_effectors(game):
    scene = UnityPy.load(str(game / "KoikatsuSunshine_Data/level8"))
    scripts = UnityPy.load(str(game / "KoikatsuSunshine_Data/globalgamemanagers.assets"))
    main = scene.assets[0]
    data = main.objects[4454].get_raw_data()
    # The player scene strips type trees. These two HandCtrl components refer to
    # sibling copies of HitReaction. Verify the MonoScript and serialized layout.
    assert data[12:16] == b"\x01\x00\x00\x00"
    script_id, = struct.unpack_from("<q", data, 20)
    assert scripts.assets[0].objects[script_id].read().m_ClassName == "HitReaction"
    assert data == main.objects[4478].get_raw_data()
    cursor = 28

    def read(fmt):
        nonlocal cursor
        values = struct.unpack_from("<" + fmt, data, cursor)
        cursor += struct.calcsize("<" + fmt)
        return values[0] if len(values) == 1 else values

    def string():
        nonlocal cursor
        length = read("i")
        value = data[cursor:cursor + length].decode("utf-8")
        cursor = (cursor + length + 3) & ~3
        return value

    def curve():
        keys = [read("4fi2f") for _ in range(read("i"))]
        read("3i")  # pre/post wrap modes and rotation order
        return keys

    string()  # MonoBehaviour name
    read("fiq")  # overall weight and FullBodyBipedIK pointer
    result = {}
    for _ in range(read("i")):
        name, id_ = string(), read("i")
        points = []
        for _ in range(read("i")):
            label, fade = string(), read("f")
            drive, up = curve(), curve()
            links = [read("if") for _ in range(read("i"))]
            points.append({"name": label, "fade": fade, "force": drive, "up": up, "links": links})
        result[str(id_)] = {"name": name, "points": points}
    assert cursor == len(data) and len(result) == 12
    return result


def mesh_data(name, renderer):
    mesh = renderer.m_Mesh.read()
    stream = MeshHandler(mesh)
    stream.process()
    vertices = stream.m_VertexCount
    sample_ids = sorted({j * (vertices - 1) // 11 for j in range(12)})
    sample_uv = [[i, *stream.m_UV0[i][:2]] for i in sample_ids]
    shapes = []
    for channel in mesh.m_Shapes.channels:
        index = channel.frameIndex + channel.frameCount - 1
        frame = mesh.m_Shapes.shapes[index]
        scale = 100 / mesh.m_Shapes.fullWeights[index]
        sparse = []
        for entry in mesh.m_Shapes.vertices[frame.firstVertex:frame.firstVertex + frame.vertexCount]:
            pos = entry.vertex
            if max(abs(pos.x), abs(pos.y), abs(pos.z)) >= 1e-7:
                sparse.extend([entry.index, round(scale * pos.x, 7),
                               round(scale * pos.y, 7), round(-scale * pos.z, 7)])
        shapes.append([channel.name, sparse])
    bones = [joint.read().m_GameObject.read().m_Name for joint in renderer.m_Bones]
    # The Godot loader already reflects Z. Convert the native bind matrices likewise.
    binds = []
    for bone, pose in zip(bones, mesh.m_BindPose):
        plane = [1, 1, -1]
        binds.append([bone, *[round(getattr(pose, f"e{r}{c}") * plane[r] * plane[c], 7)
                             for c in range(3) for r in range(3)]])
    return {"name": name, "vertices": vertices, "uv": sample_uv, "shapes": shapes, "binds": binds,
            "indices": stream.m_BoneIndices, "weights": stream.m_BoneWeights, "patterns": {}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = reaction_data(read_tables(args.game))
    data["effectors"] = hit_effectors(args.game)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "reactions.json").write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")),
                                               encoding="utf-8")
    payload = json.dumps(read_morphs(args.game), separators=(",", ":")).encode("utf-8")
    (args.output / "face_morphs.json.gz").write_bytes(gzip.compress(payload, mtime=0))


if __name__ == "__main__":
    main()
