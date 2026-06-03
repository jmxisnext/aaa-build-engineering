# accel/ — Track 3: build acceleration

**Goal (roadmap):** cut a clean-build time on a non-trivial C++ project
*measurably*, and be able to explain what you did and why — in build-engineer
vocabulary (`/MP`, unity build, PCH, FASTBuild, link time).

Track 3 starts with a prerequisite the earlier tracks quietly assumed: **a
C++ compiler you can actually invoke from a script.** On Windows that is not
free — MSVC ships gated behind a "Developer Command Prompt." This dir first
makes the toolchain activatable and *proven*, then layers measured
acceleration wins on top.

## What's here

| Path | What |
|---|---|
| `scripts/activate-msvc.ps1` | Locates the newest MSVC via `vswhere`, imports its `vcvars64` environment into the current PowerShell session. **Dot-source it.** |
| `scripts/smoke-build.ps1` | Activates the toolchain, compiles + runs `samples/hello`, asserts the output. The "compiler works" proof — exits non-zero on failure, so CI can gate on it. |
| `samples/hello/` | Smallest program that proves compile + run (prints `_MSC_VER`). |
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

- [ ] **`/MP` parallel compilation** — measure serial vs parallel `cl` on a
      multi-TU build. The first free win.
- [ ] **Unity / jumbo build** vs per-TU compilation.
- [ ] **PCH** review — is the precompiled header doing real work?
- [ ] **FASTBuild** as orchestrator (the accelerator the public AAA world
      documents — Ubisoft et al.).
- [ ] Linker-time profiling (`/INCREMENTAL`, symbol bloat).
- [ ] One-page report: numbers, hypotheses, what worked, what didn't.
