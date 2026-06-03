# Skills Roadmap — Build Engineer practice

Five tracks. Each track produces one concrete artifact you can demo or reference in an interview. Tracks are sequenced so later ones can reuse earlier infrastructure (e.g., track 2 builds the project that track 1 puts in Perforce).

## Track 1 — Perforce sandbox

**Goal:** Be fluent enough with P4 that you can answer "how would you administer Perforce for a 300-engineer studio?" without bluffing.

**Steps:**
1. Install **Helix Core (P4D)** locally on Windows — free for up to 5 users / 20 workspaces.
2. Install **P4V** (visual client) and **P4** (CLI). Configure environment vars (`P4PORT`, `P4USER`, `P4CLIENT`).
3. Design a depot layout for a hypothetical small game: `//depot/main/`, `//depot/release-1.0/`, with subdirs for `Code/`, `Content/Art/`, `Content/Audio/`, `Engine/`, `Tools/`. Note where you would put binary-heavy content vs code.
4. Set up a **stream depot** with mainline / development / release streams. Promote a change up the stream graph.
5. Write a **trigger** (server-side script in Python or batch) that rejects a submit if it touches `//depot/main/Engine/` without a specific changelist description tag. This is real-world studio hygiene.
6. Write a **P4Python** script that: lists pending changelists older than 7 days, prints diff stats, optionally shelves and reverts. Useful muscle for "automate the boring janitor work."
7. Configure a **proxy / broker** on a second machine (or VM) to understand how studios serve geographically distributed teams.

**Artifact:** `perforce/` subdir in this repo with depot-layout doc, the trigger script, the P4Python tool, and a README explaining the workspace design choices.

## Track 2 — CI/CD wiring

**Goal:** Demonstrate building a non-trivial dependency graph of build configurations, with artifact handoff between them.

**Pick one:** TeamCity (widely used across AAA studios) or Jenkins (more ubiquitous, easier to docker-compose). TeamCity is the higher-leverage choice for this role.

**Steps:**
1. Run **TeamCity Server + one Build Agent** in Docker on Windows.
2. Wire it to the Perforce depot from track 1 (TeamCity has first-class P4 VCS support).
3. Build a sample non-trivial C++ project (any reasonable open-source: a small game framework, raylib demo, BGFX sample). MSBuild on Windows.
4. Create at least four chained build configs:
   - `Compile` — produces a build artifact.
   - `Smoke Test` — depends on Compile, runs a unit test exe, fails the chain on non-zero exit.
   - `Cook Data` — runs a (stub) Python script that "cooks" content with timestamps, produces a `data.pak`.
   - `Package` — depends on Compile + Cook Data, zips a release candidate, version-stamps it with the P4 changelist number.
