# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 2518262 - AAA build/databuild engineering skill ladder

**This repo is now PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . On 2026-06-03 history was flattened to a single clean commit for public release (scrubbed the real machine name -> `WS01`, genericized job-target/employer references). The full 13-commit dev history is preserved in the local `localbak` backup mirror. **Because it's public now: never commit secrets, the real machine name, or job-hunt / employer specifics.**

## What was just built
- **2026-06-03 - went public.** Security pass (gitleaks clean across history), scrubbed the `DESKTOP-...` machine name, genericized target-employer references in README / ROLE_NOTES / SEEDS / SKILLS_ROADMAP, flattened history, pushed to public GitHub, no co-author trailer. Tracks 1-2 ship as the portfolio.
- **Track 2 complete** (pre-flatten; per-commit detail lives in the localbak mirror) - TeamCity four-stage DAG **Compile -> (Smoke || Cook) -> Package** via an idempotent REST bootstrap (`ci/scripts/bootstrap-builds.ps1`), a custom p4-baked agent image, and a seeded Hoops Brawl CMake project in `//game/main`. Verified end-to-end (all four SUCCESS in ~35s -> `hoops-brawl.tar.gz`). Lessons in `ci/lessons-learned.md` + `perforce/lessons-learned.md` (#3 broker-is-a-router-not-a-journal; #4 TeamCity REST per-endpoint content negotiation).
- **Track 1 complete** - Perforce sandbox: stream depot, broker, submit triggers, P4Python janitor tooling.

## Live edge
Tracks 1-2 are done and now public. Next-step work is a menu, not a forced path. Top candidates: (a) add a second build agent so the DAG's Smoke || Cook fork actually parallelizes (it serialized in the verify run - only one agent); (b) Track 1 broker hardening (service-account allowlist) to close the lesson-#3 audit-trail gap; (c) kick off Track 3 (build acceleration / FASTBuild). Mind what you commit - the repo is public.

## Next
1. **Restart infra** (order matters): `perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1` -> verify `p4 -p localhost:1667 info`. Then Docker Desktop + `docker compose up -d` from `ci/`. Re-run `ci\scripts\bootstrap-builds.ps1` if the four build configs didn't survive a restart (idempotent, auto-grabs the superuser token; `-Recreate` to wipe + redo).
2. **Pick a follow-up:** second agent (~30 min; confirms DAG parallelism - strong interview demo) · broker service-account allowlist (Track 1 hardening, closes lesson #3) · VCS-change trigger on Compile (`POST /buildTypes/{id}/triggers`) · or start Track 3.
3. **(Optional)** Kotlin DSL versioned settings (`.teamcity/settings.kts`) - higher interview-narrative value, higher complexity; defer until you want the polish.
