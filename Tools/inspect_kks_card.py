"""Read the KKS PNG trailer and export a small subset of character metadata."""

import argparse
import json
from pathlib import Path
import struct

import msgpack


PNG_SIGNATURE = bytes.fromhex("89504e470d0a1a0a")
KKS_MARKER = "【KoiKatuCharaSun】"
PARAMETERS = ("sex", "lastname", "firstname", "nickname", "personality", "voiceRate")
MAX_CARD_BYTES = 64 * 1024 * 1024


class CardReader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def read(self, size: int) -> bytes:
        end = self.offset + size
        if size < 0 or end > len(self.data):
            raise ValueError("Truncated card or invalid block size")
        result = self.data[self.offset:end]
        self.offset = end
        return result

    def unpack(self, fmt: str) -> tuple:
        return struct.unpack(fmt, self.read(struct.calcsize(fmt)))

    def text(self) -> str:
        size = 0
        for shift in range(0, 35, 7):
            (part,) = self.unpack("B")
            size |= (part & 0x7f) << shift
            if part < 0x80:
                return self.read(size).decode("utf-8")
        raise ValueError("Invalid .NET string length")


def inspect_card(path: Path) -> dict:
    with path.open("rb") as stream:
        data = stream.read(MAX_CARD_BYTES + 1)
    if len(data) > MAX_CARD_BYTES:
        raise ValueError("Card exceeds 64 MiB")

    card = CardReader(data)
    if card.read(8) != PNG_SIGNATURE:
        raise ValueError("File is not a PNG card")
    while True:
        size, kind = card.unpack(">I4s")
        card.read(size + 4)
        if kind == b"IEND":
            break
    if card.offset == len(data):
        raise ValueError("PNG has no KKS card data after IEND")

    (product_number,) = card.unpack("<i")
    if card.text() != KKS_MARKER:
        raise ValueError("Card does not have the KKS marker")
    version = card.text()
    (thumbnail_size,) = card.unpack("<i")
    card.read(thumbnail_size)
    (header_size,) = card.unpack("<i")
    header = msgpack.unpackb(card.read(header_size), strict_map_key=False)
    (payload_size,) = card.unpack("<q")
    payload = card.read(payload_size)

    blocks = []
    parameters = None
    for block in header["lstInfo"]:
        start, size = block["pos"], block["size"]
        if start < 0 or size < 0 or start + size > len(payload):
            raise ValueError(f"Block outside payload: {block['name']}")
        blocks.append({key: block[key] for key in ("name", "version", "size")})
        if block["name"] == "Parameter":
            parameters = msgpack.unpackb(payload[start:start + size], strict_map_key=False)
    if not isinstance(parameters, dict):
        raise ValueError("Card has no supported Parameter block")
    return {
        "format": "Koikatsu Sunshine",
        "product_number": product_number,
        "card_version": version,
        "blocks": blocks,
        "parameters": {key: parameters[key] for key in PARAMETERS if key in parameters},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("card", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        metadata = inspect_card(args.card)
        if args.output:
            args.output.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        else:
            print(json.dumps(metadata, indent=2))
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(1, f"Cannot read card: {error}\n")


if __name__ == "__main__":
    main()
