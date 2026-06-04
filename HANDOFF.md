# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: ca6f4a1 - docs(track4): record pagefile durable fix applied (64GB on D:)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, and now `unreal/.logs/` + `unreal/.metrics/` are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **10 commits are ahead of `origin/main` this session (`e92a7e4`..`ca6f4a1`) - all unpushed. Push them.**

## What was just built
- ca6f4a1 record pagefile durable fix APPLIED - fixed 64GB on D: (`D:\pagefile.sys 65536 65536`); commit limit 31->~95GB **after reboot**
- e17081b lesson #1 (commit-limit OOM, not RAM) + slice #1 green status in README
- da76060 **LyraEditor compiles GREEN** (`-NoUBA -MaxParallelActions=8`) - editor DLLs link = Track 4 slice #1 DONE
- 0dbd9cd refactor: check-prereqs uses the shared discovery helper (DRY)
- 34b2721 UBT compile wrapper (`compile-lyra.ps1`) + shared `_unreal-common.ps1` discovery helper
- 087c2e5 fix: gate-check finds `Lyra.uproject` (folder=LyraStarterGame, project=Lyra) -> 3/3 GREEN
- ee49a42 UE 5.6.1 installed (2/3) + harden Lyra auto-detection (scan G:)
- 98bede3 VS2022 17.14 installed (1/3 green)
- 87bfda4 scaffold `unreal/` track + runnable prereq gate-check (`check-prereqs.ps1`)
- e92a7e4 sequence Phase 2 foundation-first (Track 4 -> Horde -> Track 5 -> Capstone)

## Live edge
Phase 2 **Step 1 (Track 4 - Unreal) is underway**: prereqs 3/3 green (VS2022 17.14 / UE 5.6.1 @ `G:\UnrealEngine\UE_5.6` / Lyra @ `G:\UnrealProjects\LyraStarterGame\Lyra.uproject`), and **slice #1 of the compile->cook->package ladder is done** - `LyraEditor` compiles via `unreal/scripts/compile-lyra.ps1`. The cold build first OOM'd on **commit-limit** exhaustion (pagefile was disabled -> commit limit pinned to 31GB RAM; Docker's WSL2 VM + UBA's VA reservation ate the headroom; MSVC `C3859`/`C1076`) - see `unreal/lessons-learned.md` #1. Worked around with `-NoUBA`; **durable fix (64GB pagefile on D:) is applied but needs a REBOOT to activate.** Open item: the captured 3.6s was an *incremental* build, NOT a cold baseline - the real number is still owed.

## Next
**Reboot first** (activates the D: pagefile). Then: (1) verify commit limit is ~95GB via `(Get-CimInstance Win32_OperatingSystem).TotalVirtualMemorySize/1MB`; (2) capture the **cold `LyraEditor` baseline properly** now that UBA can run - `compile-lyra.ps1 -Clean` (UBA on) vs `-Clean -NoUBA`, giving a clean accelerator on/off before-after on a stable box; (3) move to the next rung - **`RunUAT BuildCookRun`** to cook Lyra content for Win64 (point DDC/cook scratch at `D:` per the drive plan). To restart CI/P4 infra if needed: `docker compose -f ci/docker-compose.yml up -d` + `perforce/scripts/start-p4d.ps1` + `perforce/broker/start-broker.ps1`.
