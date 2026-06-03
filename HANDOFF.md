# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 10c2bff - accel(track3): add PCH lever + correct the unity model with /Bt+ evidence

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Full pre-public dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release).

## What was just built (2026-06-03)
- `10c2bff` **Track 3 - PCH lever + corrected model.** Added PCH (clean + warm) configs to `bench.ps1`. Full table (32 TUs / 16 cores): serial 20.27s · `/MP` 5.10s (3.97x) · PCH warm 4.37s (4.64x) · unity×8 1.49s (13.60x) · **unity 0.72s (28.15x)**. Finding: PCH barely beat `/MP` (refuted my "PCH ≈ unity" guess). `/Bt+` showed per-TU ≈ 50% front-end (parse+instantiation) / 50% back-end (`/O2`); PCH caches only the parsed-declaration state, so it can't share the instantiation or codegen that dominate here - unity can. Corrected lesson #3's framing; added #4.
- `a5fab0a` **Track 3 - consolidated benchmark + unity lever.** `demo-mp.ps1` -> `bench.ps1` (fixture `samples/mp-demo` -> `samples/bench`); one table across serial/`/MP`/unity/chunked-unity.
- `39e603b`/`191bb3f` **Track 3 foundation.** MSVC activatable (`activate-msvc.ps1` vswhere->vcvars; `smoke-build.ps1`). The "compiler situation" was activation, not acquisition. lessons #1-2.
- `049bfcc` **Track 1 - broker service-account allowlist (hardening DONE).** Ordered PASS rule before the freeze reject closes the audit-trail gap from `ci/lessons-learned.md` #3. perforce/lessons #11.

**Sandbox infra was left RUNNING** earlier this session: p4d :1666, broker :1667. Stop with `perforce\broker\stop-broker.ps1` then `perforce\scripts\stop-p4d.ps1`.

## Live edge
Track 1 broker hardened. Track 3 now has the toolchain + **three measured levers (`/MP`, unity, PCH)** in one reusable benchmark (`bench.ps1`), with the front/back-end split (`/Bt+`) tying the results together. The interview narrative is strong: each lever attacks a different cost, proven with data, including a refuted hypothesis corrected by measurement.

## Next
1. **Track 3 - FASTBuild** as orchestrator: the accelerator the public AAA world documents (Ubisoft et al.). Needs a portable `FBuild.exe` download (~30 min incl. a `fbuild.bff` that compiles the same `samples/bench` TUs, so it slots into the existing comparison). Then it has caching + distribution stories `/MP`/unity/PCH don't.
2. **Track 3 - one-page report** (`accel/` roadmap final item): consolidate the lever table + the "measure the front/back split, then pick the lever" thesis into a single interview-ready writeup. Cheap, high narrative value - most of the prose already exists across the lessons.
3. **Or switch tracks:** Track 1 `policies.d/` modular policy assembly; Track 2 second build agent (needs Docker Desktop, down this session); Track 2 VCS-change trigger on Compile.

First action whichever path: `. .\accel\scripts\activate-msvc.ps1` to get `cl` on PATH, then `pwsh -File .\accel\scripts\bench.ps1` to reproduce the table.
