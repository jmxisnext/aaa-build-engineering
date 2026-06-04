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

1. UBT compiles `LyraEditor` (Development, Win64) — *first green.* ✅ **DONE 2026-06-04** (`-NoUBA -MaxParallelActions=8`; commit-limit fight → lesson #1).
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
  Lyra (`G:\UnrealProjects\LyraStarterGame\Lyra.uproject`). **Slice #1 DONE:** `LyraEditor`
  (Win64/Development) compiles green via `compile-lyra.ps1` — editor module DLLs link.
  Working config on this 31 GB / no-pagefile box: **`-NoUBA -MaxParallelActions=8`** (a cold
  build OOM'd on *commit-limit* exhaustion, not RAM — see `lessons-learned.md` #1).
  **Caveat:** the captured 3.6 s was an *incremental* build, NOT a cold baseline — a clean
  `-Clean` rebuild is still owed for the real number. Next rungs: cold baseline → `RunUAT
  BuildCookRun` (cook) → package → BuildGraph → TeamCity.
