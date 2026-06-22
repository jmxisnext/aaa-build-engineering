"""Pack the cooked CAS dir + .toc into a single deterministic .pak (a fixed-timestamp ZIP).

A consumer that wants ONE artifact (e.g. the CI Package step expecting a single Cooked.pak)
gets the toc plus every blob it references. Deterministic: entries are added in sorted order
with a fixed timestamp, so identical cooked inputs produce a byte-identical .pak.
"""
import json
import os
import zipfile

FIXED_DATE = (1980, 1, 1, 0, 0, 0)   # ZIP epoch -> timestamp-free, deterministic bytes
TOC_ARCNAME = "manifest.toc.json"


def pack(cooked_dir, toc_path, out_pak):
    """Write out_pak = a ZIP of the toc + every blob it references. Return the entry count."""
    with open(toc_path, "rb") as f:
        toc_bytes = f.read()
    toc = json.loads(toc_bytes)

    blobs = sorted({f"{e['outputHash']}.{e['ext']}" for e in toc["entries"].values()})
    members = [(TOC_ARCNAME, toc_bytes)]
    for name in blobs:
        with open(os.path.join(cooked_dir, name), "rb") as f:
            members.append((name, f.read()))
    members.sort(key=lambda kv: kv[0])   # fully sorted archive order

    with zipfile.ZipFile(out_pak, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for arcname, data in members:
            zi = zipfile.ZipInfo(arcname, date_time=FIXED_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)
    return len(members)
