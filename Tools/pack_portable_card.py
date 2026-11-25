"""Package an existing PNG and its prepared KCS model as a self-contained PNG for KksRoom."""

import argparse
from pathlib import Path
import struct


def pack(card, model, output):
    png = card.read_bytes()
    actor = model.read_bytes()
    if not png.startswith(bytes.fromhex("89504e470d0a1a0a")):
        raise ValueError("The card must be a PNG")
    if not 4 <= len(actor) <= 134217728 or actor[:4] not in (b"KCS2", b"KCS3", b"KCS4", b"KCS5", b"KCS6", b"KCS7"):
        raise ValueError("Invalid or oversized prepared model")
    with output.open("xb") as stream:
        stream.write(png)
        stream.write(actor)
        stream.write(struct.pack("<Q8s", len(actor), b"KKSROOM1"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("card", type=Path)
    parser.add_argument("model", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    pack(options.card, options.model, options.output)
