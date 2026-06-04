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
- **Method:** best-of-3 **cold** reps (object dir wiped before each rep).
  Sections A/B are compile-only (`/c`, no link); section C measures the link
  separately. Reproduce: `bench.ps1` (`/MP`/unity/PCH), `demo-fbuild.ps1`
  (FASTBuild), `bench-link.ps1` (linker). Profiling: `cl /Bt+` (compile split),
  `link /time+` (link passes).

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

**C. The link step** — a *different phase* none of A/B touches. `/MP`, unity,
PCH, and the cache all speed *compilation*; the link still runs, serially, per
target — so once compiles are cheap, **the link is the floor on incremental
iteration.** Fixture: 16,000 symbols, compiled once, only the link varied.

| link config | link time | exe size | what it attacks |
|---|---|---|---|
| full `/INCREMENTAL:NO` | 0.081 s | 777 KB | — (baseline) |
| **incremental** (after 1-symbol edit) | **0.033 s** | 1160 KB | *patch in place* vs re-link (2.45×) |
| `/OPT:REF,ICF` | 0.112 s | **247 KB** | *dead-strip + fold* — smaller exe, slower link |
| `/LTCG` (`/GL` objs) | **21.8 s** | 246 KB | *codegen moved to link* (269× — release cost) |

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
- **H5 — link is a separate axis the compile levers can't help.** *Confirmed.*
  `/INCREMENTAL` patches the exe in place (2.45× faster relink) — but a full link
  pays the *whole* cost for a one-line change (re-link after a 1-symbol edit ≈
  from-scratch), which is the incremental linker's reason to exist. Its trade:
  a fatter binary + incompatibility with `/OPT:REF`/`/OPT:ICF`/`/LTCG` (so it's
  a *debug* lever). `/LTCG` is the mirror image — `/GL` moves codegen *to* the
  link (269× slower), the real "why is the release link slow." Symbol count
  drives both link time and binary size, so DLL-splitting + dead-strip is the
  structural fix.

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
5. Compiles fast but iteration slow?     -> profile the LINK (link /time+):
     incremental edit-build-run loop?      -> /INCREMENTAL (debug; not w/ LTCG)
     release link takes forever?           -> /LTCG codegen-at-link is the cost
     link slow + binary huge?              -> cut symbol count: split into DLLs,
                                              /OPT:REF,ICF to dead-strip + fold
```

They **compose**: `/MP` is the baseline FASTBuild already does; unity/PCH cut the
*cold* compile FASTBuild still pays on a cache miss; the cache + farm attack the
*repeat* builds the others can't; and the **link** (step 5) is a separate phase
*none* of them touch — once compiles are cheap or cached, the serial link is
what's left, so it becomes the floor on incremental iteration. "25 → 12" is
layered across both phases, not one switch.

## Trade-offs you must name (not just speedups)

- **unity** sacrifices **incremental granularity** (touch one `.cpp` → recompile
  the whole blob; studios tune *chunk size*) and surfaces **ODR / symbol bleed**
  (`static`, anon namespaces, `using`, `#define`s leak across merged TUs). PCH
  and FASTBuild keep per-TU granularity; unity does not.
- **PCH** is low-risk but only pays off when you're parse-bound.
- **FASTBuild** is **hermetic** (no inherited env) — you feed it the toolchain
  explicitly; that strictness is what makes its cache keys reproducible.
- **`/INCREMENTAL`** buys relink speed with a **fatter binary** (padding/thunks)
  and rules out `/OPT:REF`/`/OPT:ICF`/`/LTCG` — a debug-iteration lever, not
  release. **`/LTCG`** is the inverse trade: link time for runtime perf.

## Validation on a real codebase (bgfx renderer core)

The sections above use a **synthetic** fixture — a header engineered to be
expensive. To check the thesis against real code, I re-ran the compile levers on
the **bgfx renderer core** (`extern/bgfx/src`, 20 TUs of a shipping engine) —
and bgfx ships its *own* unity build (`amalgamated.cpp`), so unity here is real,
not concatenated. Best of 3 cold, `/c` (`samples/bgfx/` + `bench-bgfx.ps1`):

| config | best(s) | vs serial |
|---|---|---|
| serial (per-file) | 7.57 | 1.00× |
| **`/MP` (per-file)** | **1.63** | **4.64×** |
| unity (amalgamated) | 1.96 | 3.86× |

**Real code moved the ranking — exactly as the thesis predicts.** On the
fixture, unity (28×) crushed `/MP` (4×); on bgfx, **`/MP` (4.64×) *beats* unity
(3.86×).** The fixture was one shared header parsed 32×, so amalgamating did it
once; bgfx's 20 TUs are genuinely distinct renderers (VK/GL/D3D11/D3D12) with
little shared work to collapse, so parallelizing wins. Two more real-code
findings the fixture couldn't show:

- **Unity's incremental cost, measured:** edit one trivial file → per-file
  rebuilds **0.13 s**, the amalgamation rebuilds the whole engine, **1.96 s
  (15×)**. That's the granularity unity trades for clean-build speed — the real
  edit-build loop, the thing `/MP`/PCH keep and unity doesn't.
- **bgfx is front-end-bound:** `/d2cgsummary` finds **0** hot codegen functions;
  `/Bt+` shows **61 %** of `bgfx.cpp` is front-end (parse + instantiate
  Vulkan/D3D/Windows decls). So the parse-once levers (the amalgamation, a
  declaration-heavy PCH) fit — *not* `/LTCG`-class codegen tuning. Profile first.

## Honest caveat on these numbers

The synthetic fixture is *instantiation/codegen-dominated by design* (one heavy
template header, trivial bodies), which flatters unity and starves PCH — which
is exactly why the bgfx run above matters: real, declaration-heavy engine code
shifted the ranking toward `/MP` and the parse-once levers, as predicted. The
link section is the mirror caveat — its fixture is *symbol-count-dominated by
design* (16k trivial functions), so it shows `/INCREMENTAL`/`/LTCG`/`/OPT`
cleanly but starves `/DEBUG:FASTLINK` (trivial debug info). **That's the whole
point of the thesis: measure your own split before choosing.** Full per-lever
detail: `samples/bench/README.md`, `samples/bgfx/README.md`,
`samples/fbuild/README.md`, `samples/link/README.md`, and `lessons-learned.md`
#1–#9.
