"""cook.py CLI: --stats-json must create its parent dir (CI writes into a fresh pipeline/.metrics)."""
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))  # pipeline/ on path
import cook  # noqa: E402
from cooker import pipeline  # noqa: E402  (to build a tiny source tree)
from PIL import Image  # noqa: E402


def _tiny_src(d):
    os.makedirs(os.path.join(d, "textures"))
    os.makedirs(os.path.join(d, "audio"))
    os.makedirs(os.path.join(d, "characters"))
    Image.new("RGBA", (8, 8), (1, 2, 3, 255)).save(os.path.join(d, "textures", "t.png"))
    with open(os.path.join(d, "characters", "c.json"), "w") as f:
        json.dump({"name": "c", "textures": ["textures/t.png"], "audio": []}, f)


class TestStatsJsonParentDir(unittest.TestCase):
    def test_stats_json_into_missing_dir_succeeds(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _tiny_src(src)
            stats = os.path.join(out, "does", "not", "exist", "cook.json")
            rc = cook.main(["--src", src, "--out", os.path.join(out, "cooked"),
                            "--stats-json", stats])
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(stats), "stats-json parent dir should be created")
            with open(stats) as f:
                self.assertIn("total_bytes", json.load(f))


if __name__ == "__main__":
    unittest.main()
