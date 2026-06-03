# samples/bench — build-acceleration benchmark

`heavy.h` is a deliberately expensive compile fixture (`<regex>` +
associative-container instantiation over several type pairs, compiled `/O2`).
Each TU's first line is `#include "pch.h"` — a transparent passthrough to
`heavy.h` so the PCH configs can use `/Yu`. `../../scripts/bench.ps1` stamps N
thin TUs and times **six ways of compiling the same source** — best of 3 cold
reps (object dir wiped before each rep), compile-only (`/c`, no link):

| config | command | what it does |
|---|---|---|
| serial (per-TU) | `cl /c tu00..tuNN` | baseline: parse + instantiate + optimize each TU, 1 core |
| `/MP` (per-TU) | `cl /MP /c tu00..tuNN` | same work, spread across cores |
| unity (1 file) | `cl /c unity_all.cpp` | all TUs in one compile — shared work done once |
| unity ×K + `/MP` | `cl /MP /c unity_c00..cKK` | K unity chunks across cores |
| PCH clean + `/MP` | `/Yc` once, then `/MP /Yu` TUs | header *parse* cached; clean build pays `/Yc` |
| PCH warm + `/MP` | `.pch` prebuilt, then `/MP /Yu` TUs | steady state — parse already paid |

## Result (2026-06-03 · 32 TUs · 16 logical cores · MSVC 19.29)

| config | best(s) | vs serial |
|---|---|---|
| serial (per-TU) | 20.27 | 1.00× |
| `/MP` (per-TU) | 5.10 | 3.97× |
| PCH clean + `/MP` | 4.61 | 4.40× |
| PCH warm + `/MP` | 4.37 | 4.64× |
| unity ×8 + `/MP` | 1.49 | 13.60× |
| **unity (1 file)** | **0.72** | **28.15×** |

```powershell
pwsh -File .\accel\scripts\bench.ps1            # 32 TUs, auto chunks, 3 reps
pwsh -File .\accel\scripts\bench.ps1 -TU 64     # scale up
```

## Reading the result (the actual lesson)

`/Bt+` on one TU splits the per-TU cost ~50/50: **front-end** (parse + template
instantiation) ≈ 0.35 s, **back-end** (`/O2` optimize + codegen) ≈ 0.36 s. That
split explains the whole table:

- **`/MP` parallelizes** all of it — parse, instantiate, optimize — 32× across
  cores. ~4× (16 *logical* cores ≈ 8 physical + HT, plus a serial front-end +
  obj-write tail).
- **PCH caches the *parse* only.** `/Yu` TUs skip re-parsing `heavy.h`, but each
  still *instantiates* the templates it uses and runs the full `/O2` back end.
  PCH removed only the ~14 % that was pure parse → 4.37 s warm, barely above
  `/MP`. **Not** the unity-class win I first expected.
- **unity removes the redundant instantiation *and* optimization.** All 32 TUs
  compile together, so the shared `std::regex` / `map_churn<...>` machinery is
  instantiated and optimized **once** — 28×. Eliminating redundant work beats
  parallelizing it, and here beats merely caching the parse.
- **Chunked unity** sits between: it still repeats the shared work K=8 times
  (once per chunk), so 8 parallel chunks lose to one serial unity blob.

**Why this fixture flatters unity and starves PCH (the honest caveat):** the
cost here is template *instantiation + codegen*, which unity shares and PCH
can't cache. Real PCH wins come from *declaration*-heavy headers (`<Windows.h>`,
framework umbrellas) every TU parses but doesn't re-instantiate — there PCH
cancels huge parse cost. The transferable skill isn't "unity wins" — it's
**measure the front/back split (`/Bt+`, `/d2cgsummary`), then pick the lever
that attacks your actual cost.**

## The levers and their trade-offs

| lever | removes | keeps per-TU granularity? | best when |
|---|---|---|---|
| `/MP` | nothing (parallelizes) | yes | always — the free baseline |
| PCH | redundant *parse* | yes (and `/MP`-compatible) | parse-bound (declaration-heavy headers) |
| unity | redundant parse **+ instantiation + codegen** | **no** (merges TUs) | instantiation-bound; clean-build speed > incremental |

**unity's real costs** (not exercised here — the fixture is collision-free by
construction): incremental granularity collapses (touch one `.cpp`, recompile
the whole blob — studios tune *chunk size* to trade clean-build speed against
incremental pain), and ODR / symbol bleed (`static` helpers, anon namespaces,
`using`, `#define`s leak across concatenated TUs — unity surfaces latent ODR
violations that per-TU builds hid).
