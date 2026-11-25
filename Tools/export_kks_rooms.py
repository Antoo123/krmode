"""Batch-export Koikatsu Sunshine studio rooms to self-contained GLB for KksRoom.

Reimplements the JapaneseStyleRoom GLB writer with resilience to missing
"unity default resources" references and optional shared texture/material
bundles (the ``CAB-*`` bundles KksRoom's map loader resolves at runtime).

Usage (from Myproject):
    python ./Tools/export_kks_rooms.py <game> ./Build/KKS/Rooms
    python ./Tools/export_kks_rooms.py <game> <out> --map backyard
    python ./Tools/export_kks_rooms.py <game> <out> --list
"""

import argparse
import io
import json
import struct
from pathlib import Path

import UnityPy
from UnityPy.helpers.MeshHelper import MeshHandler

STUDIO_MAP_DIR = "studio/map"
GAME_SCENE_DIR = "map/scene"

# Shared bundles that room materials reference through CAB-* external file names.
SHARED_STUDIO = [
    "studio/map/00/tex.unity3d",
    "studio/map/materials/00.unity3d",
    "studio/map/common/00.unity3d",
    "map/common/00.unity3d",
    "map/materials/00.unity3d",
    "map/object/00.unity3d",
]


class Glb:
    def __init__(self):
        self.data = bytearray()
        self.doc = {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": []}],
            **{name: [] for name in
               ("nodes", "meshes", "materials", "textures", "images", "accessors", "bufferViews")},
        }
        self.material_ids = {}
        self.texture_ids = {}

    @staticmethod
    def _key(reader):
        # path_id alone collides across SerializedFiles; key on file name + path id.
        af = getattr(reader, "assets_file", None)
        return (getattr(af, "name", None), reader.path_id)

    def add(self, kind, entry):
        items = self.doc[kind]
        items.append(entry)
        return len(items) - 1

    def buffer(self, data):
        self.data.extend(b"\0" * (-len(self.data) % 4))
        offset = len(self.data)
        self.data.extend(data)
        return self.add("bufferViews", {"buffer": 0, "byteOffset": offset, "byteLength": len(data)})

    def vectors(self, vectors, dimensions, bounds=False):
        data = b"".join(struct.pack("<" + "f" * dimensions, *v[:dimensions]) for v in vectors)
        accessor = {
            "bufferView": self.buffer(data), "componentType": 5126, "count": len(vectors),
            "type": f"VEC{dimensions}",
        }
        if bounds:
            accessor["min"] = [min(v[i] for v in vectors) for i in range(dimensions)]
            accessor["max"] = [max(v[i] for v in vectors) for i in range(dimensions)]
        return self.add("accessors", accessor)

    def texture(self, pointer):
        try:
            reader = pointer.deref()
        except Exception:
            return -1
        key = self._key(reader)
        if key not in self.texture_ids:
            try:
                texture = reader.read()
                stream = io.BytesIO()
                texture.image.save(stream, "PNG")
            except Exception:
                return -1
            image = self.add("images", {
                "name": getattr(texture, "m_Name", "tex"), "bufferView": self.buffer(stream.getvalue()),
                "mimeType": "image/png",
            })
            self.texture_ids[key] = self.add("textures", {"source": image})
        return self.texture_ids.get(key, -1)

    def normal_texture(self, pointer):
        from PIL import Image, ImageChops
        try:
            reader = pointer.deref()
        except Exception:
            return -1
        key = ("normal",) + self._key(reader)
        if key not in self.texture_ids:
            try:
                texture = reader.read()
                r, g, _, a = texture.image.convert("RGBA").split()
                image = Image.merge("RGB", (ImageChops.multiply(r, a), ImageChops.invert(g),
                                            Image.new("L", r.size, 255)))
                stream = io.BytesIO()
                image.save(stream, "PNG")
            except Exception:
                return -1
            index = self.add("images", {"name": "normal", "bufferView": self.buffer(stream.getvalue()),
                                        "mimeType": "image/png"})
            self.texture_ids[key] = self.add("textures", {"source": index})
        return self.texture_ids.get(key, -1)

    def material(self, pointer):
        try:
            reader = pointer.deref()
        except Exception:
            return -1
        key = self._key(reader)
        if key not in self.material_ids:
            try:
                source = reader.read()
                properties = source.m_SavedProperties
                color = dict(properties.m_Colors).get("_Color")
                maps = dict(properties.m_TexEnvs)
                main = maps.get("_MainTex")
                mode = dict(properties.m_Floats).get("_Mode", 0)
            except Exception:
                self.material_ids[key] = -1
                return -1
            pbr = {"metallicFactor": 0, "roughnessFactor": 0.85}
            if color:
                pbr["baseColorFactor"] = [color.r, color.g, color.b, color.a]
            if main and main.m_Texture:
                idx = self.texture(main.m_Texture)
                if idx >= 0:
                    pbr["baseColorTexture"] = {"index": idx}
            material = {"name": getattr(source, "m_Name", "mat"), "pbrMetallicRoughness": pbr,
                        "doubleSided": True}
            bump = maps.get("_BumpMap")
            if bump and bump.m_Texture:
                idx = self.normal_texture(bump.m_Texture)
                if idx >= 0:
                    material["normalTexture"] = {"index": idx,
                                                 "scale": dict(properties.m_Floats).get("_BumpScale", 1)}
            glow = maps.get("_EmissionMap")
            if glow and glow.m_Texture:
                idx = self.texture(glow.m_Texture)
                if idx >= 0:
                    material["emissiveTexture"] = {"index": idx}
                    tint = dict(properties.m_Colors).get("_EmissionColor")
                    material["emissiveFactor"] = [min(1, v) for v in (tint.r, tint.g, tint.b)] if tint else [1, 1, 1]
            if mode == 1:
                material["alphaMode"] = "MASK"
                material["alphaCutoff"] = dict(properties.m_Floats).get("_Cutoff", 0.5)
            elif mode >= 2 or "_alfa" in str(getattr(source, "m_Name", "")):
                material["alphaMode"] = "BLEND"
            self.material_ids[key] = self.add("materials", material)
        return self.material_ids.get(key, -1)

    def mesh(self, source, slots, lightmap_transform):
        try:
            mesh = MeshHandler(source)
            mesh.process()
        except Exception:
            return -1
        points = [(x, y, -z) for x, y, z, *_ in mesh.m_Vertices]
        normals = [(x, y, -z) for x, y, z, *_ in mesh.m_Normals]
        uv = [(u, 1 - v) for u, v, *_ in mesh.m_UV0]
        attributes = {
            "POSITION": self.vectors(points, 3, bounds=True),
            "NORMAL": self.vectors(normals, 3),
            "TEXCOORD_0": self.vectors(uv, 2),
        }
        if lightmap_transform and len(mesh.m_UV1 or []) == len(points):
            st = lightmap_transform
            attributes["TEXCOORD_1"] = self.vectors(
                [(u * st.x + st.z, 1 - (v * st.y + st.w)) for u, v, *_ in mesh.m_UV1], 2)
        primitives = []
        for i, triangles in enumerate(mesh.get_triangles()):
            if not triangles:
                continue
            flip = winding_score(triangles, points, normals) < 0
            indices = b"".join(struct.pack("<III", a, c, b) if flip else struct.pack("<III", a, b, c)
                               for a, b, c in triangles)
            accessor = self.add("accessors", {
                "bufferView": self.buffer(indices), "componentType": 5125, "count": len(triangles) * 3,
                "type": "SCALAR",
            })
            primitive = {"attributes": attributes, "indices": accessor}
            if i < len(slots) and slots[i]:
                mid = self.material(slots[i])
                if mid >= 0:
                    primitive["material"] = mid
            primitives.append(primitive)
        return self.add("meshes", {"name": getattr(source, "m_Name", "mesh"), "primitives": primitives})

    def save(self, path):
        self.data.extend(b"\0" * (-len(self.data) % 4))
        self.doc["buffers"] = [{"byteLength": len(self.data)}]
        header = json.dumps(self.doc, separators=(",", ":")).encode()
        header += b" " * (-len(header) % 4)
        with path.open("wb") as file:
            file.write(struct.pack("<4sII", b"glTF", 2, 28 + len(header) + len(self.data)))
            file.write(struct.pack("<I4s", len(header), b"JSON"))
            file.write(header)
            file.write(struct.pack("<I4s", len(self.data), b"BIN\0"))
            file.write(self.data)


