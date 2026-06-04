# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 9039469 - docs: correct drive-placement guidance (F: is slow external HDD; UE/DDC -> NVMe D:/G:)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/` + `localbak/` and vendor binaries are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **2 commits (`c32bac1..9039469`) are local and UNPUSHED.**

## What was just built
A **strategy / re-planning** session on top of the (now public) VCS-root-creation increment - two doc commits:
- `9039469` Corrected drive-placement guidance after verifying real hardware: **F: is a slow external USB HDD, NOT a build target.** UE5/Lyra -> G: (NVME_DURABLE), DDC + build/cook scratch -> D: (NVME_SCRATCH), source -> J: (Dev Drive).
- `7191475` **`ROADMAP_NEXT.md`** - the session's main artifact: a completeness audit of tracks 1-3 (all demoable; only polish/gap-closing left), a 2026 landscape update for tracks 4-5 (Horde + UBA GA in UE 5.5; BuildGraph still the standard; Zen DDC; WPF still valid), the **workload tier** principle (adopt bgfx + Lyra, do NOT build a game), hardware reality, and a **locked consolidate-first Phase 1**. `SKILLS_ROADMAP.md` now points to it.
- Saved auto-memories this session: `dev-machine-specs` (CPU/RAM/GPU + drive map) and `verify-over-assume-on-portfolio` (working-style feedback).

## Live edge
Planning is captured and locked through Phase 1; nothing is mid-implementation. Decision: **consolidate-first** - finish tracks 1-3 + build the dashboard before touching tracks 4-5 (whose order is deliberately deferred to a re-sanity *after* the dashboard ships). This **supersedes** the prior handoff's "pre-flight / gated builds" Next - that's now a later Track 2 lever, not the immediate move. Sandbox infra (TeamCity x3 + p4d + broker) is **STOPPED**, data preserved.

## Next
Start **`ROADMAP_NEXT.md` Phase 1, step 1 - finalize Track 1**: stand up a `p4p` proxy (`:1668`->`:1666`) + cache-hit demo, embed a live `p4 streams` snapshot in `perforce/depot-layout.md`, and add a P4 change-submit validation trigger. Bring the Perforce side up first (`perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1`); TeamCity is not needed for the Track 1 bits. Then continue Phase 1: Track 2 version-stamp + failure-notification -> Track 3 bgfx real numbers -> the dashboard. (Full sequence + rationale in `ROADMAP_NEXT.md`.)
