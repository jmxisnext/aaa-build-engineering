# Unreal lessons learned (Track 4)

Real-world gotchas hit standing up the Unreal build pipeline (Lyra on UE 5.6).
Each is the kind of thing an interviewer might phrase as *"tell me about a build
you had to debug / tune for the hardware you were on."*

## 1. Lyra clean-compile failed on *commit-limit* exhaustion, not RAM

**What happened:** First cold `LyraEditor` (Win64/Development) build via `Build.bat`
failed at `[414/423]` with:

```
c1xx: error C3859: Failed to create virtual memory for PCH
c1xx: fatal error C1076: compiler limit: internal heap limit reached
Result: Failed (OtherCompilationError)   (exit 6)
```

UBA logged `memory pressure` waits the whole way (`Available: 5.7gb / Total: 33.5gb`),
so it *looked* like a classic out-of-memory.

**Wrong first fix (instructive):** Assumed too much parallelism for 31 GB RAM and capped
`-MaxParallelActions` 16→8. **It still failed — this time with 10–12 GB physical RAM
free.** That free-RAM-at-failure was the tell: the bottleneck was never physical RAM.

**Root cause:** `C3859`/`C1076` are *virtual-memory / commit* failures, not physical-RAM
exhaustion. This box had the **Windows pagefile disabled**, so the system **commit limit
= physical RAM (31.2 GB)** with zero headroom (`Win32_OperatingSystem.TotalVirtualMemorySize`
== `Win32_ComputerSystem.TotalPhysicalMemory`; `AutomaticManagedPagefile = False`). On top
of that, **Docker Desktop's WSL2 VM** was holding ~13 GB of commit. UBA reserves a large
virtual-address block too. Between them, the parallel `cl.exe` PCH allocations (each PCH
commits a big contiguous region) tipped over the commit limit — even though "Available RAM"
looked fine. **Free physical RAM ≠ available commit when there is no pagefile.**

**Fix (what made it green):**
1. **Close Docker Desktop** — frees the commit its WSL2 VM was holding.
2. **`-NoUBA`** — drop Unreal Build Accelerator's large VA reservation (we don't need UBA
   for a plain compile; it's a deliberate Phase 2 *Step 2* demo).
   Build then succeeded with `-MaxParallelActions=8 -NoUBA`.

**Durable fix (the proper answer, APPLIED 2026-06-04):** **Enable a pagefile.** Set a fixed
**64 GB pagefile on `D:`** (NVMe scratch) via the `PagingFiles` registry value
(`D:\pagefile.sys 65536 65536`). Fixed (initial = max) avoids auto-growth lag under sudden
commit bursts. This unpins the commit limit from physical RAM (31 GB → ~95 GB after reboot)
and lets UBA + Docker + a clean build coexist without juggling. Takes effect on **reboot**.
(Tradeoff: a pagefile only on D: — none on C: — means no automatic kernel crash dump; fine
for a build box.)

**Why a build engineer cares:**
- On Windows, **commit charge — not "Available RAM" — is what kills PCH-heavy parallel C++
  builds.** Task Manager's available-memory number is a red herring for these failures.
- Three different things silently eat commit: **pagefile policy** (disabled → no headroom),
  **VM/container memory** (Docker/WSL2, Hyper-V), and **build-accelerator VA reservations**
  (UBA). A build farm has to budget commit, not just cores/RAM.
