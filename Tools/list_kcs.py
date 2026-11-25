"""List renderer names, vertex counts and material kinds in a KCS6 or KCS7 capture."""
import argparse
import struct
from pathlib import Path

MAGIC = 0x3653434B
NATIVE_LAYERS_MAGIC = 0x3753434B


class R:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.p)[0]
        self.p += 4
        return v

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def skip(self, n):
        self.p += n

    def text(self):
        n = self.i32()
        s = self.d[self.p:self.p + n].decode("utf-8", "replace")
        self.p += n
        return s

    def map(self):
        tid = self.i32()
        if tid < 0:
            return
        size = self.i32()
        if size > 0:
            self.skip(size)
        self.skip(16)  # uv


def load(path):
    raw = path.read_bytes()
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        size = struct.unpack_from("<Q", raw, len(raw) - 16)[0]
        raw = raw[len(raw) - 16 - size:len(raw) - 16]
    return raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", type=Path, nargs="+")
    args = ap.parse_args()
    for path in args.paths:
        r = R(load(path))
        magic = r.i32()
        if magic not in (MAGIC, NATIVE_LAYERS_MAGIC):
            raise SystemExit(f"{path.name}: not KCS6 or KCS7")
        bones = r.i32()
        for _ in range(bones):
            r.text()
            r.skip(4 + 12 + 16 + 12)
        renderers = r.i32()
        print(f"{path.name}: {bones} bones, {renderers} renderers")
        for _ in range(renderers):
            name = r.text()
            count = r.i32()
            r.skip(count * (12 + 12 + 8 + 16 + 16))
            native_layers = magic == NATIVE_LAYERS_MAGIC and r.u8() != 0
            if native_layers:
                r.skip(count * 26)
            sections = r.i32()
            kinds = []
            for _ in range(sections):
                kinds.append(r.u8())
                r.u8()  # opacity
                r.skip(4 + 4 + 4)  # queue cutoff extend
                r.skip(4 * 4 * 8)  # 8 colors
                for _m in range(6):
                    r.map()
                r.skip(8)  # body_mask_weights
                r.map()  # body_mask
                r.skip(4 * 7)  # 7 floats
                for _m in range(8):
                    r.map()
                if native_layers:
                    r.skip(16)
                n = r.i32()
                r.skip(n * 4)
            print(f"  {name}\tverts={count}\tkinds={kinds}")


if __name__ == "__main__":
    main()
