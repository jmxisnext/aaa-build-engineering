"""cooker.pipeline end-to-end: deterministic .toc, content-cache hits, and
dependency propagation (touch one source -> only it + its dependents re-cook)."""
import array
import json
import os
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import pipeline  # noqa: E402
from PIL import Image  # noqa: E402


def _png(path, color):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Image.new("RGBA", (16, 16), color).save(path, format="PNG")


def _wav(path, samples=(1, 2, 3, 4)):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(array.array("h", samples).tobytes())


def _char(path, name, textures=(), audio=()):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump({"name": name, "textures": list(textures), "audio": list(audio)}, f)


def _build_src(d):
    _png(os.path.join(d, "textures", "hero.png"), (200, 50, 50, 255))
    _png(os.path.join(d, "textures", "npc.png"), (50, 200, 50, 255))
    _wav(os.path.join(d, "audio", "hero.wav"))
    _char(os.path.join(d, "characters", "hero.json"), "hero",
          ["textures/hero.png"], ["audio/hero.wav"])
    _char(os.path.join(d, "characters", "npc.json"), "npc", ["textures/npc.png"])


class TestPipelineEndToEnd(unittest.TestCase):
    def test_first_run_cooks_everything(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            st = pipeline.run(src, out)
            self.assertEqual((st.textures_cooked, st.textures_cached), (2, 0))
            self.assertEqual((st.audio_cooked, st.audio_cached), (1, 0))
            self.assertEqual((st.characters_cooked, st.characters_cached), (2, 0))
            self.assertTrue(os.path.exists(os.path.join(out, "manifest.toc.json")))

    def test_second_run_all_cached_and_toc_byte_identical(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            pipeline.run(src, out)
            toc_path = os.path.join(out, "manifest.toc.json")
            with open(toc_path, "rb") as f:
                toc1 = f.read()
            st = pipeline.run(src, out)
            self.assertEqual((st.textures_cooked, st.audio_cooked, st.characters_cooked), (0, 0, 0))
            self.assertEqual((st.textures_cached, st.audio_cached, st.characters_cached), (2, 1, 2))
            with open(toc_path, "rb") as f:
                toc2 = f.read()
            self.assertEqual(toc1, toc2, "toc must be byte-identical across no-change runs")

    def test_touch_one_texture_recooks_only_it_and_its_dependent(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            pipeline.run(src, out)
            toc_path = os.path.join(out, "manifest.toc.json")
            with open(toc_path) as f:
                toc_before = json.load(f)
            # change hero's texture pixels -> new source bytes
            _png(os.path.join(src, "textures", "hero.png"), (10, 20, 30, 255))
            st = pipeline.run(src, out)
            # only hero.png re-cooks; npc.png + hero.wav stay cached
            self.assertEqual((st.textures_cooked, st.textures_cached), (1, 1))
            self.assertEqual((st.audio_cooked, st.audio_cached), (0, 1))
            # hero character re-serializes (its texture hash changed); npc untouched
            self.assertEqual((st.characters_cooked, st.characters_cached), (1, 1))
            with open(toc_path) as f:
                toc_after = json.load(f)
            self.assertNotEqual(toc_before["entries"]["textures/hero.png"]["outputHash"],
                                toc_after["entries"]["textures/hero.png"]["outputHash"])
            self.assertEqual(toc_before["entries"]["textures/npc.png"]["outputHash"],
                             toc_after["entries"]["textures/npc.png"]["outputHash"])

    def test_force_recooks_even_when_cached(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            pipeline.run(src, out)
            st = pipeline.run(src, out, force=True)
            self.assertEqual((st.textures_cooked, st.audio_cooked, st.characters_cooked), (2, 1, 2))

    def test_character_entries_carry_sorted_dependency_edges(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            pipeline.run(src, out)
            with open(os.path.join(out, "manifest.toc.json")) as f:
                toc = json.load(f)
            self.assertEqual(toc["entries"]["characters/hero"]["deps"],
                             ["audio/hero.wav", "textures/hero.png"])
            self.assertEqual(toc["entries"]["characters/npc"]["deps"],
                             ["textures/npc.png"])
            # leaf assets carry NO deps key (their schema is unchanged)
            self.assertNotIn("deps", toc["entries"]["textures/hero.png"])


if __name__ == "__main__":
    unittest.main()
