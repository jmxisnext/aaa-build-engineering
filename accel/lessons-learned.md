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

**What happened:** Compiling 32 deliberately-heavy TUs went **20.27 s → 5.10 s**
just by adding `/MP` — a **3.97×** speedup on a 16-logical-core box, with no
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
| serial (per-TU) | 20.27 s | 1.00× |
| `/MP` (per-TU) | 5.10 s | 3.97× |
| **unity (1 file)** | **0.72 s** | **28.15×** |
| unity ×8 + `/MP` | 1.49 s | 13.60× |

The surprise: **unity on a single core (0.72 s) beat unity-chunked across 16
cores (1.49 s), and crushed `/MP` (5.10 s).**

**Why:** `/MP` parallelizes the work; unity *removes* it. The redundant cost
isn't only parsing `heavy.h` — `/Bt+` puts a per-TU compile at ~50 % front-end
(parse + template instantiation, ~0.35 s) and ~50 % back-end (`/O2` optimize +
codegen, ~0.36 s). Every per-TU build re-instantiates and re-optimizes the same
STL template machinery (`std::regex`, the `map_churn<...>` instantiations) — 32
times. A unity build `#include`s all 32 TUs into one compile, so that shared
machinery is instantiated and optimized **once**. When the bottleneck is
redundant work, doing it once on one core beats doing it 8× across cores
(chunked unity) or 32× across cores (`/MP`). The "obvious" sweet spot (chunk
*and* parallelize) only wins when the *per-TU-unique* work is big enough to
parallelize — here it's tiny, so plain unity wins outright.

**The caveat that makes this honest:** the fixture's redundant cost is template
instantiation + optimization (proven in lesson #4 — PCH, which removes the
*parse* but not the instantiation/codegen, barely helped). Real code has
substantial *per-TU-unique* codegen that `/MP` and chunked-unity genuinely
parallelize, so on a real codebase the ranking shifts back toward
chunked-unity+`/MP`. The transferable skill isn't "unity wins" — it's **profile
where the time goes (`/Bt+`, `/d2cgsummary`), then pick the lever that attacks
that cost.**

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

**Interview-ready bullet:** *"On a build dominated by redundant template
instantiation, a unity build gave ~28× by compiling the shared STL machinery
once instead of per-TU — beating `/MP`'s 4× outright, because eliminating
redundant work beats parallelizing it. But that's fixture-specific: real
per-TU-unique codegen parallelizes, so you tune unity *chunk size* (clean-build
speed vs incremental granularity) and watch for the ODR violations unity
surfaces. The real skill is profiling where build time goes (`/Bt+`) before
reaching for a lever."*

## 4. PCH caches the *parse*, not instantiation or codegen — know what your time is

**What happened:** Adding a precompiled header to the same benchmark barely
moved the needle:

| config | best | vs serial |
|---|---|---|
| `/MP` (per-TU) | 5.10 s | 3.97× |
| PCH clean + `/MP` | 4.61 s | 4.40× |
| PCH warm + `/MP` | 4.37 s | 4.64× |
| unity (1 file) | 0.72 s | 28.15× |

I expected PCH+`/MP` to approach unity (both "parse the header once"). It
didn't — PCH landed barely above plain `/MP`, ~6× short of unity. ("warm" =
the `.pch` is prebuilt and reused, the realistic steady state; "clean" rebuilds
it inside the timed region.)

**Why (this corrects lesson #3's first guess):** `/Yc` compiles the prefix
header into a `.pch` that caches the **parsed declaration state**; `/Yu` TUs
reuse it and skip *re-parsing* `heavy.h`. But:
- **Template *instantiation* is not cached.** `map_churn<int,long long>`,
  `std::regex`'s internals, etc. are instantiated where *used* — in every TU —
  and that work stays.
- **Back-end optimization is not cached at all.** `/Bt+` put a per-TU compile
  at ~0.35 s front-end + ~0.36 s back-end; PCH shaves only part of the front
  end (the parse), leaving the instantiation half of the front end *and* the
  whole `/O2` back end to repeat per TU.

So PCH removed only the ~14 % of `/MP`'s time that was pure parsing (5.10 →
4.37 warm). unity removed the redundant instantiation **and** optimization by
compiling the shared machinery once — hence 28×.

