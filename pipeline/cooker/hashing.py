"""Content hashing for the cooker's cache + content-addressable store.

Two distinct hashes:
  * cook_key   -- identity of a cook INPUT (source bytes + params + cooker version).
                  Drives the cache: an unchanged cook_key short-circuits to the known
                  output without re-cooking. Bumping COOKER_VERSION invalidates all keys.
  * output_hash -- identity of a cooked OUTPUT (the CAS key). Cooked blobs are stored
                  named by this, so identical outputs dedupe and the .toc is stable.
"""
import hashlib

# Bump when a cooker's output format/algorithm changes, to force a global re-cook.
COOKER_VERSION = "1"


def output_hash(cooked_bytes):
    """SHA-256 hex of a cooked artifact (its content-addressable-store key)."""
    return hashlib.sha256(cooked_bytes).hexdigest()


def cook_key(source_bytes, params=b"", cooker_version=COOKER_VERSION):
    """SHA-256 hex identifying a cook input: source + params + cooker version.

    NUL-delimited so (source, params) boundaries can't be ambiguous.
    """
    h = hashlib.sha256()
    h.update(cooker_version.encode("utf-8"))
    h.update(b"\0")
    h.update(params)
    h.update(b"\0")
    h.update(source_bytes)
    return h.hexdigest()
