# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: b7d3d92 - feat(track2): version-stamp Package with P4 changelist + build-failure notifier

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/` + `localbak/` and vendor binaries are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **3 commits (`cdf1370..b7d3d92`) are local and UNPUSHED.**

## What was just built
Phase 1 **steps 1 & 2 both finished and verified end-to-end** on live infra:
- `b7d3d92` **Track 2 step 2** - version-stamp Package (`dist/build-info.json` from `%build.vcs.number%` + the `hoops-brawl-cl<N>.tar.gz` filename; verified at CL 29/46) and `notify-build-failure.ps1` (file-write notifier; proven by a CL-45 `[DEMO-BREAK]` test -> Smoke Test FAILED -> caught -> fix-forward CL 46 -> green). Bonus hardening from the live run: **CSRF** fix on `bootstrap-builds.ps1` + `setup-vcs-trigger.ps1` (TeamCity 2026.x blocks session-authed writes), `%%` date-escaping, tarball-staleness `rm`, instant-CI restored. Lessons #10-12.
- `05cd8e0` **Track 1 proxy LIVE** - downloaded `p4p.exe` (P4P/2025.2), proxy `:1668`->`:1666`; `demo-proxy.ps1 -SeedMB 50` proved cache-fill -> cache-hit (50 MB cached, client B = 0 upstream fetches).
- `cdf1370` **Track 1** - p4p proxy harness + `validate-submit.py` (`change-content` depot-hygiene trigger, 5/5 demo cases) + live `p4 streams` snapshot in `depot-layout.md`. Lessons #12-13 (perforce).

## Live edge
Phase 1 is half done: **steps 1 (Track 1) + 2 (Track 2) complete + locked**; nothing mid-implementation. All sandbox infra (p4d :1666, broker :1667, p4p :1668, TeamCity server+2 agents) is **STOPPED, data preserved** - bring up only what the next step needs. The 3 commits await the human's `git push`.

## Next
Start **`ROADMAP_NEXT.md` Phase 1 step 3 - finalize Track 3 (accel)**: adopt **bgfx `examples/common`** (the workload-tier injection #1) so the accel before/after numbers are real instead of the synthetic 32-TU fixture - `/MP`, unity, FASTBuild cache against a recognizable C++ codebase; add a `/d2cgsummary` snippet + single-file-edit compile timing. Track 3 work lives in `accel/`; no TeamCity/p4 infra needed for it. Then Phase 1 step 4 (the dashboard aggregating tracks 1-3).
