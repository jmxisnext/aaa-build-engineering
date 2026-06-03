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

**What happened:** Compiling 16 deliberately-heavy TUs went **10.02 s → 2.54 s**
just by adding `/MP` — a **3.94×** speedup on a 16-logical-core box, with no
code change. Stable across reps (serial 10.34/10.02/10.05; parallel
2.54/2.54/2.58), so it's a real number, not a lucky run. Reproduce with
`accel/scripts/demo-mp.ps1`.

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
