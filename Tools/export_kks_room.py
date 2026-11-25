"""Copy the JapaneseStyleRoom mesh hierarchy and textures from a local KKS install to GLB."""

import argparse
import io
import json
from pathlib import Path
import struct

import UnityPy
from UnityPy.helpers.MeshHelper import MeshHandler


MAP = "abdata/studio/map/japanesestyleroom.unity3d"
TEXTURES = "abdata/studio/map/00/tex.unity3d"


class Glb:
    def __init__(self):
        self.data = bytearray()
        self.doc = {
            "asset": {"version": "2.0", "extras": {"source": MAP, "textures": TEXTURES}},
            "scene": 0,
            "scenes": [{"nodes": []}],
            **{name: [] for name in ("nodes", "meshes", "materials", "textures", "images", "accessors", "bufferViews")},
        }
        self.material_ids = {}
        self.texture_ids = {}

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
            "bufferView": self.buffer(data), "componentType": 5126, "count": len(vectors), "type": f"VEC{dimensions}"
        }
        if bounds:
            accessor["min"] = [min(v[i] for v in vectors) for i in range(dimensions)]
            accessor["max"] = [max(v[i] for v in vectors) for i in range(dimensions)]
        return self.add("accessors", accessor)

    def texture(self, pointer):
        reader = pointer.deref()
        if reader.path_id not in self.texture_ids:
            texture = reader.read()
            stream = io.BytesIO()
            texture.image.save(stream, "PNG")
            image = self.add("images", {
                "name": texture.m_Name, "bufferView": self.buffer(stream.getvalue()), "mimeType": "image/png"
            })
            self.texture_ids[reader.path_id] = self.add("textures", {"source": image})
        return self.texture_ids[reader.path_id]

    def material(self, pointer):
        reader = pointer.deref()
        if reader.path_id not in self.material_ids:
            source = reader.read()
            properties = source.m_SavedProperties
            color = dict(properties.m_Colors).get("_Color")
            maps = dict(properties.m_TexEnvs)
            main = maps.get("_MainTex")
            mode = dict(properties.m_Floats).get("_Mode", 0)
            pbr = {"metallicFactor": 0, "roughnessFactor": 0.85}
            if color:
                pbr["baseColorFactor"] = [color.r, color.g, color.b, color.a]
            if main and main.m_Texture:
                pbr["baseColorTexture"] = {"index": self.texture(main.m_Texture)}
            material = {"name": source.m_Name, "pbrMetallicRoughness": pbr, "doubleSided": True}
            bump = maps.get("_BumpMap")
            if bump and bump.m_Texture:
                material["normalTexture"] = {"index": self.normal_texture(bump.m_Texture),
                                             "scale": dict(properties.m_Floats).get("_BumpScale", 1)}
            glow = maps.get("_EmissionMap")
            if glow and glow.m_Texture:
                material["emissiveTexture"] = {"index": self.texture(glow.m_Texture)}
                tint = dict(properties.m_Colors).get("_EmissionColor")
                material["emissiveFactor"] = [min(1, v) for v in (tint.r, tint.g, tint.b)] if tint else [1, 1, 1]
            if mode == 1:
                material["alphaMode"] = "MASK"
                material["alphaCutoff"] = dict(properties.m_Floats).get("_Cutoff", 0.5)
            elif mode >= 2 or "_alfa" in source.m_Name:
                material["alphaMode"] = "BLEND"
            self.material_ids[reader.path_id] = self.add("materials", material)
        return self.material_ids[reader.path_id]

    def normal_texture(self, pointer):
        from PIL import Image, ImageChops
        reader = pointer.deref()
        key = ("normal", reader.path_id)
        if key not in self.texture_ids:
            texture = reader.read()
            r, g, _, a = texture.image.convert("RGBA").split()
            image = Image.merge("RGB", (ImageChops.multiply(r, a), ImageChops.invert(g), Image.new("L", r.size, 255)))
            stream = io.BytesIO()
            image.save(stream, "PNG")
            index = self.add("images", {"name": texture.m_Name, "bufferView": self.buffer(stream.getvalue()), "mimeType": "image/png"})
            self.texture_ids[key] = self.add("textures", {"source": index})
        return self.texture_ids[key]

    def mesh(self, source, slots, lightmap_transform):
        mesh = MeshHandler(source)
        mesh.process()
        points = [(x, y, -z) for x, y, z, *_ in mesh.m_Vertices]
        normals = [(x, y, -z) for x, y, z, *_ in mesh.m_Normals]
        uv = [(u, 1 - v) for u, v, *_ in mesh.m_UV0]
        attributes = {
            "POSITION": self.vectors(points, 3, bounds=True),
            "NORMAL": self.vectors(normals, 3),
            "TEXCOORD_0": self.vectors(uv, 2)
        }
        if lightmap_transform and len(mesh.m_UV1 or []) == len(points):
            st = lightmap_transform
            attributes["TEXCOORD_1"] = self.vectors(
                [(u * st.x + st.z, 1 - (v * st.y + st.w)) for u, v, *_ in mesh.m_UV1], 2)
        primitives = []
        for i, triangles in enumerate(mesh.get_triangles()):
            if not triangles:
                continue
            # Reflect the Unity axis, then preserve the orientation encoded by the source normals.
            flip = winding_score(triangles, points, normals) < 0
            indices = b"".join(struct.pack("<III", a, c, b) if flip else struct.pack("<III", a, b, c)
                               for a, b, c in triangles)
            accessor = self.add("accessors", {
                "bufferView": self.buffer(indices), "componentType": 5125, "count": len(triangles) * 3, "type": "SCALAR"
            })
            primitive = {"attributes": attributes, "indices": accessor}
            if i < len(slots) and slots[i]:
                primitive["material"] = self.material(slots[i])
            primitives.append(primitive)
        return self.add("meshes", {"name": source.m_Name, "primitives": primitives})

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


