# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: b3c708f - ci(track2): resolve bench second-agent by name, not hardcoded id

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Commits here carry **no co-author trailer** (matches the public release). `data/` (TeamCity DB/agent conf) and vendor binaries are gitignored. NB: `git push` is permission-blocked for the agent this session - the human runs `! git push origin main`. Both commits below are already pushed and public.

## What was just built
- `b3c708f` Track 2 - bench hardening: `bench-agents.ps1` resolves the second agent by **name** (`agent-linux-02`) via a new `Get-AgentId` lookup instead of a hardcoded `id=11`, so the "just run it" script survives a fresh DB (`docker compose down -v`). Syntax-checked; not re-run live (stack was already down).
- `678a1b6` Track 2 - **second build agent + parallelism benchmark**. New `teamcity-agent-02` (distinct compose service, own conf/identity volume - NOT `--scale`, which collides on the persisted agent identity). New `ci/scripts/bench-agents.ps1` (`-Repeat N`, median/min/max). Result, median of 5 A/B trials: leaf stage (Smoke Test ‖ Cook Data) **22s -> 11s = 2x**, whole chain 45s -> 34s (~24%), overlap consistent across all 5, near-zero variance. Broker log confirmed agent-02 syncs through `:1667`. lessons #5 (agent-pool sizing tracks DAG width) + #6 (superuser token rotates per process; stale-token tight-loop trips the brute-force lockout). README updated.

## Live edge
Track 2 second-agent increment is **complete and public**. One loose verification thread: the by-name fix (`b3c708f`) was syntax-checked but never exercised live - the stack was shut down before the edit. Sandbox infra (TeamCity x3 containers + p4d + broker) is **STOPPED**, data preserved.

## Next
1. **Pick the next Track 2 lever.** Strongest is the **VCS-change trigger**: add a `<build-triggers>` vcsTrigger to Compile so a P4 submit through the broker (`:1667`) auto-fires the whole chain - closes the end-to-end studio loop and ties Track 1 ↔ Track 2. (Alt: native **Windows agent** for MSBuild - the OS-diversity / separate-host case. Or switch tracks: 1 `policies.d/`, 4 Unreal BuildGraph/Horde, 5 data cooker + WPF tool.)
2. **Bring the stack up first** (any Track 2 work needs it): `perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1`, then `cd ci; docker compose up -d`. Heads-up: on restart TeamCity re-inits for a few min and **rotates the superuser token** - scrape the *last* occurrence from the log *after* init (see lesson #6), and don't tight-loop auth. While up, opportunistically run `pwsh -File .\ci\scripts\bench-agents.ps1 -Repeat 1` to close the by-name verification thread.
