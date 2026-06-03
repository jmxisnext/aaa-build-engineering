# samples/link — linker-time profiling

The **link** counterpart to `samples/bench` (which is compile-only, `/c`). Link
time is driven by **symbol count**, not per-TU compile cost — so this fixture is
the opposite shape from `heavy.h`: many *cheap* symbols rather than a few
expensive ones. `../../scripts/bench-link.ps1` generates it, compiles it **once**
(untimed), then times only the **link**, several ways.

## The fixture (generated, parametric)

`bench-link.ps1 -TU 64 -Symbols 250` stamps 64 TUs × 250 tiny functions =
**16,000 symbols**, each `int sym_TT_NNNN(int x){ return x*a+b; }`. `(a,b)` come
from a small modulus, so distinct indices collide → genuine **ICF-foldable**
duplicate-body groups. `main` references the **even** global indices, leaving the
odd ones linked-but-unreferenced **bloat** that `/OPT:REF` can strip. Objs are
built `/O2 /Gy /Z7` (function-level COMDATs + embedded debug); a second `/GL` set
feeds the `/LTCG` config. The linked exe is run and its output asserted, so a
wrong link fails the script.

## Result (2026-06-03 · 64 TUs × 250 = 16,000 symbols · 16 logical cores · MSVC 19.29)

| config | link(s) | exe(KB) | vs full |
|---|---|---|---|
| full `/INCREMENTAL:NO` | 0.081 | 777 | 1.00× (baseline) |
| **incremental** (after 1-symbol edit) | **0.033** | 1160 | **2.45× faster** |
| full re-link (after the same edit) | 0.083 | 777 | ≈ full |
| `/DEBUG:FASTLINK` | 0.078 | 777 | ≈ full |
| `/OPT:REF` | 0.085 | **373** | ≈ full time, ½ the exe |
| `/OPT:REF,ICF` | 0.112 | **247** | 1.4× slower, ⅓ the exe |
| `/LTCG` (`/GL` objs) | **21.79** | 246 | **269× slower** |

**Symbol-bloat sweep** (full link, best-of-2):

| symbols | link(s) | exe(KB) |
|---|---|---|
| 16,000 | 0.085 | 777 |
| 32,000 | 0.105 | 1340 |
| 64,000 | 0.153 | 2277 |

```powershell
pwsh -File .\accel\scripts\bench-link.ps1                 # 64 TUs × 250 syms
pwsh -File .\accel\scripts\bench-link.ps1 -Symbols 500    # scale symbol count up
```

## Reading the result (the actual lesson)

Link is a **separate phase from compile, and none of the compile levers touch
it.** `/MP`, unity, PCH, and the FASTBuild cache all attack *compilation*; the
link still runs, serially, per target. Once compilation is fast (or cached),
**the link is the floor on incremental iteration** — the edit-build-run loop.

- **`/INCREMENTAL` patches the exe in place** rather than re-linking from
  scratch — 2.45× faster relink after a one-symbol edit (0.033 vs 0.081 s). The
  cost is a **fatter binary** (1160 vs 777 KB: reserved padding + thunks so the
  next patch fits), and it's **incompatible with `/OPT:REF`, `/OPT:ICF`, and
  `/LTCG`** — ask for those and the linker silently does a full link. So
  incremental is a *debug-iteration* lever, not a release one.
- **A full link pays the whole cost for a one-line change** (full re-link after
  the edit = 0.083 s ≈ from-scratch 0.081 s). Link time is ~independent of how
  much changed — which is the entire reason the incremental linker exists.
- **`/OPT:REF` dead-strips** unreferenced COMDATs (our odd-indexed symbols are
  linked but never called): 777 → 373 KB, essentially free in time. **`/OPT:ICF`
  folds** identical-byte COMDATs (the duplicate `(a,b)` body groups): 373 → 247
  KB, at a link-time cost. Both shrink the binary and both **disable
  incremental** — the release/debug split again.
- **`/LTCG` moves codegen to link time.** With `/GL` objs the optimizer/codegen
  runs *here*, not at compile: 21.79 s, **269×** the plain link. This is the
  answer to "why does our release link take ten minutes" — and why `/MP` (a
  *compile* lever) does nothing for it.
- **Symbol count drives both link time and binary size** (the sweep). More
  COMDATs to resolve, dedup, and write. This is why monolithic targets link
  slowly and studios split into DLLs + dead-strip aggressively.

**The profiling tool — `link /time+`** — is the linker's `cl /Bt+`: it prints
per-pass timings, so you profile the link before reaching for a lever:

```
Pass 1 (input + symbol resolution) = 0.080 s
  OptIcf                           = 0.025 s
Pass 2 (write image)               = 0.021 s
Final                              = 0.101 s
```

**Why `/DEBUG:FASTLINK` barely moved here (the honest caveat):** FASTLINK's win
is *leaving debug info in the objs* instead of merging it into the PDB — it
scales with **how much debug info there is**. This fixture's debug info is
trivial, so FASTLINK ≈ full. On a real codebase with a multi-GB PDB it's a large
link-time win (trade: the PDB then depends on the objs — an iteration tool, not
shippable). Same shape as `samples/bench`'s PCH caveat: the fixture has to *have*
the cost for the lever to show it. Profile your own link (`link /time+`) first.
