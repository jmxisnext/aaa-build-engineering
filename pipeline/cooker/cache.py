"""Content-addressable store + cook-key index -- the incremental-cook engine.

Two parts working together:
  * CAS store    -- cooked blobs written as <cooked_dir>/<output_hash>.<ext>, so identical
                    outputs dedupe to a single file.
  * cook index   -- <cooked_dir>/.cookindex.json mapping cook_key -> {outputHash, ext, size},
                    persisted across runs. An unchanged cook_key whose blob still exists is a
                    HIT: cook_or_reuse returns the known result WITHOUT running the cook fn.

Orphaned blobs/keys (left when an input changes) are not garbage-collected in this slice --
they are harmless (the .toc only references current assets). GC is a future add.
"""
import json
import os
from dataclasses import dataclass

from . import hashing

INDEX_NAME = ".cookindex.json"


@dataclass
class CacheResult:
    output_hash: str
    size: int
    hit: bool
    ext: str


class Cache:
    def __init__(self, cooked_dir, load_index=True):
        self.dir = cooked_dir
        os.makedirs(cooked_dir, exist_ok=True)
        self.index_path = os.path.join(cooked_dir, INDEX_NAME)
        self._index = {}
        # load_index=False => every lookup misses (a forced/clean re-cook)
        if load_index and os.path.exists(self.index_path):
            with open(self.index_path, "r", encoding="utf-8") as f:
                self._index = json.load(f)

    def blob_path(self, output_hash, ext):
        return os.path.join(self.dir, f"{output_hash}.{ext}")

    def cook_or_reuse(self, cook_key, ext, cook_fn):
        """Return the cooked result for cook_key, running cook_fn only on a miss."""
        entry = self._index.get(cook_key)
        if entry and os.path.exists(self.blob_path(entry["outputHash"], entry["ext"])):
            return CacheResult(entry["outputHash"], entry["size"], True, entry["ext"])

        data = cook_fn()
        output_hash = hashing.output_hash(data)
        blob = self.blob_path(output_hash, ext)
        if not os.path.exists(blob):  # CAS dedupe -- don't rewrite an identical blob
            with open(blob, "wb") as f:
                f.write(data)
        self._index[cook_key] = {"outputHash": output_hash, "ext": ext, "size": len(data)}
        return CacheResult(output_hash, len(data), False, ext)

    def would_hit(self, cook_key):
        """Return the cached output_hash for cook_key if a reusable blob exists, else None.
        Read-only: never cooks, never writes -- the --dry-run primitive."""
        entry = self._index.get(cook_key)
        if entry and os.path.exists(self.blob_path(entry["outputHash"], entry["ext"])):
            return entry["outputHash"]
        return None

    def save(self):
        # sorted keys -> deterministic index file
        with open(self.index_path, "w", encoding="utf-8") as f:
            json.dump(self._index, f, indent=2, sort_keys=True)
