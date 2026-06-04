# samples/bgfx — build acceleration on a *real* codebase

The other Track 3 samples (`bench/`, `fbuild/`, `link/`) measure the levers on a
**synthetic fixture** — a header engineered to be expensive. That's good for
isolating one cost, but it can't answer *"I cut a real build"*: the numbers only
describe a fixture I built to make them look that way.

This sample swaps in a **real, recognizable workload**: the
[bgfx](https://github.com/bkaradzic/bgfx) renderer core (`extern/bgfx/src`) —
the same engine shipped in real titles and tools. The win isn't bigger numbers
(it's an ~8 s build, not a 25-minute one); it's that the lever *ranking* now
reflects how real engine code actually behaves, and that the unity build is
**bgfx's own** (`src/amalgamated.cpp`), not a fixture I concatenated.

> The workload (bgfx/bx/bimg) is **gitignored** — re-create it with
> `accel/scripts/setup-bgfx.ps1` (pinned SHAs in `vendored.lock.json`), same
> treatment as the vendored `FBuild.exe`. Then `accel/scripts/bench-bgfx.ps1`.

## Why bgfx/src, and why pinned

**Why `src/` and not `examples/common`** (the roadmap's literal target):
measured, `examples/common` is too light — ~3.9 s serial over 24 tiny TUs
(most 0.1–0.5 s), and its `entry/` backends are config-guarded **1 KB no-ops**
under any single platform. Overhead-bound: `/MP` can't show an honest win on
0.1 s TUs. `bgfx/src` is the heavy renderer (`renderer_vk/gl/d3d11/d3d12` +
`bgfx.cpp`, ~0.7–1.1 s each) **and** ships `src/amalgamated.cpp`, the real
unity build. Same vendored repo — the part with real compile cost.

**Why a pinned revision** (not `master`): on 2025-05-26 bx raised its minimum
toolchain to **MSVC 19.35 / Visual Studio 2022 17.5 + C++20**. This build agent
runs **VS 2019 Build Tools (MSVC 19.29)** — the same `cl` the rest of Track 3
uses. Rather than install VS 2022 (a machine-altering detour) or switch the
workload to `clang-cl` (which would break the `/MP` + unity story this track is
about), the triple is pinned to the last revision *before* that bump:

| repo | pinned SHA | date | gate at that revision |
|---|---|---|---|
| bx   | `d4096a8` | 2025-04-26 | MSVC ≥ 19.27 (VS2019 16.7) + **C++17** |
| bgfx | `0e73452` | 2025-04-12 | — |
| bimg | `446b9eb` | 2025-03-07 | — |

So the whole track stays on **one toolchain** (`cl /std:c++17`) and the bgfx
numbers are apples-to-apples with the synthetic fixture's. Pinning the workload
to match the installed compiler *is* the reproducibility discipline this track
preaches (`REPORT.md`: "pin the toolchain version"). See `lessons-learned.md` #7.

## The build recipe (what it took to compile bgfx standalone)

No GENie/CMake — `bench-bgfx.ps1` invokes `cl` directly, which means
reproducing bgfx's include/define setup by hand. What the compiler *demanded*,
in order (each a real "fails on a clean checkout" gotcha):

- `/Zc:__cplusplus` **and** `/Zc:preprocessor` — bx `#error`s without both.
- `/std:c++17` + the `__STDC_*_MACROS` defines + `BX_CONFIG_DEBUG=0`.
- `3rdparty/directx-headers/include/directx` **first on the include path** — the
  VS2019 Windows SDK's `d3d12.h` is too old (`D3D_FEATURE_LEVEL_12_2`,
  `D3D12_FEATURE_DATA_D3D12_OPTIONS8` undeclared); bgfx bundles newer
  DirectX-Headers and expects them to win.
- `3rdparty/khronos` for `vulkan-local/vulkan.h` + `gl/glext.h`.

The per-file set is exactly what `amalgamated.cpp` `#include`s (every `src/*.cpp`
except itself), so per-file vs unity is the same code both ways. 5 of the 20 are
inactive-platform stubs (`renderer_agc/gnm/nvn`, `glcontext_egl/html5`) that
guard to ~1 KB objects — kept, because they're in the real build too.

## Result (2026-06-04 · bgfx `0e73452` · 20 TUs · 16 logical cores · MSVC 19.29)

**A. Clean compile** — best of 3 cold reps, compile-only (`/c`):

| config | best(s) | vs serial | note |
|---|---|---|---|
| serial (per-file) | 7.57 | 1.00× | 20 TUs, 1 core |
| **`/MP` (per-file)** | **1.63** | **4.64×** | all 16 cores |
| unity (amalgamated) | 1.96 | 3.86× | bgfx's real `amalgamated.cpp`, 1 core |

**B. Single-file-edit incremental** — the real edit-build loop (recompile only
what changed):

| edit → rebuild | best(s) |
|---|---|
| per-file: edit `bgfx.cpp` (heavy) | 0.59 |
| per-file: edit `vertexlayout.cpp` (trivial) | **0.13** |
| amalgamated: edit *any* one file | **1.96** |

**C. Where the heaviest TU's time goes** (`bgfx.cpp`):

| profiler | result |
|---|---|
| `/d2cgsummary` (back-end codegen) | 0.21 s, **0** anomalistic/hot functions |
| `/Bt+` front-end (parse + instantiation) | 0.36 s · **61 %** |
| `/Bt+` back-end (codegen) | 0.23 s · 39 % |

## Reading the result (what real code changed vs the synthetic fixture)

1. **`/MP` (4.64×) edges out unity (3.86×) here — the opposite of the synthetic
   fixture**, where one unity blob (28×) crushed `/MP` (4×). Reason: the fixture
   was one shared template header `#include`d 32×, so merging compiled that
   machinery *once*. bgfx's 20 TUs are **genuinely distinct** renderers (Vulkan,
   GL, D3D11, D3D12) with little shared instantiation to collapse — so
   *parallelizing* across 16 cores beats *amalgamating* into one serial compile.
   The lesson the fixture couldn't teach: **unity is not universally fastest;
   it wins when redundant shared work dominates, and real engines aren't always
   that shape.**

2. **The amalgamation's incremental cost is brutal — and now measured on real
   code.** Edit one trivial file: per-file rebuilds **0.13 s**, the amalgamation
   rebuilds the whole engine, **1.96 s — a 15× penalty.** That's the granularity
   a unity build trades away for clean-build speed, and it's why studios that
   amalgamate tune *chunk size* instead of building one blob. bgfx ships *both*
   `amalgamated.cpp` and the per-file set precisely so you can pick per
   build-type (CI clean build → amalgamation; local iteration → per-file).

3. **bgfx is front-end-bound — so `/d2cgsummary` finds nothing, and that's the
   finding.** The back-end codegen profiler reports **zero** hot functions
   because no single function is expensive; `/Bt+` shows why — **61 % of the
   cost is the front end** (parsing + instantiating Vulkan/D3D/Windows
   declarations: 324 includes, ~4,700 type definitions in `renderer_vk` alone).
   This is the Track 3 thesis in one TU: *profile before picking the lever.* The
   right levers here are the **parse-once** ones (the amalgamation, or a
   declaration-heavy PCH on `bgfx_p.h`) — **not** `/LTCG`-class codegen tuning,
   which would attack the 39 % that isn't the problem.

## Reproduce

```powershell
pwsh -File .\accel\scripts\setup-bgfx.ps1      # vendor bgfx/bx/bimg (pinned)
pwsh -File .\accel\scripts\bench-bgfx.ps1      # full run (3 reps)
pwsh -File .\accel\scripts\bench-bgfx.ps1 -Probe   # just the per-TU table
```

Full per-lever detail and the synthetic-fixture comparison: `../bench/README.md`,
`../../REPORT.md`, and `../../lessons-learned.md` #7–#9.
