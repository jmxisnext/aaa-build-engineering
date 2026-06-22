"""pak.pack: a single deterministic .pak (fixed-timestamp ZIP) of the toc + referenced blobs."""
import array
import json
import os
import sys
import tempfile
import unittest
import wave
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import pak, pipeline  # noqa: E402
from PIL import Image  # noqa: E402


def _png(path, color):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Image.new("RGBA", (16, 16), color).save(path, format="PNG")


def _wav(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(22050)
        w.writeframes(array.array("h", (1, 2, 3, 4)).tobytes())


def _char(path, name, textures=(), audio=()):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump({"name": name, "textures": list(textures), "audio": list(audio)}, f)


def _build_src(d):
    _png(os.path.join(d, "textures", "hero.png"), (200, 50, 50, 255))
    _wav(os.path.join(d, "audio", "hero.wav"))
    _char(os.path.join(d, "characters", "hero.json"), "hero",
          ["textures/hero.png"], ["audio/hero.wav"])


class TestPak(unittest.TestCase):
    def test_pack_contains_toc_and_all_blobs(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            st = pipeline.run(src, out)
            pak_path = os.path.join(out, "Cooked.pak")
            n = pak.pack(out, st.toc_path, pak_path)
            with zipfile.ZipFile(pak_path) as z:
                names = set(z.namelist())
            self.assertIn("manifest.toc.json", names)
            with open(st.toc_path) as f:
                toc = json.load(f)
            for e in toc["entries"].values():
                self.assertIn(f"{e['outputHash']}.{e['ext']}", names)
            self.assertEqual(n, len(names))

    def test_pack_is_byte_deterministic(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            st = pipeline.run(src, out)
            p1 = os.path.join(out, "a.pak"); p2 = os.path.join(out, "b.pak")
            pak.pack(out, st.toc_path, p1)
            pak.pack(out, st.toc_path, p2)
            with open(p1, "rb") as f: b1 = f.read()
            with open(p2, "rb") as f: b2 = f.read()
            self.assertEqual(b1, b2, "pak must be byte-identical across runs (deterministic)")


if __name__ == "__main__":
    unittest.main()
