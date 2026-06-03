# Track 3 — Build Acceleration: one-page report

**The question this track answers:** *"Walk me through cutting a 25-minute clean
C++ build to 12. What's your order of operations?"*

**Thesis:** there is no single "make it fast" switch. Each lever attacks a
*different* cost; you **profile to find which cost is yours**, then pick — and
the levers compose rather than compete. The most useful thing I learned here was
from a hypothesis I got *wrong* and corrected with a measurement (PCH, below).

## Setup

- **Machine:** 16 logical cores (8 physical + HT). **Toolchain:** MSVC 19.29
  (VS 2019 Build Tools), FASTBuild v1.20.
- **Workload:** 32 translation units, each `#include`-ing one deliberately
  expensive header (`<regex>` + multi-type container instantiation), `/O2`.
- **Method:** compile-only (`/c`, no link), best-of-3 **cold** reps (object dir
  wiped before each rep). Reproduce: `bench.ps1` (`/MP`/unity/PCH) and
  `demo-fbuild.ps1` (FASTBuild). Profiling split: `cl /Bt+`.

## Results

**A. Speeding up one clean compile** — how fast can we build this from scratch?

| lever | time | vs serial | what it attacks |
|---|---|---|---|
| serial (1 core) | 20.27 s | 1.0× | — (baseline) |
| `/MP` (all cores) | 5.10 s | 4.0× | *parallelize* parse + instantiation + codegen |
| PCH warm + `/MP` | 4.37 s | 4.6× | *cache the parse* (only) |
| FASTBuild, cold (cache miss) | 5.33 s | 3.8× | parallelize (≈ `/MP`) |
| unity ×8 chunks + `/MP` | 1.49 s | 13.6× | *share* instantiation+codegen, chunked |
| **unity (1 file)** | **0.72 s** | **28.2×** | *share* instantiation+codegen, fully |

**B. Avoiding the compile entirely** — how fast is a *re*build of unchanged code?
(A different question — this is where real CI/branch-switch time goes.)

| FASTBuild state | time | what it does |
|---|---|---|
| clean build, cache **HIT** | 0.37 s | retrieves every `.obj` from cache, no compile |
| incremental no-op | 0.01 s | dependency check, nothing to do |

## What worked, what didn't (the hypotheses)

- **H1 — `/MP` gives ~Nx.** *Partly.* Got 4.0× on 16 *logical* cores, not 16× —
  hyperthreads aren't full cores, the `cl` front-end + obj writes are serial,
  and it only *parallelizes* redundant work without removing it. The free
  baseline; always on.
- **H2 — unity is the biggest single-compile win.** *Confirmed* (28×) — but for
  a non-obvious reason (H3).
- **H3 — PCH should rival unity (both "parse the header once").** **Refuted.**
  PCH barely beat `/MP` (4.6×), ~6× short of unity. `/Bt+` showed a per-TU
  compile is ~50 % front-end (parse + template **instantiation**) and ~50 %
  back-end (`/O2` codegen). **PCH caches only the parsed declarations** — not
  the instantiation, not the codegen — so it removed just the ~14 % that was
  pure parse. unity wins because merging the TUs compiles the shared template
  machinery (instantiation **and** codegen) *once*. The dominant cost was never
  parsing; my mental model was wrong until I measured the split.
- **H4 — chunked-unity + `/MP` is the sweet spot.** *Refuted for this fixture*
  (one unity blob, single-core, beat 8 chunks across 16 cores) because the
  per-TU-*unique* work is tiny here, so there's nothing to parallelize. Holds
  when real per-TU codegen is large.

## Decision framework

```
1. Turn on /MP.                          Free ~4x. No reason not to.
2. Profile the split (cl /Bt+).
     front-end (parse) dominated?  -> PCH    (declaration-heavy headers:
                                              <Windows.h>, framework umbrellas)
     instantiation/codegen dominated? -> unity/jumbo  (shared templates
                                              everywhere — the common AAA case)
3. Rebuilding unchanged code a lot?      -> FASTBuild cache (CI re-runs, branch
   (CI, branch switches, whole team)        switches; shared path = cross-machine)
4. Cores are the ceiling?                -> FASTBuild distribution (FBuildWorker
                                              = compile farm)
```

They **compose**: `/MP` is the baseline FASTBuild already does; unity/PCH cut the
*cold* compile FASTBuild still pays on a cache miss; the cache + farm attack the
*repeat* builds the others can't. "25 → 12" is layered, not one switch.

## Trade-offs you must name (not just speedups)

- **unity** sacrifices **incremental granularity** (touch one `.cpp` → recompile
  the whole blob; studios tune *chunk size*) and surfaces **ODR / symbol bleed**
  (`static`, anon namespaces, `using`, `#define`s leak across merged TUs). PCH
  and FASTBuild keep per-TU granularity; unity does not.
- **PCH** is low-risk but only pays off when you're parse-bound.
- **FASTBuild** is **hermetic** (no inherited env) — you feed it the toolchain
  explicitly; that strictness is what makes its cache keys reproducible.

## Honest caveat on these numbers

This fixture is *instantiation/codegen-dominated by design* (one heavy template
header, trivial bodies), which flatters unity and starves PCH. A
declaration-heavy, unique-code codebase would shift the ranking toward PCH and
chunked-unity+`/MP`. **That's the whole point of the thesis: measure your own
split before choosing.** Full per-lever detail: `samples/bench/README.md`,
`samples/fbuild/README.md`, and `lessons-learned.md` #1–#5.
