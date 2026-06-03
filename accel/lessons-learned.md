# Build-acceleration lessons learned (Track 3)

Same numbered format as `perforce/lessons-learned.md` and
`ci/lessons-learned.md` — each entry is the kind of thing an interviewer
phrases as *"tell me about a time you got bitten by the build."* Appended as
they happen, not batched at the end of the track.

## 1. MSVC is installed but not on PATH — vcvars only mutates its own process

**What happened:** From a fresh shell, `cl`, `cmake`, and `ninja` were all
"not found," which reads like *no compiler is installed*. They were wrong:
`vswhere` found two complete MSVC toolchains (VS 2019 Build Tools 14.29 and
VS 2017 Community 14.16). The compiler was never missing — it just wasn't
activated.

**Root cause:** On Windows, MSVC lives behind a "Developer Command Prompt"
that runs `vcvars64.bat`, which prepends the compiler/linker/SDK directories
to `PATH` and sets `INCLUDE` / `LIB` / etc. But `vcvars64.bat` is a batch
file — it mutates the environment of *the `cmd.exe` process it runs in* and
nothing else. Calling it from PowerShell changes a child process that
immediately exits; the calling shell sees no change. So "I ran vcvars and
`cl` still isn't found" is the expected result of running it wrong.

**Fix:** Run vcvars in a `cmd` subshell, dump the resulting environment with
`set`, and replay each `NAME=value` back into the PowerShell session
(`accel/scripts/activate-msvc.ps1`):

```powershell
$dumped = cmd /c "`"$vcvars`" >nul 2>&1 && set"
foreach ($line in $dumped) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_()]*)=(.*)$') {
        Set-Item -Path "env:$($matches[1])" -Value $matches[2]
    }
}
```

Two sharp edges hit while building this:
- **Locate the toolchain with `vswhere`, never a hardcoded path.** `vswhere`
  (always at `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\`) with
  `-latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64`
  returns the newest install that actually has the x64 C++ toolchain — so
  Build Tools 2019 is selected over Community 2017 automatically, and the
  script keeps working across VS upgrades.
- **`cl` exits non-zero when given no input, and PS 7.4+ turns that into a
  thrown error.** With `$ErrorActionPreference = 'Stop'`, a bare `& cl.exe`
  (used to probe the version) aborts the script because
  `$PSNativeCommandUseErrorActionPreference` defaults to `$true` in PS 7.4+.
  Set it to `$false` and check `$LASTEXITCODE` yourself.

**Why a build engineer cares:** This is the same failure class as
`ci/lessons-learned.md` #2 — "Test connection is green but the agent can't
sync because it has no `p4` binary." A build that works on a developer's
machine (their shell is already a Developer Command Prompt) fails on a clean
CI agent that never ran vcvars. The build *step* must activate the toolchain;
relying on a pre-warmed environment is exactly how a green local build turns
into a red agent build. And pin the MSVC version
(`vcvars64.bat -vcvars_ver=14.29`) for reproducible codegen — `-latest` is a
sandbox convenience, not a production guarantee.

**Interview-ready bullet:** *"On Windows the C++ compiler is gated behind
vcvars, which only mutates its own cmd process — so 'cl not found' usually
means 'not activated,' not 'not installed.' Locate it with vswhere, replay
the vcvars environment into your shell, and make the CI build step do the
activation rather than trusting a developer's pre-warmed Developer Command
Prompt. Pin the toolchain version for reproducibility."*

## 2. `/MP` gives a real but sub-linear speedup — know why it's not N×

**What happened:** Compiling 32 deliberately-heavy TUs went **20.22 s → 4.98 s**
just by adding `/MP` — a **4.06×** speedup on a 16-logical-core box, with no
code change. Stable across cold reps, so it's a real number, not a lucky run.
Reproduce with `accel/scripts/bench.ps1` (the `/MP (per-TU)` row).

**Why not 16×** (this is the actual interview question):
- **16 *logical* cores ≈ 8 physical + hyperthreading.** Compilation is
  compute- and memory-bandwidth-bound; HT siblings don't add a full core.
- **`/MP` parallelizes the TUs inside one `cl` process** — the front-end
  distributing work and the per-`.obj` writes are not parallel.
- **Each TU re-parses the same `heavy.h` independently** (no PCH). Parallelism
  *hides* that redundant work but doesn't eliminate it.

**Why a build engineer cares:** `/MP` is the cheapest real win on MSVC (one
flag) and the first thing to reach for. But the follow-up — "you got 4× on 16
cores, why not more?" — is also the roadmap for the *next* wins: **PCH** and
**unity/jumbo builds** remove the redundant header parsing that `/MP` only
parallelizes. And `/MP` (parallel *within* a project) is orthogonal to MSBuild
`/m` (parallel *across* projects) — real builds enable both, and conflating
them is a common misconfiguration (e.g. `/m` × `/MP` oversubscribing cores).

**Interview-ready bullet:** *"`/MP` is a one-flag ~4× on a 16-core box — but
not 16×, because half those cores are hyperthreads, the `cl` front-end and obj
writes aren't parallel, and every TU still re-parses the same headers. That
last point is why PCH and unity builds are the next lever: `/MP` parallelizes
the redundant header work; PCH eliminates it. And keep `/MP` (within-project)
distinct from MSBuild `/m` (across-project) so you don't oversubscribe cores."*

## 3. Unity/jumbo build: *eliminating* redundant work can beat *parallelizing* it

**What happened:** Same 32 heavy TUs, four ways (`accel/scripts/bench.ps1`,
32 TUs / 16 logical cores):

| config | best | vs serial |
|---|---|---|
| serial (per-TU) | 20.22 s | 1.00× |
| `/MP` (per-TU) | 4.98 s | 4.06× |
| **unity (1 file)** | **0.73 s** | **27.70×** |
| unity ×8 + `/MP` | 1.49 s | 13.57× |

The surprise: **unity on a single core (0.73 s) beat unity-chunked across 16
cores (1.49 s), and crushed `/MP` (4.98 s).**

**Why:** `/MP` parallelizes the work; unity *removes* it. Each per-TU compile
re-parses `<regex>` (the dominant cost here) — 32 times. A unity build
`#include`s all 32 TUs into one file, so `#pragma once` makes `heavy.h` parse
**once**. When the bottleneck is redundant parsing, doing it once on one core
beats doing it 8× across cores (chunked unity) or 32× across cores (`/MP`).
The "obvious" sweet spot (chunk *and* parallelize) only wins when there's
enough *per-TU* work to parallelize — which is the caveat.

