# pipeline/ — Track 5: data / asset cook pipeline

**Goal (roadmap):** think like the *data* half of "databuild engineer" — incremental
cooks, dependency tracking, content-addressable storage. The artifact is a **hand-rolled
mini DDC / CAS**: a Python cooker that turns synthetic source assets into cooked binaries,
stores them content-addressed, and **skips re-cooking anything that didn't change** — the
same idea as Unreal's Zen/DDC, in ~400 lines of stdlib + Pillow.

> This is **slice 1 — the cooker core**. The C# WPF artist tool (roadmap step 3) and wiring
> into the Track-2 CI `Cook Data` job are deliberately later steps (see *Out of scope*).

## The demo (zero heavy services — pure offline)

```bash
python pipeline/scripts/make-samples.py      # generate synthetic assets (deterministic)
python pipeline/cook.py                       # first cook — everything cooks
python pipeline/cook.py                       # second cook — everything is a cache HIT
#   -> the manifest.toc.json is byte-identical to the first run (determinism)
# now edit one source texture, then:
python pipeline/cook.py                       # only that texture + the character that
                                              # references it re-cook; the rest stay cached
python pipeline/cook.py --force               # ignore the cache; clean re-cook of all
```

The cook prints a `cooked N / cached M` line per asset type — **that's the interview number**:
*"unchanged inputs don't re-cook, and a changed asset only invalidates its dependents."*

## What's here

| Path | What |
|---|---|
| `cook.py` | CLI: `--src` / `--out` / `--force` / `--stats-json`. Thin glue over `cooker.pipeline.run`. |
| `cooker/hashing.py` | `cook_key` (input identity → cache) + `output_hash` (CAS key). A `COOKER_VERSION` bump invalidates every key. |
| `cooker/textures.py` | PNG → capped RGBA8 **mip-chain** `.tex` binary (Pillow, fixed resample → deterministic). |
| `cooker/audio.py` | 16-bit WAV → **mono** 16-bit PCM `.aud` (stdlib `wave`; manual downmix — Py 3.13 removed `audioop`). |
| `cooker/characters.py` | character → binary `.chr` record referencing its assets **by cooked output hash** (so a changed asset propagates). |
| `cooker/assets.py` | parse character JSON + build the **dependency graph** (`dependents(asset) → characters`). |
| `cooker/cache.py` | the **CAS store** (`<hash>.<ext>`) + persisted **cook-key index** → the incremental skip. |
| `cooker/pipeline.py` | orchestration: scan → graph → cook-with-cache → deterministic `.toc` → stats. |
| `scripts/make-samples.py` | deterministic synthetic asset generator (gradient PNGs + sine WAVs + character JSON). |
| `tests/test_*.py` | stdlib `unittest`; per-module + an end-to-end determinism / incremental / dependency-propagation test. |

## Cooked binary formats (little-endian)

- **`.tex`** — `"TEX1"` · `u32 width,height,mipCount` · raw RGBA8 per mip (base → 1×1).
- **`.aud`** — `"AUD1"` · `u32 sampleRate,frameCount` · int16 mono PCM.
- **`.chr`** — `"CHR1"` · `u16 nameLen` + name · `u16 refCount` + per-ref `u8 kind, u16 hashLen, hash`.
- **`manifest.toc.json`** — logical path → `{type, cookKey, outputHash, size, ext}`, sorted, **no timestamps** (so it is byte-identical across no-change runs; run stats are kept separate).

## Why these choices (interview vocabulary)

- **Content-addressable store** — cooked blobs are named by the hash of their bytes, so identical
  outputs dedupe and the `.toc` is a stable content map (Zen Server / UE DDC do exactly this).
- **Cook key vs output hash** — the cook key is the *input* identity (source + params + cooker
  version); an unchanged key short-circuits to the known output without doing the work.
- **Dependency propagation** — characters reference assets by *cooked output hash*, so editing a
  texture invalidates only that texture and the characters that use it — not the whole set.
- **Deterministic** — fixed resample filter, sorted manifest, no timestamps → reproducible builds.

## Tests

```bash
python -m unittest discover -s pipeline/tests -t pipeline   # all
python pipeline/tests/test_pipeline.py                       # the end-to-end proof, alone
```

## CI integration

The cooker runs in CI as the TeamCity **Cook Assets** stage (`AAASandbox_CookAssets`,
see `ci/`). It is also gated on every push by GitHub Actions
(`.github/workflows/tests.yml` → `pipeline-cooker`) and by `run-tests.sh`.

Reproduce the CI cook locally:

```bash
python pipeline/scripts/make-samples.py
python pipeline/cook.py --pack Cooked-assets.pak --stats-json pipeline/.metrics/cook-local.json
# run again: warm cache -> "cooked 0 / cached 8"
python pipeline/cook.py --pack Cooked-assets.pak --stats-json pipeline/.metrics/cook-local.json
```

Cook stats in `pipeline/.metrics/` feed the dashboard "Cook (Track 5)" panel via
`dashboard/scripts/collect-metrics.ps1`.

## Out of scope (this slice)

- **C# WPF artist tool** (roadmap step 3) — pick folder, view the dep graph, trigger a cook,
  see sizes / stale entries. The cooker exposes `pipeline.run` + the `.toc` for it to consume.
- **CI wiring** — replacing Track 2's stub `Cook Data` job with this cooker.
- **Cache GC** — orphaned blobs/keys (left when an input changes) are harmless but not collected.
- **Dashboard feed** — the `--stats-json` output is shaped to feed the dashboard later; not wired.
