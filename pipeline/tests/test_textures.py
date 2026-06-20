"""cooker.textures: PNG -> capped RGBA8 mip-chain .tex binary (Pillow)."""
import io
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import textures  # noqa: E402
from PIL import Image  # noqa: E402


def _png(w, h, color=(200, 100, 50, 255)):
    buf = io.BytesIO()
    Image.new("RGBA", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


def _parse(blob):
    magic = blob[:4]
    w, h, mips = struct.unpack_from("<III", blob, 4)
    return magic, w, h, mips


def _expected_mip_count(w, h):
    n = 1
    while w > 1 or h > 1:
        w = max(1, w // 2)
        h = max(1, h // 2)
        n += 1
    return n


class TestCookTexture(unittest.TestCase):
    def test_header_magic_and_base_dims(self):
        magic, w, h, mips = _parse(textures.cook_texture(_png(100, 60)))
        self.assertEqual(magic, b"TEX1")
        self.assertEqual((w, h), (100, 60))
        self.assertEqual(mips, _expected_mip_count(100, 60))

    def test_caps_to_max_dim(self):
        _, w, h, mips = _parse(textures.cook_texture(_png(512, 512), max_dim=256))
        self.assertEqual((w, h), (256, 256))
        self.assertEqual(mips, 9)  # 256,128,...,1

    def test_total_size_is_header_plus_all_mip_rgba(self):
        blob = textures.cook_texture(_png(8, 8))
        # header = 4 magic + 3*uint32; mips 8,4,2,1 -> RGBA bytes
        expected_mip_bytes = sum((8 >> i) * (8 >> i) * 4 for i in range(4))
        self.assertEqual(len(blob), 16 + expected_mip_bytes)

    def test_deterministic(self):
        src = _png(40, 40)
        self.assertEqual(textures.cook_texture(src), textures.cook_texture(src))


if __name__ == "__main__":
    unittest.main()