**The real-world flip — why PCH is still a top lever:** this fixture is
unusual. Its expensive header is *template-definition* heavy and each TU
*instantiates* those templates, so the cost PCH can't cache (instantiation +
codegen) dominates. Most real PCH wins come from *declaration*-heavy headers
(`<Windows.h>`, big framework umbrellas) that every TU parses but doesn't
re-instantiate — there PCH cancels enormous, genuinely-redundant parse cost.
And critically, PCH keeps **per-TU compilation**, so `/MP` parallelism *and*
incremental rebuilds both survive — whereas unity sacrifices both. Honest
framing: *unity* trades incremental granularity for the biggest clean-build
win; *PCH* speeds builds **without** that trade — when your cost is parse, not
instantiation.

**Why a build engineer cares:** "add a PCH" is folk wisdom; whether it helps
depends entirely on whether your build is parse-bound. The discipline is to
*measure the split* (`/Bt+` front-end vs back-end, `/d2cgsummary` for back-end
detail) before choosing — PCH for parse-bound, unity/jumbo for
instantiation-bound, `/MP` for the free parallel baseline, and the three
compose.

**Interview-ready bullet:** *"I expected PCH to rival unity since both parse the
header once — but PCH got ~4.4× vs unity's 28×, because PCH caches parsed
declarations, not template instantiation or `/O2` codegen, and `/Bt+` showed my
per-TU cost was ~50 % back-end. PCH attacks parse cost and keeps per-TU
granularity; unity attacks redundant instantiation+codegen but merges TUs.
Measure the front/back split before reaching for one."*

## 5. FASTBuild: caching makes the *second* identical build free — what /MP/unity/PCH can't

**What happened:** Same 32 heavy TUs through FASTBuild v1.20
(`accel/scripts/demo-fbuild.ps1`):

| state | best | vs cache-miss |
|---|---|---|
| clean (cache miss) | 5.33 s | 1.00× |
| clean (cache HIT) | 0.37 s | 14.4× |
| no-op (incremental) | 0.01 s | 533× |

**The reframe:** a *cold* FASTBuild (5.33 s) is ~identical to `/MP` (5.10 s) —
it parallelizes by default, so with an empty cache it's just another parallel
compile, and unity (0.72 s) still beats it cold. FASTBuild's reason to exist is
the **content-addressable cache**: each `.obj` is keyed on (preprocessed source
+ compiler + options), so any later build of identical input *retrieves* the
obj (every TU printed `<CACHE>`) instead of recompiling — 0.37 s, 14× faster.
The no-op (0.01 s) is plain dependency tracking.

**Why a build engineer cares:** `/MP`, unity, and PCH each speed up a *single*
compile; none makes the *second identical* compile cheap. Real studio cost is
dominated by exactly those repeats — CI re-running a commit on every push,
branch switches recompiling already-built files, every engineer clean-building
code a teammate already compiled. Point `.CachePath` at a shared network/object
store and those become cross-machine cache hits. That's why the public-AAA
build conversation centers on FASTBuild/Incredibuild-style **caching +
distribution** (`FBuildWorker` turns idle boxes into a compile farm), not just
`/MP`.

**The levers compose, they don't compete:** FASTBuild for the cache + the farm
+ one dependency graph over compile/link/cook; unity or PCH to cut the *cold*
compile that still happens on a cache miss; `/MP` is the within-process
baseline FASTBuild already does for you. The layered answer to "cut a 25-min
build": parallelize (free), remove redundant work (unity/PCH where the profile
says), then stop rebuilding what hasn't changed (cache).

**Gotcha hit building this:** FASTBuild runs child processes in a *hermetic*
environment — it does **not** inherit the shell's env. The build failed until
`Settings.Environment` was handed `PATH` (cl's support DLLs), `INCLUDE`, `TMP`,
and `SystemRoot` from the activated vcvars. Same lesson as #1 (hand the tool its
toolchain, don't assume it) and `ci/lessons-learned.md` #2 (the fresh agent had
no `p4`): hermetic build tools need the environment passed in explicitly — which
is the *feature* that makes cache keys and distributed builds reproducible.

**Interview-ready bullet:** *"FASTBuild cold ≈ /MP — both are parallel compiles
— but its cache made a clean build of unchanged code 14× faster (0.37 s vs
5.3 s), every obj a cache hit. That's the win /MP/unity/PCH can't give: they
speed one compile; the cache makes the second identical compile free, which is
where real CI / branch-switch cost lives. Share the cache path and it's
cross-machine; add FBuildWorker and it's a compile farm. Caveat: it's hermetic,
so you feed it PATH/INCLUDE/etc. explicitly — the same discipline that makes the
cache reproducible."*
