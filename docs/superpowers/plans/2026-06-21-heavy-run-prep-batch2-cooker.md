# Heavy-Run Prep — Batch 2 (cooker) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Track-5 cooker with the three offline capabilities its consumers (CI "Cook Data" wiring + the future WPF artist tool) need: dependency edges in the `.toc`, a `--dry-run` "what would recook" mode, and a single-`.pak` pack output.

**Architecture:** Pure-Python additions to the existing `pipeline/cooker/` package, each behind a `cook.py` flag where user-facing. The cooker stays the single tested source of truth (consumers shell out to it). All work is stdlib + Pillow, deterministic, TDD with `unittest`.

**Tech Stack:** Python 3.13 stdlib (`json`, `zipfile`, `dataclasses`), Pillow (already a dep), `unittest`.

## Global Constraints

- **Offline, deterministic.** `.toc` stays byte-identical across no-change runs (sorted keys, no timestamps); the `.pak` is a fixed-timestamp ZIP so identical cooked inputs → byte-identical pak.
- **Additive, zero-regression.** Leaf (texture/audio) `.toc` entries are unchanged; only character entries gain a `deps` field. All existing `pipeline/tests/*` stay green.
- **Cooker is the source of truth.** No logic moves to consumers; `--dry-run` and `--pack` are thin CLI surfaces over tested `cooker.pipeline` / `cooker.pak` functions.
- **TDD:** write the failing test, run RED, implement, run GREEN, commit per task.
- Run the suite with: `python -m pytest pipeline/tests -q` (or `python -m unittest discover -s pipeline/tests`).

---

### Task 1: Dependency edges in the `.toc`

**Files:**
- Modify: `pipeline/cooker/pipeline.py` (character entries gain `deps`)
- Test: `pipeline/tests/test_pipeline.py` (new test)
- Regenerate: `pipeline/cooked/manifest.toc.json` (committed demo artifact)

**Interfaces:**
- Produces: each `characters/<name>` entry in the `.toc` gains `"deps": [sorted source rel paths]` (its textures + audio). Leaf entries are unchanged (no `deps` key).

- [ ] **Step 1: Write the failing test** — add to `pipeline/tests/test_pipeline.py`:

```python
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
```

- [ ] **Step 2: Run RED** — `python -m unittest pipeline.tests.test_pipeline -v`
Expected: the new test FAILS (`KeyError: 'deps'`).

- [ ] **Step 3: Implement** — in `pipeline/cooker/pipeline.py`, give `_record` an optional `deps` and pass it for characters.

Replace the `_record` definition:
```python
    def _record(rel, kind, key, result, deps=None):
        entry = {
            "type": kind, "cookKey": key, "outputHash": result.output_hash,
            "size": result.size, "ext": result.ext,
        }
        if deps is not None:
            entry["deps"] = deps
        entries[rel] = entry
        stats.total_bytes += result.size
```

In the character loop, compute and pass deps (the `_record(...)` call for characters becomes):
```python
        deps = sorted(list(ch.textures) + list(ch.audio))
        _record(f"characters/{ch.name}", "character", key, r, deps=deps)
```

- [ ] **Step 4: Run GREEN** — `python -m unittest pipeline.tests.test_pipeline -v`
Expected: all tests PASS (incl. the byte-identical-toc determinism test — `deps` is sorted, so still deterministic).

- [ ] **Step 5: Regenerate the committed demo toc** — `python pipeline/cook.py`
(All-cached re-cook; rewrites `pipeline/cooked/manifest.toc.json` with the new `deps` on character entries. Blobs + cookindex unchanged.)

- [ ] **Step 6: Commit**
```bash
git add pipeline/cooker/pipeline.py pipeline/tests/test_pipeline.py pipeline/cooked/manifest.toc.json
git commit -m "feat(pipeline): serialize character->asset dependency edges into the .toc"
```

---

### Task 2: `--dry-run` (what-would-recook, writes nothing)

**Files:**
- Modify: `pipeline/cooker/cache.py` (add `would_hit`)
- Modify: `pipeline/cooker/pipeline.py` (add `DryReport` + `plan()`)
- Modify: `pipeline/cook.py` (add `--dry-run`)
- Test: `pipeline/tests/test_pipeline.py` (and a `test_cache.py` case for `would_hit`)

**Interfaces:**
- Consumes: the persisted cook index (read-only).
- Produces: `cache.Cache.would_hit(cook_key) -> output_hash|None` (read-only, never cooks/writes). `pipeline.plan(src_dir, out_dir) -> DryReport` with `{textures,audio,characters}_{recook,cache}` counts + `would_recook` (sorted rel list); creates and writes nothing. `cook.py --dry-run` prints the report.

- [ ] **Step 1: Write the failing tests**

