# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 39e603b - accel(track3): /MP parallel-compilation benchmark

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. History was flattened for the public release on 2026-06-03; full dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release).

## What was just built (2026-06-03 - unattended session)
Three verified, committed deliverables:

- **Track 1 broker hardening - DONE** (`049bfcc`). Added a service-account allowlist to the code-freeze rule (`perforce/broker/p4broker.conf`): a `user = ^(buildagent|build-svc|infra-svc)$` PASS rule placed *before* the blanket reject (first-match-wins). Closes the audit-trail gap from `ci/lessons-learned.md` #3 - automation now submits *through* the broker (allowed AND logged in `broker.log`) instead of bypassing to `:1666` and vanishing from the audit log. Verified: `james`->REJECT, `buildagent`/`build-svc`->PASS->p4d, all three logged. Docs: broker/README "Service-account allowlist" section + `perforce/lessons-learned.md` #11.
- **Track 3 started - toolchain foundation** (`191bb3f`). The "C++ compiler situation" was *activation, not acquisition*: VS2019 Build Tools (cl 19.29) and VS2017 Community (cl 19.16) are both installed but gated behind vcvars. `accel/scripts/activate-msvc.ps1` (vswhere -latest -> vcvars replay into the PS session) + `smoke-build.ps1` (compile+run+assert). Verified: activates BuildTools 2019, compiles, runs, `_MSC_VER=1929`, SMOKE OK. `accel/lessons-learned.md` #1.
- **Track 3 first measured win - /MP** (`39e603b`). `accel/scripts/demo-mp.ps1` benchmarks serial vs `/MP` compilation of 16 heavy TUs: **10.02s -> 2.54s = 3.94x** on 16 logical cores, stable across reps. `accel/samples/mp-demo/` + `accel/lessons-learned.md` #2 (why ~4x not 16x).

**Infra is currently RUNNING** (I started it this session): p4d on :1666, broker on :1667. Stop with `perforce\broker\stop-broker.ps1` then `perforce\scripts\stop-p4d.ps1` if you want them down.

## Live edge
Track 1's broker is hardened (allowlist + audit gap closed). Track 3 is live with a working, activatable MSVC toolchain and one measured acceleration result. The next-step menu is wide open:
- **Track 3 next levers** (the `accel/README.md` roadmap): **unity/jumbo build** and **PCH** - both remove the redundant per-TU header parsing that `/MP` only *parallelizes* (the demo-mp harness generalizes to measure these); then **FASTBuild** as orchestrator (needs a portable binary download - ~30 min task on its own); then linker-time profiling + a one-page report.
- **Track 1 still-deferred** (broker/README "Real-world hardening"): `policies.d/` modular policy assembly; `redirection = pedantic` for replica-bound commands; filter-mode (`action = filter`) handler driving a Python policy script.
- **Track 2** (needs Docker Desktop, which was down this session): second build agent to actually parallelize the Smoke||Cook DAG fork; VCS-change trigger on Compile.

## Next
1. **If infra was stopped, restart** (order matters): `perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1` -> verify `p4 -p localhost:1667 info`. (Both were left running at session end.)
2. **Activate the compiler in any new shell:** `. .\accel\scripts\activate-msvc.ps1` (dot-source), then `pwsh -File .\accel\scripts\smoke-build.ps1` to confirm.
3. **Pick a follow-up:** unity-build vs per-TU measurement (extends demo-mp, closes the "why not 16x" loop with data) · PCH win · FASTBuild bring-up · broker `policies.d/` · or Track 2's second agent once Docker is up.