**The caveat that makes this honest:** the fixture is *header-parse-dominated
by design* (trivial TU bodies). Real code has substantial per-TU codegen that
`/MP` and chunked-unity genuinely parallelize, so on a real codebase the
ranking shifts back toward chunked-unity+`/MP`. The transferable skill is not
"unity wins" — it's **profile where the time goes, then pick the lever that
attacks that cost.**

**Unity's real costs** (not hit here — the fixture is collision-free by
construction):
- **Incremental granularity collapses**: touch one `.cpp` and the whole unity
  blob recompiles. Studios tune unity *chunk size* to balance clean-build
  speed vs incremental pain — which is exactly why the chunked config exists.
- **ODR / symbol bleed**: `static` helpers, anonymous namespaces, `using`
  directives, and `#define`s leak across concatenated TUs. Unity builds
  surface latent ODR violations that per-TU compilation hid.

**Why a build engineer cares:** "cut the 25-min build to 12" is a *profiling*
question, not flag cargo-culting. Unity/jumbo is the biggest single lever when
a few heavy headers are included everywhere (the common AAA case), but it
trades away incremental speed and can expose ODR bugs — so you tune chunk size
rather than going all-in on one blob.

**Interview-ready bullet:** *"On a header-parse-dominated build a unity build
gave ~28× by parsing the shared header once instead of per-TU — beating `/MP`'s
4× outright, because eliminating redundant work beats parallelizing it. But
that's fixture-specific: real per-TU codegen parallelizes, so you tune unity
*chunk size* (clean-build speed vs incremental granularity) and watch for the
ODR violations unity surfaces. The real skill is profiling where build time
goes before reaching for a lever."*
