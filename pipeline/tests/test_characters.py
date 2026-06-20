"""cooker.characters: character -> binary record referencing cooked asset hashes."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import characters  # noqa: E402

H1 = "a" * 64
H2 = "b" * 64


def _parse(blob):
    assert blob[:4] == b"CHR1"
    off = 4
    (name_len,) = struct.unpack_from("<H", blob, off); off += 2
    name = blob[off:off + name_len].decode("utf-8"); off += name_len
    (refc,) = struct.unpack_from("<H", blob, off); off += 2
    refs = []
    for _ in range(refc):
        (kind,) = struct.unpack_from("<B", blob, off); off += 1
        (hl,) = struct.unpack_from("<H", blob, off); off += 2
        h = blob[off:off + hl].decode("ascii"); off += hl
        refs.append((kind, h))
    return name, refs


class TestCookCharacter(unittest.TestCase):
    def test_header_name_and_refs(self):
        blob = characters.cook_character("hero", [("texture", H1), ("audio", H2)])
        name, refs = _parse(blob)
        self.assertEqual(name, "hero")
        self.assertEqual(refs, [(characters.KIND["texture"], H1),
                                (characters.KIND["audio"], H2)])

    def test_changing_a_dep_hash_changes_the_record(self):
        # the whole point: a recooked texture (new hash) must change the character blob
        base = characters.cook_character("hero", [("texture", H1)])
        changed = characters.cook_character("hero", [("texture", "c" * 64)])
        self.assertNotEqual(base, changed)

    def test_ref_order_is_significant(self):
        a = characters.cook_character("h", [("texture", H1), ("audio", H2)])
        b = characters.cook_character("h", [("audio", H2), ("texture", H1)])
        self.assertNotEqual(a, b)

    def test_deterministic(self):
        args = ("hero", [("texture", H1), ("audio", H2)])
        self.assertEqual(characters.cook_character(*args), characters.cook_character(*args))

    def test_unknown_kind_raises(self):
        with self.assertRaises(ValueError):
            characters.cook_character("x", [("mesh", H1)])


if __name__ == "__main__":
    unittest.main()
