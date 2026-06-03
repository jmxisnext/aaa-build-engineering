# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 1385873 - accel(track3): one-page capstone report (REPORT.md)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Full pre-public dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release). Vendor binaries (FBuild.exe, p4 binaries) are gitignored, never committed.

## What was just built
- `1385873` Track 3 - one-page capstone report (`accel/REPORT.md`): all four levers side by side + decision framework + the refuted-PCH-hypothesis writeup. (HTML render in `J:\projects\_html\` is a generated digest, not committed.)
- `7917f87` Track 3 - FASTBuild lever: cache miss 5.33s (≈`/MP`) · cache HIT 0.37s (14×) · no-op 0.01s. The cache makes the *second identical* build free - what `/MP`/unity/PCH can't do. lessons #5.
- `10c2bff` Track 3 - PCH lever + corrected model: PCH barely beat `/MP`; `/Bt+` showed cost is ~50% instantiation+codegen (which PCH can't cache), refuting the "PCH≈unity" guess. lessons #3-#4.
- `a5fab0a` Track 3 - consolidated `bench.ps1` + unity lever (unity 28× by compiling shared template machinery once).
- `39e603b` Track 3 - `/MP` benchmark (first measured win, ~4×).
- `191bb3f` Track 3 - MSVC toolchain made activatable (vswhere->vcvars); the "compiler situation" was activation, not acquisition. lessons #1-2.
- `049bfcc` Track 1 - broker service-account allowlist (hardening DONE); closes the audit-trail gap from `ci/lessons-learned.md` #3. perforce/lessons #11.

## Live edge
Track 1 hardened; **Track 3 is essentially complete** - toolchain + four measured levers (`/MP`, unity, PCH, FASTBuild) in one comparison, the profiling-first thesis proven by a refuted-then-corrected hypothesis, capstone in `accel/REPORT.md`. Only the optional linker-profiling roadmap item remains. **Sandbox infra is now STOPPED** (p4d + broker were shut down at closeout).

## Next
1. **Track 3 - linker-time profiling** (`/INCREMENTAL`, symbol bloat) - the one roadmap lever not yet measured; needs a link step (the bench is compile-only). Rounds out the track fully. *Or treat Track 3 as banked - it's in strong demoable shape.*
2. **Switch tracks:** Track 1 `policies.d/` modular broker policy; Track 2 second build agent / VCS-change trigger (need Docker Desktop up); Track 4 (Unreal BuildGraph/Horde) or Track 5 (data cooker + WPF tool), both greenfield.
3. **To resume Track 3 hands-on:** restart infra only if a track needs it (`perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1`); for accel work just `. .\accel\scripts\activate-msvc.ps1` then `pwsh -File .\accel\scripts\bench.ps1` / `demo-fbuild.ps1`.