5. Add **build failure notifications** (Slack webhook or local file write — doesn't matter, just wire the hook).
6. Write a small **dashboard page** (static HTML pulling TeamCity REST API) that shows last 10 builds + duration + status.

**Artifact:** `ci/` subdir with TeamCity Kotlin DSL definitions (or Jenkinsfile if you pick Jenkins) checked in, the dashboard, and a README diagramming the chain.

## Track 3 — Build acceleration

**Goal:** Be able to cut a clean-build time on a non-trivial C++ project measurably, and explain what you did.

**Steps:**
1. Take a real medium-size C++ codebase (e.g., a fork of bgfx, or a sizable opensource engine like Godot or O3DE — but keep scope tight; pick one module).
2. Measure baseline: cold clean build, warm rebuild, single-file edit rebuild. Use MSBuild detailed logging or `/Bt+` / `/d2cgsummary`.
3. Apply incremental wins, measuring after each:
   - **Unity / jumbo builds** (merge `.cpp` files for compile speed at the cost of recompile granularity).
   - **PCH** review — is the precompiled header doing real work or just bloating includes?
   - **`/MP` parallel cl** on MSVC.
   - **FASTBuild** as the orchestrator (free, open source, the build accelerator the public AAA world actually documents publicly — Ubisoft, etc.).
   - **Optionally:** Incredibuild trial if you want to compare commercial.
4. Profile linker time separately. Watch for symbol bloat; consider `/INCREMENTAL`, hot reload tradeoffs.
5. Write up a one-page report: numbers, hypotheses, what worked, what didn't.

**Artifact:** `accel/` subdir with the modified build config, FASTBuild `.bff` files, and the report.

## Track 4 — Unreal build pipeline

**Goal:** Understand the Unreal-specific build vocabulary (UBT, UAT, BuildGraph, Horde) because half the AAA-build-engineer world speaks it natively. Even though many AAA engines aren't Unreal, fluency here is a strong cross-training signal.

**Steps:**
1. Install a recent Unreal Engine (5.x).
2. Read enough source to know: what `UnrealBuildTool` (UBT) is, what `UnrealAutomationTool` (UAT) is, how a `.uproject` becomes a packaged build.
3. Make a tiny C++ project; package it for Windows from the command line via `RunUAT.bat BuildCookRun`.
4. Write a **BuildGraph XML** script that does: sync, build editor, run unit tests, cook content, stage, package. This is the format Epic uses internally and the format a "Build Engineer at an Unreal studio" lives in.
5. **Stretch:** Stand up **Horde** (Epic's open-source build orchestrator that ships with UE5.x). Connect an agent. Run a BuildGraph through Horde.

**Artifact:** `unreal/` subdir with the BuildGraph script and a README explaining what each node does.

## Track 5 — Data/asset pipeline + tools

**Goal:** Show you can think like the "data" half of "databuild engineer" — incremental cooks, dependency tracking, content authoring UX.

**Steps:**
1. Define a tiny fake asset format — say JSON descriptions of "characters" that reference "textures" (PNG files) and "audio clips" (WAV files).
2. Write a **Python cooker** that:
   - Scans an input directory.
   - Computes a dependency graph (character → textures → source PNGs).
   - Cooks textures (resize, mip generation via Pillow), bakes audio (downmix, compress), serializes characters to a binary format.
   - Caches output by content hash so unchanged inputs don't recook.
   - Writes a manifest (`.toc`) of cooked artifacts.
3. Wrap the cooker behind a **C# WPF tool** (mirroring a common AAA studio tool stack — WPF, .NET) that lets an artist:
   - Pick an input folder.
   - See the dependency graph.
   - Trigger a cook with progress.
   - See output sizes and stale entries.
4. Hook the cooker into the CI from track 2 as the `Cook Data` job.

**Artifact:** `pipeline/` subdir with the cooker, the WPF tool, sample assets, and a video / GIF of it working.

---

## Cross-cutting practice

- **Read** the [Unreal Build Tool source](https://github.com/EpicGames/UnrealEngine/tree/release/Engine/Source/Programs/UnrealBuildTool) (requires GitHub-Epic linkage) — it's a real-world example of a custom C# build system.
- **Read** [FASTBuild documentation](https://www.fastbuild.org/docs/home.html) — short, dense, written by ex-Ubisoft build engineer.
- **Watch** GDC talks tagged "build" / "tools" / "engine programming." Many are free on the GDC Vault YouTube channel.
- Pick up working vocabulary: *unity build, jumbo build, PCH, link-time codegen, ODR violation, distributed build, content hashing, deterministic build, hermetic build, asset cooking, content-addressable storage, change-list, shelved CL, stream graph, edge server, broker, automation graph.*

## Skill self-check — questions to answer fluently

By end of track 2 you should be able to answer:
- How do you debug a flaky CI build that fails 1 in 20 runs only on one agent?
- What's the difference between a clean build and a rebuild, and when do you force a clean?
- How do you stop one team's broken commit from blocking everyone else's iteration?

By end of track 3:
- Walk me through cutting a 25-minute clean build to 12 minutes. What's the order of operations you try?
- What does Incredibuild actually do, and what does it *not* help with?

By end of track 5:
- An artist says "my texture isn't showing up in game." How does your pipeline help them diagnose where in the chain it broke?
