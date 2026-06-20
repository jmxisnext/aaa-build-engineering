"""cooker.hashing: cook-key (input identity for the cache) + output hash (CAS key)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import hashing  # noqa: E402


class TestOutputHash(unittest.TestCase):
    def test_is_64_char_hex_sha256(self):
        h = hashing.output_hash(b"hello")
        self.assertEqual(len(h), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in h))

    def test_known_sha256_of_empty(self):
        # sha256("") is a fixed, well-known constant -> proves it's real sha256
        self.assertEqual(
            hashing.output_hash(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )

    def test_deterministic_and_collision_sensitive(self):
        self.assertEqual(hashing.output_hash(b"abc"), hashing.output_hash(b"abc"))
        self.assertNotEqual(hashing.output_hash(b"abc"), hashing.output_hash(b"abd"))


class TestCookKey(unittest.TestCase):
    def test_same_inputs_same_key(self):
        a = hashing.cook_key(b"src", params=b"p")
        b = hashing.cook_key(b"src", params=b"p")
        self.assertEqual(a, b)

    def test_source_change_changes_key(self):
        self.assertNotEqual(hashing.cook_key(b"src1"), hashing.cook_key(b"src2"))

    def test_params_change_changes_key(self):
        self.assertNotEqual(
            hashing.cook_key(b"src", params=b"max=256"),
            hashing.cook_key(b"src", params=b"max=128"),
        )

    def test_cooker_version_bump_invalidates_key(self):
        # bumping the cooker version must change every cook-key (forces a re-cook)
        self.assertNotEqual(
            hashing.cook_key(b"src", cooker_version="1"),
            hashing.cook_key(b"src", cooker_version="2"),
        )


if __name__ == "__main__":
    unittest.main()
