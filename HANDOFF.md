# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: a5fab0a - accel(track3): consolidate into one acceleration benchmark; add unity/jumbo lever

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Full pre-public dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release).

## What was just built (2026-06-03)
- `a5fab0a` **Track 3 - unity/jumbo lever + consolidated benchmark.** Superseded `demo-mp.ps1` with `accel/scripts/bench.ps1` (renamed fixture `samples/mp-demo` -> `samples/bench`). One table, four configs, 32 TUs / 16 cores: serial 20.22s · `/MP` 4.98s (4.06x) · **unity 0.73s (27.7x)** · unity×8+`/MP` 1.49s (13.57x). Finding: unity *single-core* beats chunked-unity-across-16-cores because this fixture is header-parse-dominated (eliminating redundant work > parallelizing it). Docs are explicit about that fixture bias + unity's real costs (incremental granularity, ODR). lessons-learned #3.
- `39e603b`/`191bb3f` **Track 3 foundation.** MSVC made activatable (`activate-msvc.ps1` vswhere->vcvars replay; `smoke-build.ps1`); the "compiler situation" was activation not acquisition (VS2019 BuildTools cl 19.29 selected). lessons-learned #1-2.
- `049bfcc` **Track 1 - broker service-account allowlist (hardening DONE).** Ordered PASS rule before the freeze reject closes the audit-trail gap from `ci/lessons-learned.md` #3; automation submits *through* the broker (logged). perforce/lessons-learned #11.

**Sandbox infra was left RUNNING** earlier this session: p4d on :1666, broker on :1667. Stop with `perforce\broker\stop-broker.ps1` then `perforce\scripts\stop-p4d.ps1`.

## Live edge
Track 1 broker hardened. Track 3 has the toolchain + two measured levers (`/MP`, unity) in one reusable benchmark harness (`bench.ps1`). The harness is built to plug in the remaining levers with ~one new config block each.

## Next
1. **Track 3 - PCH lever** (extends `bench.ps1`): add a `PCH` config - `/Yc` to build `heavy.h` into a .pch once, `/Yu` per TU to consume it. The interesting comparison is PCH-per-TU+`/MP` vs unity: PCH should let `/MP` approach unity's speed *without* unity's incremental-granularity / ODR costs. That contrast is the strongest interview point in the track.
2. Then **FASTBuild** as orchestrator (needs a portable binary download, ~30 min), then linker-time profiling, then the one-page report.
3. **Or switch tracks:** Track 1 `policies.d/` modular policy assembly; Track 2 second build agent (needs Docker Desktop, down this session).

First action whichever path: `. .\accel\scripts\activate-msvc.ps1` to get `cl` on PATH, then `pwsh -File .\accel\scripts\bench.ps1` to reproduce the table.
