# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 4c388d4 - accel(track3): linker-time profiling lever -- the last roadmap lever

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Full pre-public dev history is in the local `localbak` mirror. Commits here carry **no co-author trailer** (matches the public release). Vendor binaries (FBuild.exe, p4 binaries) are gitignored, never committed.

## What was just built
- `4c388d4` Track 3 - **linker-time profiling lever** (the last roadmap lever). New `accel/scripts/bench-link.ps1` + generated 16k-symbol fixture (`samples/link/`), compiled once, link varied: incremental relink `0.033s` vs full `0.081s` (**2.45x**); `/OPT:REF,ICF` 777->247 KB; `/LTCG` (`/GL` objs) **21.79s = 269x slower** (codegen moves to link). Link is a separate phase no compile lever touches. Track 3 roadmap now **COMPLETE**. lessons #6, REPORT.md section C + H5 + framework step 5, `samples/link/README.md`.

## Live edge
Track 3 is **fully complete** - all five levers measured (`/MP`, unity, PCH, FASTBuild, **link**), capstone in `accel/REPORT.md`, roadmap fully ticked. **PUSH PENDING:** commits `4c388d4` (+ this closeout commit) are local only - the push to origin was permission-blocked this session. Sandbox infra remains STOPPED.

## Next
1. **Push to origin** - run `! git push origin main` to publish `4c388d4` + the closeout commit. The only loose end from this session.
2. **Track 3 is banked.** Switch tracks: Track 1 `policies.d/` modular broker policy; Track 2 second build agent / VCS-change trigger (needs Docker Desktop up); Track 4 (Unreal BuildGraph/Horde) or Track 5 (data cooker + WPF tool), both greenfield.
3. **To re-run accel hands-on:** `. .\accel\scripts\activate-msvc.ps1`, then `pwsh -File .\accel\scripts\bench.ps1` / `demo-fbuild.ps1` / `bench-link.ps1`. Restart p4d/broker only if a track needs it (`perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1`).
