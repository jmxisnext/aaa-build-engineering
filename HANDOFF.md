# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: fa39c68 - feat(track4): rung #2 cook - cook-lyra.ps1 + cold Lyra cook (24min/15.3k shaders)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, and `unreal/.metrics/` are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **16 commits are ahead of `origin/main` (incl. this handoff) - all unpushed. Push them.**

## What was just built (2026-06-04, session 2 - rungs #1 baseline + #2 cook)
- fa39c68 **Rung #2 (cook) DONE.** `cook-lyra.ps1` (`RunUAT BuildCookRun -cook -skipstage`, mirrors `compile-lyra.ps1`: timed, tee log, metric JSON). **Cold Win64 cook: 1432s (~23.9 min), 15,317 shaders, 1.8 GB** cooked to `Saved\Cooked\Windows` (9,063 files), 0 errors. Lesson #4: (a) `Win64` build platform cooks to the **`Windows`** folder (`-Clean` now maps it); (b) `UE-LocalDataCachePath` redirects only the **Local** DDC node (0.43 GB → `D:`) - the project DDC node still wrote 1.12 GB to `G:`. All on NVMe, **C: untouched**.
- d97975e **Rung #1 cold baseline + `-Clean` fix.** Pagefile validated (commit 31→95 GB, UBA-on cold build zero OOM, lesson #1 closed). **Cold compile (423 actions, MPA=8): UBA off 83.9s vs UBA on 108.4s** → UBA ~29% slower single-box (scale-out tool, lesson #3). `-Clean` was clean-only (7.3s no-op) → now clears Intermediate+Binaries project-wide (lesson #2). Metric JSON records `noUBA`+`maxParallel`.

## Live edge
Compile **and** cook rungs are green with honest numbers. On disk now: UBA-off compiled `LyraEditor` (`G:\...\Binaries\Win64`), cooked Win64 content (`G:\...\Saved\Cooked\Windows`, 1.8 GB), DDC split across `D:\UE-DDC` (0.43 GB) + project DDC on G: (1.12 GB). The cooked output is exactly what rung #3 staging consumes - no re-cook needed (pass `-skipcook`).

## Next
**Rung #3: stage + package.** `RunUAT BuildCookRun -project=... -platform=Win64 -clientconfig=Development -skipcook -stage -pak -archive -archivedirectory=D:\LyraPackaged -nocompileeditor` (reuse the existing cook via `-skipcook`; `-pak` builds .pak, `-archive` lays down the shippable build). Natural artifact: a **`package-lyra.ps1`** wrapper (time + log + metric, archive dir on `D:`), and **version-stamp the package with the P4 changelist** (extends the Track 2 version-stamp pattern - that's the demoable artifact the track is aiming at). Then rung #4 author it all as a **BuildGraph** `.xml` (`RunUAT BuildGraph`) → rung #5 wire into **TeamCity** → rung #6 dashboard ingests cook/package durations.
- *Optional measurement (cheap, compelling):* re-run `cook-lyra.ps1` now that the DDC is warm → cold 23.9 min vs warm cook = the DDC-value story (mirrors the compile cold/warm framing). The `accel/` best-of-3 harness pattern (SEEDS) applies.
- To restart CI/P4 infra if needed: `docker compose -f ci/docker-compose.yml up -d` + `perforce/scripts/start-p4d.ps1` + `perforce/broker/start-broker.ps1`.
