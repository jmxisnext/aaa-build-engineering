"""Character cook: serialize a character to a binary record (.chr).

The record references its assets by their COOKED OUTPUT HASH, not by source path. That
is what makes the dependency graph real: when a texture's pixels change, its output hash
changes, so this record's bytes change, so the character re-cooks too (everything that
does not depend on the changed asset stays a cache-hit).

Binary layout (little-endian):
    magic     "CHR1"        (4 bytes)
    nameLen   uint16 ; name (utf-8)
    refCount  uint16
    per ref:  kind uint8 (see KIND) ; hashLen uint16 ; hash (ascii hex)
"""
import struct

MAGIC = b"CHR1"
KIND = {"texture": 0, "audio": 1}


def cook_character(name, refs):
    """refs: ordered list of (kind, output_hash_hex). Order is significant."""
    name_bytes = name.encode("utf-8")
    out = bytearray(MAGIC)
    out += struct.pack("<H", len(name_bytes))
    out += name_bytes
    out += struct.pack("<H", len(refs))
    for kind, output_hash in refs:
        if kind not in KIND:
            raise ValueError(f"unknown asset kind {kind!r} (expected one of {list(KIND)})")
        hash_bytes = output_hash.encode("ascii")
        out += struct.pack("<B", KIND[kind])
        out += struct.pack("<H", len(hash_bytes))
        out += hash_bytes
    return bytes(out)
