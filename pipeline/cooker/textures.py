"""Texture cook: PNG -> capped RGBA8 mip-chain binary (.tex).

Binary layout (little-endian):
    magic   "TEX1"           (4 bytes)
    width   uint32           (base, after capping)
    height  uint32
    mips    uint32           (number of mip levels)
    then, per level mip0..mipN: raw RGBA8 bytes (width*height*4), each level half-size
    down to 1x1.

Deterministic: a fixed resample filter (LANCZOS) + raw byte output, so the same source
always yields the same blob (the .toc stability + CAS dedupe depend on this).
"""
import io
import struct

from PIL import Image

MAGIC = b"TEX1"
_RESAMPLE = Image.Resampling.LANCZOS


def params_bytes(max_dim=256):
    """Cook params for the cache key -- changing them must force a re-cook."""
    return f"tex:max={max_dim}".encode("utf-8")


def cook_texture(png_bytes, max_dim=256):
    img = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    w, h = img.size

    # cap the longest edge to max_dim, preserving aspect ratio
    if max(w, h) > max_dim:
        if w >= h:
            w, h = max_dim, max(1, round(h * max_dim / img.size[0]))
        else:
            w, h = max(1, round(w * max_dim / img.size[1])), max_dim
        img = img.resize((w, h), _RESAMPLE)

    # full mip chain down to 1x1 (resampled from the capped base each level)
    levels = [img]
    cw, ch = w, h
    while cw > 1 or ch > 1:
        cw, ch = max(1, cw // 2), max(1, ch // 2)
        levels.append(img.resize((cw, ch), _RESAMPLE))

    out = bytearray(MAGIC)
    out += struct.pack("<III", w, h, len(levels))
    for level in levels:
        out += level.tobytes()  # raw RGBA8
    return bytes(out)
