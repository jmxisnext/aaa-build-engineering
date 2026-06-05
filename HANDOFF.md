# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 4cf1664 - feat(track4): rung #3 package - package-lyra.ps1 + runnable 1.72GB Lyra build

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, and `unreal/.metrics/` are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **18 commits are ahead of `origin/main` (incl. this handoff) - all unpushed. Push them.**

## What was just built (2026-06-04, session 2 - the compile->cook->package ladder, rungs #1-#3)
The Track 4 compile -> cook -> package pipeline is **green end-to-end with real, timed artifacts.** Each rung has a wrapper script (timed, tee log to `.logs`, metric JSON to `.metrics`) sharing `_unreal-common.ps1` discovery.
- 4cf1664 **Rung #3 package** - `package-lyra.ps1` (`BuildCookRun -build -skipcook -stage -pak -archive`). Builds the **LyraGame** target (rung #1 built only the editor; a runnable package needs the game `.exe`), reuses the cook, paks to IoStore, archives to **`D:\LyraPackaged`**. **90.5 s** -> runnable **1.72 GB** build: `LyraGame.exe` (336.8 MB) + `pakchunk0-Windows.ucas` (485.9 MB) + content paks.
- fa39c68 **Rung #2 cook** - `cook-lyra.ps1` (`BuildCookRun -cook -skipstage`). Cold Win64 cook **1432 s (~23.9 min)**, 15,317 shaders, 1.8 GB to `Saved\Cooked\Windows`. Lesson #4 (Win64->Windows folder rename; `UE-LocalDataCachePath` redirects only the Local DDC node).
- d97975e **Rung #1 compile + baseline** - pagefile validated (commit 31->95 GB, UBA-on zero OOM, lesson #1 closed). Cold compile (423 actions, MPA=8): **UBA off 83.9 s vs on 108.4 s** -> UBA ~29% slower single-box (lesson #3). `-Clean` was clean-only (lesson #2) -> now clears Intermediate+Binaries project-wide.
- **End-to-end cold pipeline (clean -> packaged): ~27 min** (compile 84 s + cook 24 min + package 90 s).

## Live edge
On disk now: compiled `LyraEditor` + `LyraGame` (`G:\...\Binaries\Win64`), cooked content (`Saved\Cooked\Windows`, 1.8 GB), and a **runnable packaged build at `D:\LyraPackaged\Windows`** (128 files, 1.72 GB; `LyraGame.exe` not yet smoke-launched - that's a manual double-click check). DDC across `D:\UE-DDC` (0.43 GB) + project DDC on G: (1.12 GB). The three command-line rungs are demoable; what's left is wiring them into CI.

## Next
**Rung #4: author the pipeline as a BuildGraph `.xml`** (`RunUAT BuildGraph -Script=... -Target=...`). Wrap the three rungs as BuildGraph nodes (Compile -> Cook -> Package) with the cooked/staged dirs as shared outputs. Validate by running it locally (`-ListOnly` first to print the graph, then a real run). This is the bridge from "three scripts" to "one declarative pipeline CI can run."
Then: **rung #5** run the BuildGraph from **TeamCity**, and **version-stamp the package with the P4 changelist** (the track's headline artifact, extends the Track-2 version-stamp). **rung #6** dashboard ingests the `.metrics` cook/package durations. These need infra up:
- CI/P4: `docker compose -f ci/docker-compose.yml up -d` + `perforce/scripts/start-p4d.ps1` + `perforce/broker/start-broker.ps1` (note SEEDS: `bench-agents.ps1` + REST scripts may have the TeamCity 2026.x CSRF-on-writes bug - patch before relying on them).
*Optional cheap measurement:* re-run `cook-lyra.ps1` now (warm DDC) for the cold-24min vs warm-cook DDC-value story.
