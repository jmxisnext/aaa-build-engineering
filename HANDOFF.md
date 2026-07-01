# Handoff - aaa-build-engineering

## Resume from
Branch: main | after the 2026-07-01 pre-publish hygiene pass

## What was just built
- **Pre-publish hygiene pass (2026-07-01):** private ideation provenance relocated out of the
  repo, internal planning refs trimmed from SEEDS/ROADMAP/HANDOFF, cache dirs gitignored, and
  the unpushed history cleaned before publishing. No functional changes; Capstone untouched.

## Live edge
Repo is publish-clean. **Capstone (Phase 2 Step 4) is DONE** — submit → CI → cook → package →
CL-stamped artifact + provenance + dashboard, all verified. See `capstone/README.md`.

## Next
1. **Track 5 Step 3 — cooker GUI tool** (PySide6 vs WPF decision, then build). The last open
   aaa-build thread; see ROADMAP_NEXT.md Step 3 and the 2026-06-20 seeds.
2. **LICENSE decision** (see SEEDS 2026-06-25) before treating the repo as interview-ready.

To re-demo the Capstone: start p4d + broker + `docker compose -f ci/docker-compose.yml up -d`,
wait for agents, then `pwsh -File capstone/demo-capstone.ps1`.