def winding_score(triangles, points, normals):
    score = 0.0
    for a, b, c in triangles[:32]:
        u = [points[b][i] - points[a][i] for i in range(3)]
        v = [points[c][i] - points[a][i] for i in range(3)]
        cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        score += sum(cross[i] * normals[a][i] for i in range(3))
    return score


def export_node(room, transform):
    try:
        actor = transform.m_GameObject.read()
    except Exception:
        actor = None
    name = getattr(actor, "m_Name", "node") if actor else "node"
    try:
        t, r, s = transform.m_LocalPosition, transform.m_LocalRotation, transform.m_LocalScale
        node = {
            "name": name, "translation": [t.x, t.y, -t.z],
            "rotation": [-r.x, -r.y, r.z, r.w], "scale": [s.x, s.y, s.z],
        }
    except Exception:
        node = {"name": name}
    if actor is not None:
        try:
            components = {c.component.deref().type.name: c.component for c in actor.m_Component}
        except Exception:
            components = {}
        if "MeshFilter" in components and "MeshRenderer" in components:
            try:
                renderer = components["MeshRenderer"].read()
                mesh = components["MeshFilter"].read().m_Mesh
                if renderer.m_Enabled and mesh:
                    st = renderer.m_LightmapTilingOffset if renderer.m_LightmapIndex == 0 else None
                    mid = room.mesh(mesh.read(), renderer.m_Materials, st)
                    if mid >= 0:
                        node["mesh"] = mid
            except Exception:
                pass
    node_id = room.add("nodes", node)
    children = getattr(transform, "m_Children", None)
    if children:
        resolved = []
        for child in children:
            try:
                resolved.append(export_node(room, child.read()))
            except Exception:
                continue
        if resolved:
            node["children"] = resolved
    return node_id


