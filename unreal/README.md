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
2. `RunUAT BuildCookRun` — cook content for Win64.
3. `RunUAT BuildCookRun` — stage + package a shippable build.
4. Author the above as a **BuildGraph** (`.xml`) — `RunUAT BuildGraph`.
5. Wire the BuildGraph into a **TeamCity** build config; version-stamp with the P4 CL.
6. Feed cook/package durations into the dashboard.

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
  (lesson #2). Next rungs: **`RunUAT BuildCookRun`** (cook for Win64; point DDC/cook scratch at
  `D:`) → package → BuildGraph → TeamCity.
