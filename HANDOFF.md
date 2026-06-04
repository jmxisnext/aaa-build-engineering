# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: d97975e - feat(track4): honest cold LyraEditor baseline + true -Clean cold rebuild

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, and `unreal/.metrics/` are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **14 commits are ahead of `origin/main` (incl. this handoff) - all unpushed. Push them.**

## What was just built (2026-06-04, session 2)
- d97975e **Cold `LyraEditor` baseline captured + `-Clean` fixed.** Rebooted first -> pagefile active, **commit limit 31 -> 95 GB** (64 GB on `D:`); the UBA-on cold build now runs with **zero OOM** - lesson #1 closed, durable fix validated end-to-end.
  - **Cold compile baseline** (423 actions, `MaxParallelActions=8`, stable box, 7800X3D 8c/16t): **UBA off `83.9s`** vs **UBA on `108.4s`** -> **UBA is ~29% SLOWER on a single machine.** Compile-action time is within ~2s either way; the whole gap is UBA's ~22s fixed server/CAS-storage/detour overhead that never amortizes with **no remote agents**. UBA is a scale-out tool (Horde), not a single-box speedup -> `-NoUBA` is the right default here (lesson #3).
  - **The old "3.6s" / today's "7.3s" were NOT cold builds.** UBT's `-Clean` is **clean-only** - it removes target binaries but leaves obj/PCH + the action makefile, so the next build relinks in seconds and reports "SUCCEEDED" having compiled nothing (empty `Binaries`, zero `.obj` = the tell). `compile-lyra.ps1 -Clean` now forces a genuinely cold build by clearing `Intermediate\Build` + `Binaries` **project-wide (root AND every plugin)** (lesson #2). Metric JSON now records `noUBA` + `maxParallel`.

## Live edge
Track 4 **slice #1 is fully done with an honest cold baseline** (replacing the mislabeled 3.6s). `LyraEditor` compiles to real DLLs (`UnrealEditor-LyraGame.dll`, `-LyraEditor.dll`, + plugin DLLs) and `LyraEditor.target`; the project is currently left in a compiled **UBA-off** state. The accelerator on/off comparison is recorded with the nuanced finding. The compile rung of the compile -> cook -> package ladder is closed.

## Next
**Rung 2: cook.** `RunUAT BuildCookRun` to cook Lyra content for **Win64**. Point DDC + cook scratch at **`D:`** (NVMe) per the drive plan (`-ddc=...`, `UE-LocalDataCachePath`). This is likely the first heavy disk/RAM step - commit is fine now (95 GB), but watch `D:` free space and physical RAM. Natural next artifact: a **`cook-lyra.ps1`** wrapper mirroring `compile-lyra.ps1` (time + tee log to `.logs` + metric JSON to `.metrics`). Then: rung 3 stage+package -> rung 4 author as **BuildGraph** (`.xml`, `RunUAT BuildGraph`) -> rung 5 wire into **TeamCity** (version-stamp with P4 CL) -> rung 6 dashboard ingests cook/package durations. To restart CI/P4 infra if needed: `docker compose -f ci/docker-compose.yml up -d` + `perforce/scripts/start-p4d.ps1` + `perforce/broker/start-broker.ps1`.