Add to `pipeline/tests/test_cache.py` (read it first; append a test method to the existing test class, or add a new class — match the file's style):
```python
    def test_would_hit_is_readonly_and_matches_cook_or_reuse(self):
        with tempfile.TemporaryDirectory() as d:
            c = cache.Cache(d)
            self.assertIsNone(c.would_hit("k1"))              # empty -> miss
            r = c.cook_or_reuse("k1", "bin", lambda: b"data")  # populate
            self.assertEqual(c.would_hit("k1"), r.output_hash) # now a hit
            self.assertIsNone(c.would_hit("nope"))             # unknown key -> miss
```

Add to `pipeline/tests/test_pipeline.py`:
```python
    def test_plan_after_cook_reports_all_cached_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            pipeline.run(src, out)
            toc = os.path.join(out, "manifest.toc.json")
            before_mtime = os.path.getmtime(toc)
            before_list = sorted(os.listdir(out))
            rep = pipeline.plan(src, out)
            self.assertEqual((rep.textures_recook, rep.audio_recook, rep.characters_recook), (0, 0, 0))
            self.assertEqual((rep.textures_cache, rep.audio_cache, rep.characters_cache), (2, 1, 2))
            self.assertEqual(rep.would_recook, [])
            self.assertEqual(os.path.getmtime(toc), before_mtime, "plan must not rewrite the toc")
            self.assertEqual(sorted(os.listdir(out)), before_list, "plan must not add files")

    def test_plan_flags_touched_texture_and_its_dependent(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            pipeline.run(src, out)
            _png(os.path.join(src, "textures", "hero.png"), (10, 20, 30, 255))
            rep = pipeline.plan(src, out)
            self.assertEqual((rep.textures_recook, rep.textures_cache), (1, 1))
            self.assertEqual((rep.characters_recook, rep.characters_cache), (1, 1))
            self.assertIn("textures/hero.png", rep.would_recook)
            self.assertIn("characters/hero", rep.would_recook)
            self.assertNotIn("characters/npc", rep.would_recook)

    def test_plan_on_empty_cache_reports_all_recook(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _build_src(src)
            rep = pipeline.plan(src, out)
            self.assertEqual((rep.textures_recook, rep.audio_recook, rep.characters_recook), (2, 1, 2))
            self.assertEqual((rep.textures_cache, rep.audio_cache, rep.characters_cache), (0, 0, 0))
```

- [ ] **Step 2: Run RED** — `python -m unittest pipeline.tests.test_cache pipeline.tests.test_pipeline -v`
Expected: the new tests FAIL (`would_hit` / `plan` / `DryReport` not defined).

- [ ] **Step 3a: Implement `would_hit`** — append to the `Cache` class in `pipeline/cooker/cache.py`:
```python
    def would_hit(self, cook_key):
        """Return the cached output_hash for cook_key if a reusable blob exists, else None.
        Read-only: never cooks, never writes -- the --dry-run primitive."""
        entry = self._index.get(cook_key)
        if entry and os.path.exists(self.blob_path(entry["outputHash"], entry["ext"])):
            return entry["outputHash"]
        return None
```

- [ ] **Step 3b: Implement `DryReport` + `plan()`** — in `pipeline/cooker/pipeline.py`:

Change the dataclass import line `from dataclasses import dataclass` to:
```python
from dataclasses import dataclass, field
```

Add the report dataclass (next to `Stats`):
```python
@dataclass
class DryReport:
    textures_recook: int = 0
    textures_cache: int = 0
    audio_recook: int = 0
    audio_cache: int = 0
    characters_recook: int = 0
    characters_cache: int = 0
    would_recook: list = field(default_factory=list)  # sorted rel paths that would re-cook
```

Add the function (after `run`):
```python
def plan(src_dir, out_dir, max_dim=MAX_DIM):
    """Dry-run: compute what a cook WOULD do (recook vs reuse) WITHOUT cooking or writing.
    Reads the persisted cook index if the out dir exists; creates and writes nothing."""
    chars = assets.load_characters(src_dir)
    graph = assets.build_graph(chars)
    rep = DryReport()

    store = cache.Cache(out_dir, load_index=True) if os.path.isdir(out_dir) else None
    def hit(key):
        return store.would_hit(key) if store else None

    asset_known_hash = {}   # rel -> output hash, for deps that WOULD be cache hits
    asset_recook = set()    # rels that WOULD re-cook

    tex_params = textures.params_bytes(max_dim)
    for rel in graph.textures:
        h = hit(hashing.cook_key(_read(os.path.join(src_dir, rel)), params=tex_params))
        if h:
            asset_known_hash[rel] = h; rep.textures_cache += 1
        else:
            asset_recook.add(rel); rep.textures_recook += 1

    aud_params = audio.params_bytes()
    for rel in graph.audio:
        h = hit(hashing.cook_key(_read(os.path.join(src_dir, rel)), params=aud_params))
        if h:
            asset_known_hash[rel] = h; rep.audio_cache += 1
        else:
            asset_recook.add(rel); rep.audio_recook += 1

    recook = set(asset_recook)
    for ch in chars:
        crel = f"characters/{ch.name}"
        deps = list(ch.textures) + list(ch.audio)
        if any(d in asset_recook for d in deps):
            rep.characters_recook += 1; recook.add(crel); continue
        refs = ([("texture", asset_known_hash[t]) for t in ch.textures]
                + [("audio", asset_known_hash[a]) for a in ch.audio])
        canon = (ch.name + "\n" + "\n".join(f"{k}:{h}" for k, h in refs)).encode("utf-8")
        if hit(hashing.cook_key(canon, params=b"chr")):
            rep.characters_cache += 1
        else:
            rep.characters_recook += 1; recook.add(crel)

    rep.would_recook = sorted(recook)
    return rep
```

- [ ] **Step 3c: Wire `--dry-run` into `cook.py`** — add the arg (after `--stats-json`):
```python
    p.add_argument("--dry-run", action="store_true",
                   help="report what WOULD recook vs reuse; write nothing")
```
And handle it right after the `os.path.isdir(args.src)` check, before `st = pipeline.run(...)`:
```python
    if args.dry_run:
        rep = pipeline.plan(args.src, args.out)
        def dline(label, recook, reuse):
            return f"  {label:<11} recook {recook:>3}   reuse {reuse:>3}"
        print(f"dry-run: {args.src} -> {args.out}  (nothing written)")
        print(dline("textures", rep.textures_recook, rep.textures_cache))
        print(dline("audio", rep.audio_recook, rep.audio_cache))
        print(dline("characters", rep.characters_recook, rep.characters_cache))
        if rep.would_recook:
            print("  would recook:")
            for r in rep.would_recook:
                print(f"    {r}")
        else:
            print("  all up to date - nothing would recook.")
        return 0
```

- [ ] **Step 4: Run GREEN** — `python -m unittest pipeline.tests.test_cache pipeline.tests.test_pipeline -v`
Expected: all PASS. Then a manual smoke: `python pipeline/cook.py --dry-run` → prints "all up to date" (the committed cache is warm).

- [ ] **Step 5: Commit**
```bash
git add pipeline/cooker/cache.py pipeline/cooker/pipeline.py pipeline/cook.py pipeline/tests/test_cache.py pipeline/tests/test_pipeline.py
git commit -m "feat(pipeline): --dry-run (what-would-recook report, writes nothing)"
```

---

### Task 3: Pack cooked CAS + toc into a single `.pak`

**Files:**
- Create: `pipeline/cooker/pak.py`
- Modify: `pipeline/cook.py` (add `--pack`)
- Test: `pipeline/tests/test_pak.py`

**Interfaces:**
- Produces: `cooker.pak.pack(cooked_dir, toc_path, out_pak) -> int` (entry count). Writes a deterministic ZIP containing `manifest.toc.json` + every blob the toc references. `cook.py --pack <path>` cooks then packs.

- [ ] **Step 1: Write the failing test** — create `pipeline/tests/test_pak.py`:

```python
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
```

- [ ] **Step 2: Run RED** — `python -m unittest pipeline.tests.test_pak -v`
Expected: FAIL (`cannot import name 'pak'`).

- [ ] **Step 3a: Implement** — create `pipeline/cooker/pak.py`:
```python
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
```

- [ ] **Step 3b: Wire `--pack` into `cook.py`** — add the arg:
```python
    p.add_argument("--pack", help="also pack cooked blobs + toc into a single .pak at this path")
```
And after the stats-json block (near the end of `main`, before `return 0`):
```python
    if args.pack:
        from cooker import pak  # local import; only needed for --pack
        n = pak.pack(args.out, st.toc_path, args.pack)
        print(f"  pak: {args.pack} ({n} entries)")
```

- [ ] **Step 4: Run GREEN** — `python -m unittest pipeline.tests.test_pak -v`
Expected: both tests PASS. Manual smoke: `python pipeline/cook.py --pack pipeline/cooked/Cooked.pak` prints the pak entry count. (Do NOT commit the generated `Cooked.pak`; it's a build output — add to `.gitignore` if it lands in a tracked dir.)

- [ ] **Step 5: Commit**
```bash
git add pipeline/cooker/pak.py pipeline/cook.py pipeline/tests/test_pak.py
git commit -m "feat(pipeline): pack cooked CAS + toc into a single deterministic .pak"
```

---

## Self-Review

**Spec coverage (Batch 2 from the campaign spec §3.1/§3.2):**
- `.toc` dep edges → Task 1 ✓
- `--dry-run` → Task 2 ✓
- pack-to-`.pak` (CI Package single-`.pak` contract) → Task 3 ✓

**Placeholder scan:** none — every step has complete code.

**Type/name consistency:** `DryReport` field names (`textures_recook`, `would_recook`, …) match the tests; `would_hit` return (output_hash|None) matches both the cache test and `plan()`'s `hit()` usage; `pak.pack(cooked_dir, toc_path, out_pak)` signature matches the test and the `cook.py --pack` call. The `.toc` `deps` key name is identical in Task 1's producer and any later consumer.

**Determinism guards:** `deps` sorted (Task 1); `plan()` writes nothing and short-circuits when out dir is absent (Task 2); ZIP fixed-date + sorted members (Task 3) — each has an explicit test.
