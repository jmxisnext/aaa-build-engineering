"""cooker.assets: parse character JSON + build the asset dependency graph."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import assets  # noqa: E402


class TestParseCharacter(unittest.TestCase):
    def test_parses_name_and_refs(self):
        c = assets.parse_character(
            b'{"name":"hero","textures":["textures/h.png"],"audio":["audio/h.wav"]}'
        )
        self.assertEqual(c.name, "hero")
        self.assertEqual(c.textures, ["textures/h.png"])
        self.assertEqual(c.audio, ["audio/h.wav"])

    def test_missing_refs_default_to_empty(self):
        c = assets.parse_character(b'{"name":"npc"}')
        self.assertEqual((c.textures, c.audio), ([], []))

    def test_missing_name_raises(self):
        with self.assertRaises(ValueError):
            assets.parse_character(b'{"textures":[]}')


class TestBuildGraph(unittest.TestCase):
    def test_shared_asset_lists_both_dependents(self):
        a = assets.Character("a", None, ["textures/shared.png"], [])
        b = assets.Character("b", None, ["textures/shared.png"], ["audio/b.wav"])
        g = assets.build_graph([a, b])
        self.assertEqual(g.dependents("textures/shared.png"), {"a", "b"})
        self.assertEqual(g.dependents("audio/b.wav"), {"b"})

    def test_unique_sorted_asset_lists(self):
        a = assets.Character("a", None, ["textures/z.png", "textures/a.png"], [])
        b = assets.Character("b", None, ["textures/a.png"], ["audio/x.wav"])
        g = assets.build_graph([a, b])
        self.assertEqual(g.textures, ["textures/a.png", "textures/z.png"])
        self.assertEqual(g.audio, ["audio/x.wav"])


class TestLoadCharacters(unittest.TestCase):
    def test_loads_from_dir_with_source_path(self):
        with tempfile.TemporaryDirectory() as d:
            cdir = os.path.join(d, "characters")
            os.makedirs(cdir)
            with open(os.path.join(cdir, "hero.json"), "w") as f:
                json.dump({"name": "hero", "textures": ["textures/h.png"]}, f)
            chars = assets.load_characters(d)
            self.assertEqual(len(chars), 1)
            self.assertEqual(chars[0].name, "hero")
            self.assertTrue(chars[0].source_path.endswith("hero.json"))


if __name__ == "__main__":
    unittest.main()
