# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 39e603b - accel(track3): /MP parallel-compilation benchmark -- first measured win (3.94x)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Full pre-public dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release).

## What was just built
- `39e603b` **Track 3 - /MP benchmark (first measured acceleration win).** `accel/scripts/demo-mp.ps1` compiles 16 heavy TUs serial vs `/MP`: **10.02s -> 2.54s = 3.94x** on 16 logical cores, stable across reps. `accel/samples/mp-demo/` + lessons-learned #2 (why ~4x not 16x: HT, non-parallel front-end, redundant header parsing -> points at PCH/unity next).
- `191bb3f` **Track 3 started - MSVC toolchain made activatable.** The "compiler situation" was activation, not acquisition (VS2019 BuildTools cl 19.29 + VS2017 Community cl 19.16 both installed, gated behind vcvars). `accel/scripts/activate-msvc.ps1` (vswhere -latest -> vcvars replay into the PS session) + `smoke-build.ps1` (compile+run+assert, CI-gateable). lessons-learned #1.
- `049bfcc` **Track 1 - broker service-account allowlist (hardening DONE).** Ordered `user = ^(buildagent|build-svc|infra-svc)$` PASS rule before the blanket freeze reject. Closes the audit-trail gap from `ci/lessons-learned.md` #3: automation now submits *through* the broker (logged) instead of bypassing to `:1666` (invisible). Verified james->REJECT, buildagent/build-svc->PASS->p4d, all logged. broker/README + perforce/lessons-learned #11.

## Live edge
Track 1 broker is hardened (allowlist + audit gap closed). Track 3 is live: activatable MSVC toolchain + one measured acceleration result, with the next levers teed up by the `/MP` "why not 16x" analysis. The `accel/scripts/demo-mp.ps1` timing/reporting pattern generalizes into a reusable acceleration measurement harness (see SEEDS.md 2026-06-03) - each remaining lever is the same harness with one variable changed.

**Sandbox infra was left RUNNING** this session: p4d on :1666, broker on :1667. Stop with `perforce\broker\stop-broker.ps1` then `perforce\scripts\stop-p4d.ps1` if you want them down.

## Next
Pick one (all are next-step menu items, not a forced path):
1. **Track 3 - unity/jumbo build measurement** (extends `demo-mp.ps1`): concatenate the N TUs into one and re-time vs per-TU + `/MP`. Closes the "why not 16x" loop with data by removing the redundant header parsing. Then PCH (`/Yc` once + `/Yu`), then FASTBuild (needs a portable binary download, ~30 min).
2. **Track 1 - `policies.d/` modular policy assembly** (broker/README "Real-world hardening" still-deferred list).
3. **Track 2 - second build agent** to actually parallelize the Smoke||Cook DAG fork (needs Docker Desktop, which was down this session).

First action whichever path: `. .\accel\scripts\activate-msvc.ps1` to get `cl` on PATH, and if infra was stopped, `perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1` -> verify `p4 -p localhost:1667 info`.
