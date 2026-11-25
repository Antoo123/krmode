"""Dump the embedded PNG textures of a KKS .kcs character capture to PNG files.

Reads KCS6 and KCS7 (card_model.gd / KksCardCapture.cs) and writes
<renderer>__<slot>[_<n>].png next to the input, so the material's base_map,
overlays and masks can be inspected directly.
"""
import argparse
import struct
from pathlib import Path

MAGIC = 0x3653434B
NATIVE_LAYERS_MAGIC = 0x3753434B

SLOTS = ["base_map", "color_mask", "gloss_map", "overlay1_map", "overlay2_map",
         "overlay3_map", "body_mask", "normal", "detail_normal", "surface_detail",
         "line", "face_normal", "ramp", "wet_mask", "wet_detail"]


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def i32(self):
        v = struct.unpack_from("<i", self.data, self.pos)[0]
        self.pos += 4
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.data, self.pos)[0]
        self.pos += 4
        return v

    def u8(self):
        v = self.data[self.pos]
        self.pos += 1
        return v

    def skip(self, n):
        self.pos += n

    def text(self):
        n = self.i32()
        s = self.data[self.pos:self.pos + n].decode("utf-8", "replace")
        self.pos += n
        return s


def read_map(r: Reader, sunk, slot, renderer):
    tid = r.i32()
    if tid < 0:
        return
    size = r.i32()
    if size > 0:
        png = r.data[r.pos:r.pos + size]
        r.pos += size
    else:
        png = None
    uv = struct.unpack_from("<4f", r.data, r.pos)
    r.pos += 16
    if png is not None:
        sunk.setdefault(tid, (slot, renderer, png))


def dump(path: Path, out: Path):
    data = path.read_bytes()
    r = Reader(data)
    magic = r.i32()
    if magic not in (MAGIC, NATIVE_LAYERS_MAGIC):
        raise SystemExit(f"{path}: not a KCS6 or KCS7 capture")
    bones = r.i32()
    for _ in range(bones):
        r.text()
        r.skip(4 + 12 + 16 + 12)
    renderers = r.i32()
    sunk = {}
    renderer_names = []
    want_tex = {}
    for _ in range(renderers):
        name = r.text()
        renderer_names.append(name)
        count = r.i32()
        r.skip(count * (12 + 12 + 8 + 16 + 16))
        native_layers = magic == NATIVE_LAYERS_MAGIC and r.u8() != 0
        if native_layers:
            r.skip(count * 26)
        sections = r.i32()
        for _ in range(sections):
            r.u8()  # kind
            r.u8()  # opacity
            r.skip(4)  # queue
            r.skip(4)  # cutoff
            r.skip(4)  # extend
            r.skip(4 * 4 * 8)  # base + 7 tint colors (8 colors x 4 floats)
            read_map(r, sunk, "base_map", name)
            read_map(r, sunk, "color_mask", name)
            read_map(r, sunk, "gloss_map", name)
            for i in range(1, 4):
                read_map(r, sunk, f"overlay{i}_map", name)
            r.skip(8)  # body_mask_weights (2 floats)
            read_map(r, sunk, "body_mask", name)
            r.skip(4 * 7)  # 7 floats
            for s in ["normal", "detail_normal", "surface_detail", "line",
                      "face_normal", "ramp", "wet_mask", "wet_detail"]:
                read_map(r, sunk, s, name)
            if native_layers:
                r.skip(16)
            indices = r.i32()
            r.skip(indices * 4)
    out.mkdir(parents=True, exist_ok=True)
    print(f"{path.name}: {len(renderer_names)} renderers, {len(sunk)} textures")
    for tid, (slot, renderer, png) in sorted(sunk.items()):
        safe = "".join(c if c.isalnum() or c in "_-" else "_" for c in renderer)
        out_path = out / f"{safe}__{slot}.png"
        out_path.write_bytes(png)
        print(f"  [{tid}] {renderer} :: {slot} -> {out_path.name} ({len(png)} bytes)")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("kcs", type=Path)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    dump(args.kcs, args.out or args.kcs.with_name(args.kcs.stem + "_tex"))


if __name__ == "__main__":
    main()