def export_env(env, output_glb, map_af=None):
    """Export the map bundle's own scene graph into ``output_glb``.

    ``map_af`` is the exact ``SerializedFile.name`` of the map bundle
    (e.g. ``BuildPlayer-Backyard.sharedAssets``). Shared bundles loaded
    alongside it only contribute materials/textures; their Transforms are
    skipped so their prefab/furniture content is not dumped as the room.
    """
    room = Glb()
    for item in env.objects:
        if item.type.name != "Transform":
            continue
        if map_af is not None and item.assets_file.name != map_af:
            continue
        try:
            transform = item.read()
        except Exception:
            continue
        if not transform.m_Father:
            room.doc["scenes"][0]["nodes"].append(export_node(room, transform))
    if not room.doc["meshes"]:
        return {"meshes": 0, "textures": 0, "lightmaps": 0}, "no meshes"
    lightmaps = 0
    for item in env.objects:
        if item.type.name == "LightmapSettings":
            if map_af is not None and item.assets_file.name != map_af:
                continue
            try:
                settings = item.read()
                baked = settings.m_Lightmaps[0]
                if baked is not None and baked.m_Lightmap is not None:
                    baked.m_Lightmap.read().image.save(output_glb.with_name(output_glb.stem + "_baked.png"))
                    lightmaps += 1
                    try:
                        d = baked.m_DirLightmap
                        if d is not None:
                            d.read().image.save(output_glb.with_name(output_glb.stem + "_direction.png"))
                    except Exception:
                        pass
            except Exception:
                pass
            break
    output_glb.parent.mkdir(parents=True, exist_ok=True)
    room.save(output_glb)
    return {"meshes": len(room.doc["meshes"]), "textures": len(room.doc["textures"]),
            "lightmaps": lightmaps}, None


def discover_maps(game, include_scenes):
    found = []
    base = game / "abdata" / STUDIO_MAP_DIR
    if base.is_dir():
        for path in sorted(base.glob("*.unity3d")):
            if path.name.endswith("tex.unity3d"):
                continue
            found.append(("studio", path.stem, f"abdata/{STUDIO_MAP_DIR}/{path.name}"))
    if include_scenes:
        base = game / "abdata" / GAME_SCENE_DIR
        if base.is_dir():
            for path in sorted(base.glob("*.unity3d")):
                found.append(("scene", path.stem, f"abdata/{GAME_SCENE_DIR}/{path.name}"))
    return found


def load_shared_env(game, shared):
    """Load the shared CAB-* bundles once into a reusable environment."""
    paths = []
    for s in shared:
        sp = game / "abdata" / s
        if sp.exists():
            paths.append(str(sp))
    return UnityPy.load(*paths) if paths else None


def export_map(game, map_rel, output, shared_env):
    # map_rel is already relative to <game> (e.g. "abdata/studio/map/backyard.unity3d").
    map_path = game / map_rel
    # Each map bundle has two SerializedFiles: "<Name>" (the scene graph with
    # MeshRenderers) and "<Name>.sharedAssets" (shared mesh/material assets, no
    # renderers). The scene lives in the non-".sharedAssets" file; probe the cheap
    # single-bundle load to pick it reliably (shared files are named CAB-*).
    probe = UnityPy.load(str(map_path))
    map_af = next((n for n in {item.assets_file.name for item in probe.objects}
                   if not n.endswith(".sharedAssets")), None)
    if shared_env is None:
        env = probe
    else:
        # Add the map to the already-loaded shared environment so external CAB-*
        # texture/material references resolve without re-parsing the multi-GB
        # shared bundles per map.
        env = shared_env
        env.load_file(str(map_path))
    info, error = export_env(env, output / (map_path.stem + ".glb"), map_af)
    return map_path.stem, info, error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--map", help="Export a single map by bundle name (without .unity3d).")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--scenes", action="store_true", help="Include main-game scene maps.")
    args = parser.parse_args()

    maps = discover_maps(args.game, args.scenes)
    if args.list:
        for kind, name, rel in maps:
            print(f"{kind}\t{name}")
        return
    target = [m for m in maps if m[1] == args.map] if args.map else maps
    if args.map and not target:
        raise SystemExit(f"Map not found: {args.map}")

    args.output.mkdir(parents=True, exist_ok=True)
    shared_env = load_shared_env(args.game, SHARED_STUDIO)
    if shared_env is not None:
        print(f"shared bundles loaded: {len(shared_env.files)} files")
    ok = 0
    for kind, name, rel in target:
        try:
            name_out, info, error = export_map(args.game, rel, args.output, shared_env)
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL\t{name}\t{exc}")
            continue
        if error:
            print(f"FAIL\t{name}\t{error}")
        else:
            print(f"OK\t{name}\t{info}")
            ok += 1
    print(f"exported={ok}/{len(target)}")


if __name__ == "__main__":
    main()