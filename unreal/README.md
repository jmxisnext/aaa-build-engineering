# Track 4 — Unreal build pipeline

**Phase 2, Step 1** (sequenced foundation-first — see `../ROADMAP_NEXT.md`). *Workload tier injection #2: Lyra.*

## Goal

Speak the Unreal build vocabulary natively (UBT, UAT, BuildGraph, Horde) by driving a real,
recognizable game (Lyra) through compile → cook → package from the command line, then authoring
it as a BuildGraph and running it from the CI we already have.

## Demoable artifact (the win condition)

Lyra **compiled → cooked → packaged** by a **BuildGraph XML** script, executed **from TeamCity**,
emitting a **CL-version-stamped package** (extends the Track 2 version-stamp pattern), with the
**dashboard ingesting the cook/package durations**.

## Smallest runnable first slice (loop on this first)

**Lyra compiles via UBT from the command line.** Then grow outward, one runnable step at a time:

1. UBT compiles `LyraEditor` (Development, Win64) — *first green.* ✅ **DONE 2026-06-04.** Cold baseline captured (423 actions, MPA=8): **UBA off 83.9s · UBA on 108.4s** — UBA is *slower* on a single box (lesson #3); commit-limit fight along the way (lesson #1); `-Clean`-isn't-cold trap (lesson #2).
2. `RunUAT BuildCookRun` — cook content for Win64. ✅ **DONE 2026-06-04** via `cook-lyra.ps1` (cold cook **23.9 min**, 15,317 shaders, 1.8 GB cooked; DDC on `D:` → lesson #4).
3. `RunUAT BuildCookRun` — stage + package a shippable build. ✅ **DONE 2026-06-04** via `package-lyra.ps1` (build `LyraGame` + stage + pak + archive, **90.5 s** reusing the cook; **1.72 GB** runnable build → `D:\LyraPackaged`).
4. Author the above as a **BuildGraph** (`.xml`) — `RunUAT BuildGraph`. ✅ **DONE 2026-06-04** — `buildgraph/lyra-pipeline.xml` (Compile→Cook→Package nodes) runs end-to-end via `buildgraph-lyra.ps1` (**72.9s** incremental; surfaced the cook-platform rename a 3rd time → lesson #4).
5. Wire the BuildGraph into a **TeamCity** build config; version-stamp with the P4 CL. ✅ **DONE 2026-06-04** (`923f0d3` — `stamp-lyra-package.ps1` + TeamCity Lyra config; package stamped with the CI build's P4 CL).
6. Feed cook/package durations into the dashboard. ✅ **DONE 2026-06-04** (`8cb39c6` — dashboard Track-4/Unreal panel ingests `unreal/.metrics`).

## Prerequisites

Run the gate-check anytime to see what's still red:

```powershell
pwsh -File unreal/scripts/check-prereqs.ps1
```

| Prereq | How to get it |
|---|---|
| **Visual Studio 2022** + "Game development with C++" (MSVC v14.3x, Win SDK, .NET 8) | `winget install Microsoft.VisualStudio.2022.Community` then add the **NativeGame** workload (UE 5.4+ needs VS2022 — 2017/2019 are too old). |
| **Unreal Engine 5.x** (~115 GB) | Epic Games Launcher → *Unreal Engine* → install (recommend latest stable, e.g. **5.6**) **to `G:\`**. Requires Epic login. |
| **Lyra Starter Game** (~25 GB) | Launcher → *Samples* / *Learn* → **Lyra Starter Game** → *Create Project* (match the engine version) → install **to `G:\`**. Requires Epic login. |

## Drive plan (RAM is the binding ceiling — serialize heavy stacks)

- **UE5 engine + Lyra project + installs-to-keep → `G:\` (NVME_DURABLE, NVMe).**
- **DDC + cook/build scratch → `D:\` (NVME_SCRATCH, NVMe).** Set `UE-LocalDataCachePath` / `-ddc` here.
- Source (this repo) → `J:\` (Dev Drive). Keep heavy build I/O off `C:`.
- 31 GB RAM: don't run UE + Horde + TeamCity + Docker concurrently. The 3060 12 GB runs the
  Lyra editor comfortably; CitySample is RAM-tight.

## Status

- **2026-06-04:** Prereqs **3/3 green** — VS2022 17.14 · UE 5.6.1 (`G:\UnrealEngine\UE_5.6`) ·
  Lyra (`G:\UnrealProjects\LyraStarterGame\Lyra.uproject`). **Slice #1 DONE + cold baseline
  captured.** `LyraEditor` (Win64/Development) compiles green via `compile-lyra.ps1`, producing
  real editor module DLLs (`UnrealEditor-LyraGame.dll`, `-LyraEditor.dll`, + plugin DLLs) and
  `LyraEditor.target`. Installed engine → a cold build is **423 actions** (Lyra game + plugin
  modules only; engine is prebuilt).

  **Cold compile baseline** (7800X3D 8c/16t, `MaxParallelActions=8`, post-reboot stable box):

  | Config | Wall clock | Action phase | Overhead |
  |---|---|---|---|
  | UBA **off** (`-NoUBA`) | **83.9 s** | 78.9 s | ~4.8 s |
  | UBA **on** | **108.4 s** | 80.7 s | ~26.7 s |

  **UBA is ~29% slower on a single machine** — its win is distributing to remote agents (Horde);
  with none configured you pay ~22 s of server/CAS/detour setup for no parallel gain (lesson #3).
  So `-NoUBA` is the right default *on this box*; UBA gets re-evaluated once there's an agent pool.

  **Durable pagefile fix validated:** rebooted → commit limit **31 → 95 GB** (64 GB pagefile on
  `D:`); UBA-on cold build now runs with **zero OOM** (lesson #1 closed). **Measurement gotcha
  fixed:** UBT's `-Clean` is clean-*only* (a 7.3 s "success" that compiled nothing) — the script's
  `-Clean` now clears `Intermediate\Build`+`Binaries` project-wide to force a true cold build
  (lesson #2).

  **Rung #2 (cook) DONE** via `cook-lyra.ps1` (`RunUAT BuildCookRun -cook -skipstage`): cold cook
  **1432 s (~23.9 min)**, **15,317 shaders**, **1.8 GB** cooked to `Saved\Cooked\Windows`
  (9,063 files), 0 errors. Cook time is shader-compile-bound → a warm DDC is the lever. Local DDC
  pointed at `D:` (0.43 GB) but the project DDC node still wrote 1.12 GB to `G:` — all on NVMe,
  C: untouched; full DDC consolidation is a follow-up (lesson #4 — incl. the `Win64`→`Windows`
  cooked-folder rename).

  **Rung #3 (stage + package) DONE** via `package-lyra.ps1` (`BuildCookRun -build -skipcook -stage
  -pak -archive`): builds the `LyraGame` target (rung #1 was the *editor*; a runnable package needs
  the game `.exe`), reuses the rung #2 cook, paks into IoStore (`.ucas`/`.utoc`), archives to
  `D:\LyraPackaged`. **90.5 s**, producing a **runnable 1.72 GB build** — `LyraGame.exe` (336.8 MB)
  + `pakchunk0-Windows.ucas` (485.9 MB) + content paks + CEF. Cook reuse (`-skipcook`) is why it's
  90 s, not another 24 min.

  **End-to-end cold pipeline (clean → packaged): ~27 min** = compile editor 84 s + cook 24 min +
  package 90 s. The compile→cook→package ladder is green with real, timed artifacts.

  **Rung #4 (BuildGraph) DONE** — `buildgraph/lyra-pipeline.xml` expresses the three rungs as
  declarative nodes (`Compile Lyra Editor` → `Cook Lyra` → `Package Lyra`, aggregate `Lyra Pipeline`)
  run via `buildgraph-lyra.ps1` (`-ListOnly` validates the graph; a real run executes it). End-to-end
  **72.9 s** incremental (editor up-to-date, warm-DDC cook, content re-paked + archived). The real
  run surfaced the `Win64`→`Windows` rename a *third* time — the BuildGraph `<Cook>` task is literal
  where `BuildCookRun` is forgiving (lesson #4). This is the bridge from three scripts to one pipeline
  TeamCity can drive. ✅ **rung #5 DONE** (`923f0d3`) — the graph runs from **TeamCity**, version-stamping the
  package with the P4 changelist (the track's headline artifact); ✅ **rung #6 DONE** (`8cb39c6`) — the dashboard ingests
  the `.metrics` cook/package durations.

- **2026-06-11:** **Horde (Phase 2 Step 2) smallest slice DONE** — a local Horde Server + one agent
  ran the unmodified `lyra-pipeline.xml` Compile node to Success via the Local executor (405 UBT
  actions). Same graph, second orchestrator. Setup, config, and the three LocalExecutor-on-installed-
  engine workarounds: **[`horde/README.md`](horde/README.md)**.
