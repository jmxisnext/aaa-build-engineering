# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 7917f87 - accel(track3): FASTBuild lever -- caching makes the second identical build free

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Full pre-public dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release). Vendor binaries (FBuild.exe, p4 binaries) are gitignored, never committed.

## What was just built (2026-06-03)
- `7917f87` **Track 3 - FASTBuild lever.** `demo-fbuild.ps1` + `samples/fbuild/fbuild.bff` compile the same `samples/bench` TUs through FASTBuild v1.20 (binary gitignored; `tools/fastbuild/README` has the download). Cache results: clean cache-miss **5.33s** (≈ `/MP`) · clean cache-**HIT** **0.37s (14.4×)** · no-op **0.01s**. The differentiator: a content-addressable cache makes the *second identical* build free (CI re-runs, branch switches, shared cross-machine cache) - what `/MP`/unity/PCH can't do. lessons #5 (incl. FASTBuild's hermetic-env gotcha).
- `10c2bff` **Track 3 - PCH lever + corrected model.** PCH barely beat `/MP`; `/Bt+` showed per-TU ≈ 50% parse+instantiation / 50% codegen, and PCH caches only the parse. Corrected the unity finding (instantiation+codegen dominate, not parse). lessons #3-#4.
- `a5fab0a` **Track 3 - consolidated `bench.ps1` + unity lever** (unity 28× by compiling shared template machinery once).
- `39e603b`/`191bb3f` **Track 3 foundation** - MSVC activatable (vswhere->vcvars); the "compiler situation" was activation, not acquisition. lessons #1-2.
- `049bfcc` **Track 1 - broker service-account allowlist (hardening DONE).** Closes the audit-trail gap from `ci/lessons-learned.md` #3. perforce/lessons #11.

**Sandbox infra was left RUNNING** earlier this session: p4d :1666, broker :1667. Stop with `perforce\broker\stop-broker.ps1` then `perforce\scripts\stop-p4d.ps1`.

## Live edge
Track 1 hardened. **Track 3 now has the toolchain + four measured levers (`/MP`, unity, PCH, FASTBuild) in one comparison**, each attacking a different cost (parallelize / eliminate redundant instantiation / cache the parse / cache the whole obj), with a refuted-then-corrected hypothesis (PCH) proving the profiling-first thesis. The full numbers live across `accel/samples/{bench,fbuild}/README.md` + `accel/lessons-learned.md` #1-#5.

## Next
1. **Track 3 - the one-page report** (`accel/` roadmap's final artifact, the capstone): consolidate the lever table + the "profile the front/back split, then pick the lever; they compose, they don't compete" thesis into a single interview-ready page. Cheap, high narrative value - the prose already exists across the five lessons; this is assembly + a decision-tree framing. **Recommended next.**
2. **Track 3 - linker-time profiling** (`/INCREMENTAL`, symbol bloat) - the one roadmap lever not yet measured; needs a link step (current bench is compile-only).
3. **Or switch tracks:** Track 1 `policies.d/` modular broker policy; Track 2 second build agent / VCS-change trigger (both need Docker Desktop, down this session); or start Track 4 (Unreal BuildGraph/Horde) / Track 5 (data cooker + WPF tool), both greenfield.

First action whichever path: `. .\accel\scripts\activate-msvc.ps1` for `cl`, then `pwsh -File .\accel\scripts\bench.ps1` and `pwsh -File .\accel\scripts\demo-fbuild.ps1` to reproduce the tables.