def export_room(game, output):
    assets = UnityPy.load(str(game / MAP), str(game / TEXTURES))
    room = Glb()
    scene_files = {item.assets_file for item in assets.objects if item.type.name == "MeshRenderer"}
    for item in assets.objects:
        if item.type.name != "Transform" or item.assets_file not in scene_files:
            continue
        transform = item.read()
        if not transform.m_Father:
            room.doc["scenes"][0]["nodes"].append(export_node(room, transform))
    if not room.doc["meshes"] or not room.doc["textures"]:
        raise ValueError("Room geometry or textures were not resolved")
    output.parent.mkdir(parents=True, exist_ok=True)
    settings = next(item.read() for item in assets.objects if item.type.name == "LightmapSettings")
    baked = settings.m_Lightmaps[0]
    baked.m_Lightmap.read().image.save(output.with_name(output.stem + "_baked.png"))
    baked.m_DirLightmap.read().image.save(output.with_name(output.stem + "_direction.png"))
    room.save(output)
    print(f"JapaneseStyleRoom: {len(room.doc['meshes'])} meshes, {len(room.doc['textures'])} original textures")


def export_node(room, transform):
    actor = transform.m_GameObject.read()
    t, r, s = transform.m_LocalPosition, transform.m_LocalRotation, transform.m_LocalScale
    node = {
        "name": actor.m_Name, "translation": [t.x, t.y, -t.z],
        "rotation": [-r.x, -r.y, r.z, r.w], "scale": [s.x, s.y, s.z]
    }
    components = {c.component.deref().type.name: c.component for c in actor.m_Component}
    if "MeshFilter" in components and "MeshRenderer" in components:
        renderer = components["MeshRenderer"].read()
        mesh = components["MeshFilter"].read().m_Mesh
        if renderer.m_Enabled and mesh:
            st = renderer.m_LightmapTilingOffset if renderer.m_LightmapIndex == 0 else None
            node["mesh"] = room.mesh(mesh.read(), renderer.m_Materials, st)
    node_id = room.add("nodes", node)
    if transform.m_Children:
        node["children"] = [export_node(room, child.read()) for child in transform.m_Children]
    return node_id


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    export_room(args.game, args.output)