- Capping parallelism is the *naive* lever (and here it didn't work). The senior move is
  knowing commit-vs-physical-RAM and fixing the actual constraint (pagefile / VM footprint).

**Takeaway:**
- `C3859 "failed to create virtual memory for PCH"` + `C1076 "internal heap limit reached"`
  with free physical RAM = **commit-limit exhaustion**, usually a too-small/disabled pagefile.
- Diagnose with commit limit vs in-use (`Win32_OperatingSystem` Total/FreeVirtualMemory),
  not Task Manager's RAM gauge.
- Fixes, cheapest → most durable: free commit (close VMs/Docker, drop UBA's reservation),
  cap `-MaxParallelActions`, then **add a pagefile** so the commit ceiling isn't physical RAM.

## 2. The "cold baseline" that wasn't: `-Clean` is clean-*only*, and a 7s "success" is a no-op

**What happened:** Post-pagefile, set out to capture the *real* cold `LyraEditor` compile time
(the prior "3.6s" was a known-bad incremental). Ran `compile-lyra.ps1 -Clean` expecting a full
rebuild. It reported **`BUILD SUCCEEDED ... in 7.3s`** — and the script dutifully logged 7.3s as
a clean build. That number is a lie: a cold Lyra editor compile is **423 actions**, not 7 seconds.

**Root cause:** UBT's `-Clean` (as passed to `Build.bat`) **only removes the target's binaries**.
It leaves the per-module `.obj`/PCH *and* the action-graph makefile under
`Intermediate\Build`. On the next build UBT sees a valid makefile, finds nothing out of date,
relinks, and exits "successfully" in seconds. Inspecting disk confirmed it: after the "clean
build," `Binaries\Win64` was **empty** and there were **zero `.obj`** — yet exit code 0. A build
that produces no binaries but reports success is the tell that **nothing actually compiled.**

**Fix (force a genuinely cold build):** delete the project's build outputs, not just the target
binaries — `Intermediate\Build` + `Binaries` at the project root **and under every project
plugin** (Lyra has ~14: `Plugins\GameFeatures\*` plus `GameSettings`, `CommonGame`, `CommonUser`,
`UIExtension`, `PocketWorlds`, …, each with its *own* `Intermediate\Build`). Miss the non-
GameFeatures plugins and ~100 stale `.obj` survive → not a cold build. `compile-lyra.ps1 -Clean`
now does exactly this (clears outputs, then builds) instead of forwarding UBT's clean-only flag.
With that, the cold graph rebuilds from scratch: `Creating makefile ... (no existing makefile)` →
`Building 423 action(s)` → real DLLs (`UnrealEditor-LyraGame.dll`, etc.) + `LyraEditor.target`.

**Why a build engineer cares:**
- **A green build with a suspiciously small number is a measurement bug, not a fast build.** If a
  "from-scratch" compile finishes in seconds, it didn't compile — verify by the *artifacts*
  (action count, fresh binaries on disk), never by the exit code alone.
- **"Clean" is not one operation.** Target-clean (binaries) ≠ intermediate-clean (obj/PCH) ≠
  makefile invalidation. CI "clean build" steps that only delete binaries silently measure
  incremental relinks and report them as cold-cache numbers.
- Build outputs are **scattered per-module/per-plugin**, not in one tree. A reliable clean walks
  every plugin's `Intermediate`/`Binaries`, or you get a partial-cold build with hidden cache hits.

**Takeaway:**
- UBT `-Clean` = remove target binaries only; obj/PCH + makefile survive → next build is a fast
  relink, not a cold compile. Force cold by deleting `Intermediate\Build` + `Binaries` project-wide
  (root **and** every plugin).
- Trust **artifacts over exit codes**: no fresh `.obj` / empty `Binaries` + "SUCCEEDED" = no-op.

## 3. UBA was ~29% *slower* on a single machine — accelerators are scale-out, not free speed

**What happened:** With the commit limit fixed, captured the cold `LyraEditor` baseline both ways
(same 423 actions, `MaxParallelActions=8`, only variable = UBA):

| Config | Wall clock | Action phase (executor) | Non-executor overhead |
|---|---|---|---|
| **UBA on**  | **108.4s** | 80.7s (UBA local executor) | ~26.7s |
| **UBA off** (`-NoUBA`) | **83.9s** | 78.9s (Parallel executor)  | ~4.8s |

UBA on was **+24.5s (~29%) slower.**

**Root cause:** the *compile-action* time is nearly identical (80.7 vs 78.9s — UBA's detouring adds
a hair per action). The entire gap is UBA's **fixed overhead**: spinning up the UBA server
(`UbaServer - Listening on 0.0.0.0:1345`), initialising CAS storage (`Storage capacity 40Gb`),
detour/trace plumbing, and teardown (~22s here). UBA's payoff is **distributing actions to remote
helper agents**; with **none configured**, you pay the coordination tax for zero parallel gain.

**Why a build engineer cares:**
- **An accelerator is a horizontal-scaling tool, not a single-box turbo.** UBA / FASTBuild /
  Incredibuild win when work is farmed to *other machines* (Horde agents). On one box with a short
  (~80s) workload, fixed setup cost dominates and the accelerator loses to the plain parallel
  executor. Adopt UBA **with** a Horde/agent pool, not before.
- **Measure the regime you'll ship.** A toy single-machine benchmark would have "proven" UBA makes
  builds slower — true here, false at farm scale. The honest number comes with its context: cores,
  remote agents (zero), and workload size.
- Earlier (lesson #1) UBA also *cost* via its large VA reservation under a tight commit limit. Same
  theme: an accelerator has real fixed costs (memory, setup) you must earn back with scale.

**Takeaway:**
- Single box, no remote agents: **UBA on 108s vs off 84s** — accelerator overhead (~22s server/
  CAS/detour) isn't amortised; action time was within ~2s.
- UBA/distributed-compile tools pay off **across machines** (Horde). Benchmark in the deployment
  regime, or you'll draw the wrong conclusion.

## 4. First cold cook: 24 min / 15k shaders, and two cook-pipeline gotchas

**What happened:** Rung #2 - cooked Lyra for Win64 via `RunUAT BuildCookRun -cook -skipstage`
(cook-only; staging is rung #3). Cold cook (empty DDC) = **1432s (~23.9 min)**, compiling
**15,317 shaders**, producing **1.8 GB** of cooked output (9,063 files), 0 errors. That ~24 min
is dominated by shader compilation - the cook's real cost and exactly why the DDC matters.

**Gotcha A - the build platform is not the cooked-folder name.** `-platform=Win64` cooks into
`Saved\Cooked\`**`Windows`**, not `...\Win64` (UE renamed the cooked target Win64 -> Windows in
UE5). A `-Clean`/cleanup that deletes `Saved\Cooked\Win64` removes nothing and silently leaves a
warm cook in place - the same "clean that didn't clean" failure mode as lesson #2, one rung up.
`cook-lyra.ps1 -Clean` maps `Win64 -> Windows` so a cold cook is actually cold.

  *Same rename, a third layer (rung #4):* the BuildGraph **`<Cook>` task** passes its `Platform`
  straight to the cook commandlet as `-TargetPlatform=`, with **no mapping** - so `Platform="Win64"`
  fails hard: `LogTargetPlatformManager: Error: Invalid target platform specified (Win64)`. The
  `<Compile>` task and `BuildCookRun` both take the **build** name `Win64`, but `<Cook>` needs the
  **cook** name `Windows`. `BuildCookRun` hides this by mapping internally; the lower-level task does
  not. `lyra-pipeline.xml` carries a separate `CookPlatform=Windows` option for exactly this node.
  Lesson: **`BuildCookRun` is forgiving, the primitive tasks are literal** - know which name each
  layer wants (build vs target/cooked platform).

**Gotcha B - `UE-LocalDataCachePath` only redirects *one* DDC node.** Set it to `D:\UE-DDC` to
keep the heavy shader scratch on NVMe; afterward only **0.43 GB** landed on D:, while **1.12 GB**
went to the *project* DDC (`<Project>\DerivedDataCache`) on `G:`. Both are NVMe and **C: stayed
clean**, so the drive-plan intent (heavy I/O off the system drive) held - but "point the DDC at
D:" is **partial**: UE's DDC is a multi-node graph (Boot/Local/Shared/project), and the env var
overrides only the Local node. Total consolidation needs the project/shared nodes redirected too
(DDC backend graph in `DefaultEngine.ini`, or `UE-SharedDataCachePath`).

**Why a build engineer cares:**
- **Cook time = shader-compile time.** "How long is your cook?" is really "how warm is your DDC
  and how many shader permutations." A shared/network DDC (or Horde's) turning a 24-min cold cook
  into a ~1-min warm cook is the single biggest cook-throughput lever on a team.
- **Platform name mapping bites cleanup and staging scripts** (`Win64` build target vs `Windows`
  cooked/staged folder). Hard-coding the wrong one passes silently until a stale cook ships.
- **"Move the DDC to fast disk" is multi-node**, not one path - verify *where bytes actually
  landed*, don't assume one env var relocated the whole cache.

**Takeaway:**
- Cold Lyra Win64 cook: **~24 min, 15.3k shaders, 1.8 GB** cooked - shader compilation dominates;
  warm DDC is the lever.
- `Win64` (build) cooks to `Saved\Cooked\Windows` (cooked) - mind the rename in clean/stage steps.
- `UE-LocalDataCachePath` moves only the Local DDC node; confirm on disk, the cache is multi-node.

## 5. An empty *shared* DDC stays sparse when the *local* DDC is already warm

**What happened:** configured a shared DDC (`UE-SharedDataCachePath=D:\DDC-Shared` — the Shared
node lesson #4 Gotcha B flagged as still un-redirected) to set up a cold→warm cook demo. With the
shared folder **empty (0 files)**, expected the next Horde cook to be a cold ~24-min fill. Instead
the cook ran in **~108s** and `D:\DDC-Shared` gained only **36 MB / 603 files** — a fast cook AND a
near-empty shared cache, the opposite of the expected cold-fill.

**Root cause:** UE's DDC is a hierarchy (Boot → Local → Shared → …) read in order. This box's
**Local** DDC was still warm from the 2026-06-13 cold cook (lesson #4), so every shader resolved as
a **Local hit** — and a Local hit is **not back-propagated** to the Shared node. The Shared node
only captured the small delta genuinely (re)computed this run. So *empty Shared + warm Local ⇒ fast
cook + sparse Shared.* The "cold→warm via the shared folder" demo is **unobservable on a single box
whose Local DDC is already warm** — a warm second cook would just show ~the same time, no delta.

**Why a build engineer cares:**
- A shared/network DDC's value is **cross-machine**: it lets a *second* machine with a cold Local
  DDC skip shader compile by reading another's results. On one box with one warm Local DDC the
  Shared node is redundant and stays sparse — there's no payoff to demonstrate there.
- To *seed* a Shared DDC you need a producer that **misses Local** (a genuinely cold Local DDC) so
  the compute happens and writes through to Shared. You fill Shared with cold-Local cooks, not warm
  ones.
- **"Empty shared cache" ≠ "cold cook."** Verify the regime by *where the hits resolve* (Local vs
  Shared), not by the shared folder's size.

**Takeaway:**
- Local-DDC hits don't back-fill the Shared node → warm Local + empty Shared still cooks fast and
  leaves Shared sparse. The shared-DDC speedup is a **cross-machine** story.
- Demo it across two machines (or after wiping Local), not two cooks on one warm box. The documented
  cold number stays **24.6 min** (2026-06-13, cold Local).

## 6. The *running* Horde config isn't the repo config — `-set:Source=horde` drift

**What happened:** the in-graph `Stamp Lyra` node (authored 2026-06-21, `c0688df`) is meant to stamp
`source=horde` on Horde runs via the stream template's `-set:Source=horde` argument. The **first
live Horde run after authoring** stamped `build-info.json` with **`source: teamcity` /
`orchestrator: TeamCity`** anyway — under a Horde run.

**Root cause:** Horde reads its stream/template config from **`C:\ProgramData\Epic\Horde\Server\`**,
not from the repo. The repo's `unreal/horde/config/game-main.stream.json` had `-set:Source=horde`,
but that copy was **never redeployed** after 2026-06-21 — the running server executed a **stale**
template (no `-set:Source=horde`), so BuildGraph's `Source` option fell back to its
`DefaultValue="teamcity"`. The offline XML test (`buildgraph-xml.Tests.ps1`) asserts the Stamp node
*exists*; it cannot see that the live server runs a different template than the repo. **Fix:** copy
repo config → `C:\ProgramData\Epic\Horde\Server\`, server hot-reloads the dir, re-run → `source:
horde` (verified 2026-06-22, job `6a3990fc…`, a ~3-min warm re-run).

**Why a build engineer cares:**
- **Config that lives outside the repo drifts.** A build server reads deployed config from its own
  dir; editing the repo copy changes nothing until you redeploy. The gap is invisible to repo-only
  tests and to "the node is present" assertions.
- This is why a **deploy step** (or a repo↔deployed drift check) belongs in the pipeline — the same
  de-risk logic as the preflight's machine-state checks, applied to config.
- A **live run** is the only thing that catches it: "authored + offline-tested" ≠ "works in the
  running system." This is exactly the gated-validation a heavy run exists to perform.

**Takeaway:**
- Horde stream/template edits in the repo don't take effect until copied to
  `C:\ProgramData\Epic\Horde\Server\` (the server hot-reloads that dir).
- Verify orchestrator-specific behavior on a **live run**; offline graph tests can't see
  deployed-vs-repo drift. (Seed: add a repo↔deployed config-drift check to `horde-preflight.ps1`.)
