# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 7f2dda1 - feat(track4): rung #4 BuildGraph - lyra-pipeline.xml runs compile->cook->package end-to-end

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, and `unreal/.metrics/` are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **20 commits are ahead of `origin/main` (incl. this handoff) - all unpushed. Push them.**

## What was just built (2026-06-04, session 2 - Track 4 rungs #1-#4, the pipeline is DECLARATIVE)
Compile -> cook -> package, then expressed as **one BuildGraph** - the bridge to CI. Each rung has a timed wrapper (tee log to `.logs`, metric JSON to `.metrics`) sharing `_unreal-common.ps1`.
- 7f2dda1 **Rung #4 BuildGraph** - `buildgraph/lyra-pipeline.xml` (`Compile Lyra Editor` -> `Cook Lyra` -> `Package Lyra`, aggregate `Lyra Pipeline`) via `buildgraph-lyra.ps1` (`-ListOnly` validates, real run executes). End-to-end **72.9 s** incremental. Surfaced the `Win64`->`Windows` rename a 3rd time (BuildGraph `<Cook>` is literal where `BuildCookRun` maps it - lesson #4); fixed via a `CookPlatform` option.
- 4cf1664 **Rung #3 package** - `package-lyra.ps1`, runnable **1.72 GB** build -> `D:\LyraPackaged` (90.5 s, reuses cook).
- fa39c68 **Rung #2 cook** - `cook-lyra.ps1`, cold cook **23.9 min / 15,317 shaders / 1.8 GB** (lesson #4 DDC + folder rename).
- d97975e **Rung #1 compile + baseline** - pagefile validated (lesson #1 closed), cold compile **UBA off 83.9 s vs on 108.4 s** (UBA slower single-box, lesson #3), `-Clean` made truly cold (lesson #2).
- **Cold pipeline ~27 min**; warm/incremental via BuildGraph **~73 s**.

## Live edge
The full pipeline is green standalone AND as a declarative BuildGraph that runs end-to-end. On disk: compiled editor + game, cooked content, runnable packaged build at `D:\LyraPackaged\Windows`. Lessons #1-#4 captured. **What's left is wiring the BuildGraph into CI + the version-stamp** - that's infra-heavy and partly manual.

## Next
**Rung #5: run the BuildGraph from TeamCity + version-stamp the package with the P4 changelist** (the track's HEADLINE demoable artifact - "BuildGraph executed from CI emitting a CL-stamped package"). Bigger, infra-dependent, possibly interactive:
1. **Bring infra up:** `docker compose -f ci/docker-compose.yml up -d` (TeamCity server+agents) + `perforce/scripts/start-p4d.ps1` + `perforce/broker/start-broker.ps1`.
2. **Heads-up (SEEDS):** TeamCity sandbox pins `:latest` (drifted to 2026.x). The REST scripts (`bootstrap-builds.ps1`, `setup-vcs-trigger.ps1` were fixed; **`bench-agents.ps1` still has the latent CSRF-on-writes bug** - patch before relying on it). TeamCity first-run (admin account, **agent authorization**) is not fully scripted - expect a manual step or two.
3. **TeamCity build config** that runs `buildgraph-lyra.ps1` (or `RunUAT BuildGraph` directly) on an agent that has UE 5.6 + VS2022 (the agent image needs the MSVC/UE toolchain - cf. the `ci/agent/` Dockerfile-grows-over-time seed).
4. **Version-stamp:** thread the P4 CL into the package (extends the Track-2 version-stamp pattern). The cook log already shows `buildversion=...-CL-44394996` (engine CL) - stamp with the *content* depot CL.
Then **rung #6:** dashboard ingests the `.metrics` cook/package/buildgraph durations.
- *Optional cheap measurement first:* re-run `cook-lyra.ps1` (warm DDC) for the cold-24min vs warm-cook DDC-value story.
