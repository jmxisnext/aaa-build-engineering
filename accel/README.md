# accel/ — Track 3: build acceleration

**Goal (roadmap):** cut a clean-build time on a non-trivial C++ project
*measurably*, and be able to explain what you did and why — in build-engineer
vocabulary (`/MP`, unity build, PCH, FASTBuild, link time).

Track 3 starts with a prerequisite the earlier tracks quietly assumed: **a
C++ compiler you can actually invoke from a script.** On Windows that is not
free — MSVC ships gated behind a "Developer Command Prompt." This dir first
makes the toolchain activatable and *proven*, then layers measured
acceleration wins on top.

> **Start with [`REPORT.md`](REPORT.md)** — the one-page summary: all five
> levers (four compile + the link) measured side by side, the decision
> framework, and the PCH hypothesis I got wrong and corrected with `/Bt+`.

## What's here

| Path | What |
|---|---|
| `REPORT.md` | **One-page capstone** — all five levers (four compile + the link) measured, the decision framework, hypotheses (incl. the refuted PCH one). Read this first. |
| `scripts/activate-msvc.ps1` | Locates the newest MSVC via `vswhere`, imports its `vcvars64` environment into the current PowerShell session. **Dot-source it.** |
| `scripts/smoke-build.ps1` | Activates the toolchain, compiles + runs `samples/hello`, asserts the output. The "compiler works" proof — exits non-zero on failure, so CI can gate on it. |
| `scripts/bench.ps1` | Build-acceleration benchmark: compiles N heavy TUs serial / `/MP` / unity / chunked-unity / PCH and prints one before/after table. The reusable harness the Track 3 levers plug into. |
| `scripts/demo-fbuild.ps1` | FASTBuild lever: builds the same TUs through FASTBuild and measures its cache (clean cache-miss vs cache-HIT vs no-op). |
| `scripts/bench-link.ps1` | **Linker** lever: the `bench.ps1` sibling for the *link* step. Compiles a 16k-symbol fixture once, then times only the link — `/INCREMENTAL` vs full, `/OPT:REF`/`ICF`, `/LTCG`, a symbol-bloat sweep, and a `link /time+` breakdown. |
| `scripts/setup-bgfx.ps1` | Vendors the **real workload** — shallow-clones bgfx/bx/bimg into `extern/` (gitignored), pinned to the last revision that builds with the installed MSVC 19.29. SHAs recorded in `samples/bgfx/vendored.lock.json`. |
| `scripts/bench-bgfx.ps1` | The levers on a **real codebase** (bgfx renderer core): serial / `/MP` / unity (bgfx's own `amalgamated.cpp`) + single-file-edit incremental + a `/d2cgsummary`+`/Bt+` profile. The honest before/after the synthetic fixture can't give. |
| `samples/hello/` | Smallest program that proves compile + run (prints `_MSC_VER`). |
| `samples/bench/` | `heavy.h` compile-cost fixture + the `/MP`/unity/PCH results writeup (`README.md`). |
| `samples/fbuild/` | `fbuild.bff` + the FASTBuild cache results writeup (`README.md`). |
| `samples/link/` | symbol-bloat fixture (generated) + the linker-profiling results writeup (`README.md`). |
| `samples/bgfx/` | **Real-workload** writeup (`README.md`): bgfx before/after, the pin rationale, and how real code moved the lever ranking. `vendored.lock.json` pins the SHAs. |
| `tools/fastbuild/` | Where `FBuild.exe` goes (gitignored vendor binary; `README.md` has the download steps). |
| `extern/` | Vendored bgfx/bx/bimg source (gitignored; re-clone via `setup-bgfx.ps1`). |
| `lessons-learned.md` | Gotchas, same numbered format as `perforce/` and `ci/`. |

## The compiler situation (resolved 2026-06-03)

`cl`, `cmake`, `ninja` were all missing from PATH — the classic Windows
"compiler is installed but not activated" state. Two MSVC toolchains are in
fact present on this box:

- **VS 2019 Build Tools** — MSVC 14.29 (cl 19.29). *Preferred*: no IDE, the
  CI-shaped install a real build agent would use.
- VS 2017 Community — MSVC 14.16 (cl 19.16).

`activate-msvc.ps1` selects the newest automatically (`vswhere -latest`), so
Build Tools 2019 wins. **No install was required** — the fix was activation,
not acquisition.

### Activate + prove it

```powershell
. .\accel\scripts\activate-msvc.ps1        # dot-source: cl/link/nmake/msbuild now on PATH
pwsh -File .\accel\scripts\smoke-build.ps1  # compile + run + assert
```

Verified output (2026-06-03):

```
MSVC active: ...\2019\BuildTools\VC\Tools\MSVC\14.29.30133\bin\HostX64\x64\cl.exe
  Microsoft (R) C/C++ Optimizing Compiler Version 19.29.30159 for x64
Compiling ...\accel\samples\hello\hello.cpp ...
  output: hello from MSVC (_MSC_VER=1929)
SMOKE OK -- MSVC toolchain activates, compiles, and runs.
```

## Why activation is a build-engineer concern (not setup noise)

This is the "works on my machine, fails on a fresh agent" class of bug, the
same shape as `ci/lessons-learned.md` #2 (agent had no `p4` binary):

- **vcvars only mutates the process it runs in.** It's a `.bat` — it can't
  reach back into the PowerShell session that launched it. The fix is to run
  it in a cmd subshell, dump `set`, and replay the variables. Every
  "activate the compiler from PowerShell" recipe is doing exactly this.
- **A build agent must activate the toolchain in its build step**, not rely
  on a developer's pre-warmed Developer Command Prompt. If your build
  "works locally" but fails on a clean agent with *cl not found*, the agent's
  step is missing the vcvars activation.
- **Pin the toolchain version.** `vswhere -latest` is convenient for a
  sandbox, but a reproducible build pins the MSVC version (e.g. via
  `vcvars64.bat -vcvars_ver=14.29`) so a newly-installed VS update doesn't
  silently change your codegen.

## Next (Track 3 roadmap — measured wins layer on the foundation)

- [x] **`/MP` parallel compilation** — one flag, **3.97×** (20.27 s → 5.10 s,
      32 TUs / 16 cores). *Parallelizes* the redundant work.
- [x] **Unity / jumbo build** — **28.2×** (→ 0.72 s) by compiling the shared
      template machinery *once* instead of per-TU. *Eliminates* redundant
      instantiation + codegen — beats `/MP` and chunked-unity outright here
      (1 core 0.72 s vs 8 chunks/16 cores 1.49 s). See `samples/bench/` +
      lessons-learned #3 (incl. fixture bias + unity's real costs).
- [x] **PCH** — **4.64×** (warm). Caches the *parse* only, not instantiation or
      `/O2` codegen (`/Bt+` showed per-TU ≈ 50 % each), so it barely beat `/MP`
      on this instantiation-bound fixture — *but* it keeps per-TU granularity
      (unlike unity) and is the right lever for declaration-heavy headers.
      lessons-learned #4.
- [x] **FASTBuild** as orchestrator — cold build ≈ `/MP` (5.33 s), but its
      content-addressable **cache** makes a clean build of unchanged code
      **0.37 s (14×)** and a no-op 0.01 s — the CI-re-run / branch-switch win
      `/MP`/unity/PCH can't give (plus distribution via `FBuildWorker`). See
      `samples/fbuild/` + lessons-learned #5.
- [x] **Linker-time profiling** — the link is a *separate phase* no compile
      lever touches. `/INCREMENTAL` patches the exe in place (**2.45×** faster
      relink, 0.033 s vs 0.081 s) at the cost of a fatter binary + no
      `/OPT`/`/LTCG`; `/OPT:REF,ICF` cut the exe ⅓ (777→247 KB); `/LTCG` moved
      codegen to link (**269× slower**, 21.8 s) — the "why release links are
      slow" answer. Symbol count drives both link time and size. Profile with
      `link /time+`. See `samples/link/` + lessons-learned #6.
- [x] **One-page report** — [`REPORT.md`](REPORT.md): the lever table, decision
      framework, and hypotheses (incl. the refuted PCH prediction).
- [x] **Real-workload validation** — re-ran the compile levers on the **bgfx
      renderer core** (a shipping engine, not a fixture), using bgfx's own
      amalgamation as the unity build. Real code flipped the ranking (`/MP`
      **4.64×** > unity **3.86×**), measured unity's incremental cost (**15×** on
      a trivial edit), and showed bgfx is front-end-bound (`/Bt+` 61 % front
      end; `/d2cgsummary` 0 hot functions). See [`samples/bgfx/`](samples/bgfx/).
      Pinned to a VS2019-buildable revision — `setup-bgfx.ps1`.
