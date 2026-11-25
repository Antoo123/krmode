"""Read serialized Unity bundle headers without inflating unrelated texture and mesh payloads."""

from bisect import bisect_right
from io import RawIOBase

import UnityPy
from UnityPy.enums import ArchiveFlags, ArchiveFlagsOld
from UnityPy.files import SerializedFile
from UnityPy.files.BundleFile import BundleFile
from UnityPy.helpers import ImportHelper
from UnityPy.streams import EndianBinaryReader


class BlockReader:
    def __init__(self, bundle, source, blocks):
        self.bundle = bundle
        self.source = source
        offset = source.Position
        self.offsets = [0]
        self.blocks = []
        for size, packed_size, codec in blocks:
            self.blocks.append((offset, size, packed_size, codec))
            offset += packed_size
            self.offsets.append(self.offsets[-1] + size)
        self.cached_index = -1
        self.cache = b""

    def read_at(self, start, size):
        result = bytearray()
        while size > 0:
            index = bisect_right(self.offsets, start) - 1
            if index >= len(self.blocks):
                break
            if index != self.cached_index:
                offset, unpacked, packed, codec = self.blocks[index]
                self.source.Position = offset
                self.cache = self.bundle.decompress_data(self.source.read_bytes(packed), unpacked, codec, index)
                self.cached_index = index
            relative = start - self.offsets[index]
            amount = min(size, len(self.cache) - relative)
            if amount <= 0:
                raise EOFError("Invalid UnityFS block")
            if not result and amount == size:
                return self.cache[relative:relative + amount]
            result.extend(self.cache[relative:relative + amount])
            start += amount
            size -= amount
        return bytes(result)


class BlockWindow(RawIOBase):
    def __init__(self, blocks, start, size):
        self.blocks = blocks
        self.start = start
        self.size = size
        self.offset = 0

    def tell(self):
        return self.offset

    def seek(self, offset, origin=0):
        origin_offset = (0, self.offset, self.size)[origin]
        self.offset = origin_offset + offset
        if self.offset < 0:
            raise ValueError("Negative UnityFS seek")
        return self.offset

    def read(self, size=-1):
        remaining = max(0, self.size - self.offset)
        amount = remaining if size < 0 else min(remaining, size)
        data = self.blocks.read_at(self.start + self.offset, amount)
        self.offset += len(data)
        return data


class IndexBundle(BundleFile):
    def read_fs(self, reader):
        if self.signature != "UnityFS":
            raise ValueError("Unsupported bundle signature for indexed read")
        reader.read_long()
        metadata_bytes = reader.read_u_int()
        metadata_unpacked = reader.read_u_int()
        flags = reader.read_u_int()
        version = self.parse_version()
        older_layout = (version < (2020,) or
                        any(version[0] == boundary[0] and version < boundary
                            for boundary in ((2020, 3, 34), (2021, 3, 2), (2022, 1, 1))))
        self.dataflags = (ArchiveFlagsOld if older_layout else ArchiveFlags)(flags)
        if self.dataflags & self.dataflags.UsesAssetBundleEncryption:
            raise ValueError("Encrypted directory requires the normal reader")
        if self.version >= 7 or (version[0] == 2019 and version >= (2019, 4, 15)):
            reader.align_stream(16)
        if flags & 0x80:
            data_start = reader.Position
            reader.Position = reader.Length - metadata_bytes
            metadata = reader.read_bytes(metadata_bytes)
            reader.Position = data_start
        else:
            metadata = reader.read_bytes(metadata_bytes)
        if not older_layout and flags & 0x200:
            reader.align_stream(16)
        directory = EndianBinaryReader(self.decompress_data(metadata, metadata_unpacked, flags))
        directory.read_bytes(16)
        blocks = [(directory.read_u_int(), directory.read_u_int(), directory.read_u_short())
                  for _ in range(directory.read_int())]
        nodes = [(directory.read_long(), directory.read_long(), directory.read_u_int(), directory.read_string_to_null())
                 for _ in range(directory.read_int())]
        return nodes, BlockReader(self, reader, blocks)

    def read_files(self, blocks, nodes):
        for start, size, _, name in nodes:
            if name.lower().endswith((".ress", ".resource", ".config", ".xml", ".dat")):
                continue
            reader = EndianBinaryReader(BlockWindow(blocks, start, size))
            try:
                if not has_animation_type(reader):
                    continue
            finally:
                reader.endian = ">"
                reader.Position = 0
            parsed = ImportHelper.parse_file(reader, self, name)
            if isinstance(parsed, SerializedFile):
                self.files[name] = parsed


def has_animation_type(reader):
    reader.Position = 8
    version = reader.read_u_int()
    if not 14 <= version <= 22:
        return True
    reader.Position = 16
    endian = ">" if reader.read_boolean() else "<"
    reader.Position = 48 if version >= 22 else 20
    reader.endian = endian
    reader.read_string_to_null()
    reader.read_int()  # Target platform
    type_tree = reader.read_boolean()
    type_count = reader.read_int()
    if not 0 <= type_count < 100000:
        return True
    for _ in range(type_count):
        class_id = reader.read_int()
        if class_id == 74:  # AnimationClip
            return True
        skip = 16 + (1 if version >= 16 else 0) + (2 if version >= 17 else 0)
        if (version < 16 and class_id < 0) or (version >= 16 and class_id == 114):
            skip += 16
        reader.Position += skip
        if type_tree:
            nodes = reader.read_int()
            strings = reader.read_int()
            if nodes < 0 or strings < 0:
                return True
            reader.Position += nodes * (32 if version >= 19 else 24) + strings
            if version >= 21:
                dependencies = reader.read_int()
                if dependencies < 0:
                    return True
                reader.Position += 4 * dependencies
    return False


def bundle_objects(source, name):
    def objects():
        prefix = source.read(8)
        source.seek(0)
        if prefix == b"UnityFS\0":
            bundle = IndexBundle(EndianBinaryReader(source), UnityPy.Environment(), name)
            for asset in bundle.files.values():
                yield from asset.objects.values()
        else:
            yield from UnityPy.load(source.read()).objects
    return objects()
