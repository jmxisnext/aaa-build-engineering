# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 494189f - fix(track4): single-line stamp invocation in Lyra CI step

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **`494189f` is committed but NOT yet pushed** (origin/main is 1 behind). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, and `unreal/.metrics/` are gitignored.

## What was just built (2026-06-04, session 4 - rung #5 HEADLINE demo executed live + 3 bugs fixed)
The session goal was "patch the bench-agents CSRF bug + pre-run verify," which expanded into running the full rung-#5 live demo end-to-end. **The headline artifact is now DONE via a real CI run**, not just authored:
- **Live run achieved (no commit - it's a TeamCity build):** build #627 of `AAASandbox_LyraPipeline` ran the full BuildGraph (compile->cook->package Lyra) on a **native Windows agent**, then version-stamped the package with the **live P4 broker changelist (CL 51)** and published `build-info.json` + `Lyra-Win64-Development-CL51.buildinfo.json` as artifacts. `source=teamcity`, `p4_changelist=51`, `build_id=627`. That IS the rung-#5 headline: "BuildGraph executed from CI, emitting a Perforce-changelist-stamped Lyra package."
- 494189f **Backtick bug fix** - the Lyra step's stamp invocation used a backtick line-continuation that TeamCity's PowerShell runner silently dropped (green build, STALE artifact). Collapsed to one line; re-ran green with correct output. Documents lessons #13 (backtick) + #14 (Store-pwsh detector miss) in `ci/lessons-learned.md`.
- 17e13c2 **CSRF fix** (the original ask) - `bench-agents.ps1` was the 3rd write-path script missing the CSRF token; patched and **validated live** (bench-agents -Repeat 3 ran clean: leaf 23s->14s, chain 49s->36s, overlap invariant held). Addendum on lesson #10. *(Already pushed by the human.)*

Three bugs surfaced + fixed during the live run: (1) bench-agents CSRF; (2) the backtick-continuation stamp skip; (3) **Store-installed pwsh invisible to TeamCity's PowerShell-Core detector** - the human installed the pwsh 7 MSI (registry + standard path) so the agent detects Core; the `edition=Core` config runs unchanged.

## Infra state: FULLY TORN DOWN (cold)
Everything is stopped and verified clear (docker daemon down, ports 1666/1667/8111 free, no p4d/broker, no agent java). The **native Windows agent install persists on disk at `C:\TeamCityAgent`** (console agent, runs as the human; portable Temurin 21 JRE at `C:\TeamCityAgent\jre` because the agent zip ships none). See auto-memory `native-windows-teamcity-agent`. Docker bind-mounted data under `ci/data/` persists, so a restart keeps the wizard/chain/Lyra config.

**To bring it back up:** Docker Desktop -> `docker compose -f ci/docker-compose.yml up -d` -> `perforce/scripts/start-p4d.ps1` -> `perforce/broker/start-broker.ps1` -> start the agent (`agent.bat start` run from `C:\TeamCityAgent\bin`, cwd must be `bin`). The agent re-authorizes itself (identity persists in its conf).

## Live edge
Rung #5 is **complete and demoed live**. Nothing is running (all cold). The only loose thread is the unpushed commit `494189f` - run `! git push origin main`.

## Next
1. **Push:** `! git push origin main` (gets `494189f` to origin).
2. **Rung #6 - the metrics dashboard:** ingest the `.metrics` JSONs (cook/package/buildgraph/stamp durations from `unreal/.metrics/`, build chain timings) into a small dashboard. This is the next net-new *capability* (data -> visualization), and the stamp run already emits a metric JSON per the wrapper convention.
- **Heads-up (open seed):** the native-agent bring-up (drop JRE, verify pwsh Core, write `buildAgent.properties`, start, authorize via REST) is currently all manual - worth scripting into `ci/scripts/setup-win-agent.ps1` for reproducibility before relying on it again.
