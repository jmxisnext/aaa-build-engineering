"""cooker.cache: content-addressable store + cook-key index (the incremental skip)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import cache  # noqa: E402


class Counter:
    """A cook function that records how many times it actually ran."""
    def __init__(self, payload):
        self.payload = payload
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return self.payload


class TestCache(unittest.TestCase):
    def test_first_cook_is_a_miss_and_stores_a_blob(self):
        with tempfile.TemporaryDirectory() as d:
            c = cache.Cache(d)
            fn = Counter(b"cooked-bytes")
            r = c.cook_or_reuse("key1", "tex", fn)
            self.assertFalse(r.hit)
            self.assertEqual(fn.calls, 1)
            self.assertEqual(r.size, len(b"cooked-bytes"))
            self.assertTrue(os.path.exists(os.path.join(d, r.output_hash + ".tex")))

    def test_same_key_is_a_hit_without_recooking(self):
        with tempfile.TemporaryDirectory() as d:
            c = cache.Cache(d)
            fn = Counter(b"x")
            first = c.cook_or_reuse("key1", "tex", fn)
            second = c.cook_or_reuse("key1", "tex", fn)
            self.assertTrue(second.hit)
            self.assertEqual(fn.calls, 1)  # NOT re-run
            self.assertEqual(second.output_hash, first.output_hash)

    def test_changed_key_recooks(self):
        with tempfile.TemporaryDirectory() as d:
            c = cache.Cache(d)
            r1 = c.cook_or_reuse("key1", "tex", Counter(b"aaa"))
            r2 = c.cook_or_reuse("key2", "tex", Counter(b"bbb"))
            self.assertFalse(r2.hit)
            self.assertNotEqual(r1.output_hash, r2.output_hash)

    def test_index_persists_across_instances(self):
        with tempfile.TemporaryDirectory() as d:
            c1 = cache.Cache(d)
            c1.cook_or_reuse("key1", "tex", Counter(b"data"))
            c1.save()
            # a fresh Cache (new run) should hit from the persisted index
            c2 = cache.Cache(d)
            fn = Counter(b"data")
            r = c2.cook_or_reuse("key1", "tex", fn)
            self.assertTrue(r.hit)
            self.assertEqual(fn.calls, 0)  # never had to cook

    def test_missing_blob_is_a_miss_and_recooks(self):
        # The cache's warm-hit requires BOTH the index entry AND the backing blob on
        # disk. If the blob is gone (truncated/lost artifact) the key must MISS and
        # recook, never crash. This is the safety the warm-cache round-trip relies on.
        with tempfile.TemporaryDirectory() as d:
            c1 = cache.Cache(d)
            r1 = c1.cook_or_reuse("key1", "tex", Counter(b"data"))
            c1.save()
            os.remove(c1.blob_path(r1.output_hash, "tex"))   # blob vanishes; index remains
            c2 = cache.Cache(d)
            self.assertIsNone(c2.would_hit("key1"))           # read-only path: miss
            fn = Counter(b"data")
            r2 = c2.cook_or_reuse("key1", "tex", fn)
            self.assertFalse(r2.hit)                          # recooked, not crashed
            self.assertEqual(fn.calls, 1)

    def test_identical_output_dedupes_to_one_blob(self):
        with tempfile.TemporaryDirectory() as d:
            c = cache.Cache(d)
            r1 = c.cook_or_reuse("key1", "tex", Counter(b"same"))
            r3 = c.cook_or_reuse("key3", "tex", Counter(b"same"))  # different key, same bytes
            self.assertEqual(r1.output_hash, r3.output_hash)
            blobs = [f for f in os.listdir(d) if f.endswith(".tex")]
            self.assertEqual(len(blobs), 1)  # CAS dedupe

    def test_would_hit_is_readonly_and_matches_cook_or_reuse(self):
        with tempfile.TemporaryDirectory() as d:
            c = cache.Cache(d)
            self.assertIsNone(c.would_hit("k1"))               # empty index -> miss
            fn = Counter(b"data")
            r = c.cook_or_reuse("k1", "bin", fn)               # populate
            self.assertEqual(c.would_hit("k1"), r.output_hash) # now a hit
            self.assertEqual(fn.calls, 1)                      # would_hit did NOT cook
            self.assertIsNone(c.would_hit("nope"))             # unknown key -> miss


if __name__ == "__main__":
    unittest.main()
