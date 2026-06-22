# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: e4c129a - docs: reconcile ROADMAP_NEXT CL-stamp parity status (authored in-graph)

## What was just built
**A "heavy-run prep campaign": front-load every offline-authorable item so each Phase-2
resource-heavy run reduces to "just the run".** Spec + 2 implementation plans, then Batches 1-2
executed TDD + a Batch-3 starter. 13 commits this session; **all offline, no heavy services touched.**

- **Campaign docs** - `docs/superpowers/specs/2026-06-21-heavy-run-prep-design.md` (+ batch1/batch2
  plans). Full Phase-2 ledger; Approach A (cross-cutting first). (02a56a8, e3dd630, 2d765c6, 38c2610)
- **Batch 1 (turnkey + warm Horde):** `set-shared-ddc.ps1` **applied** (UE-SharedDataCachePath =
  `D:\DDC-Shared`) (2a9ecba); `horde-preflight.ps1` + pure `Get-PreflightVerdict` + serialization
  guardrails (33d01b4) + env-scope fix (6805f82); `ci/.env` pins TEAMCITY_VERSION=2026.1 (047238c).
  Corrected the stale Horde README item-4 (CL-stamp parity is in-graph).
- **Batch 2 (cooker):** `.toc` character->asset dep-edges (b6cb263); `--dry-run` what-would-recook,
  writes nothing (129e809); pack-to-`.pak` deterministic ZIP (ec3a80f). **42/42 cooker tests GREEN.**
- **Batch 3 (started):** Python 3 + Pillow added to `ci/agent/Dockerfile` (777a5e8) - build-verify
  deferred to next `docker compose up`.
- **Drift fix:** ROADMAP_NEXT CL-stamp parity -> authored-in-graph/verify-only (e4c129a).

## Live edge
The whole **offline** prep surface for Phase 2's heavy runs is committed + GREEN, so the heavy runs
are now gated behind one command (`horde-preflight.ps1`). Run it read-only and it correctly reports
the box state + the exact pre-run actions. **15 commits unpushed** (human runs `git push origin main`).
The CI cook-wiring, pre-flight/gated builds, and the Capstone are deliberately deferred to their own
brainstorm->spec->plan cycles (spec §3.3) - they are features, not prep.

## Next
Pick one:
1. **Heavy session (now turnkey):** `pwsh -File unreal/scripts/horde-preflight.ps1 -Start` -> green ->
   one live Horde run (now stamps the CL **in-graph**, no manual step) + `emit-run-metric.ps1` with
   the real job facts; warm the shared DDC (`D:\DDC-Shared`) via a TeamCity cook so the next Horde
   cook drops ~24.6 min -> ~1 min.
2. **Next deferred feature (light):** brainstorm the **CI "Cook Data" wiring** - wire
   `pipeline/cook.py --pack` into the TeamCity Cook Data stage replacing the toy `hoops_cooker`. The
   agent image is now pillow-ready (777a5e8) and the cooker emits a single `.pak`; persistence of
   `cooked/`+index across CI runs is the open design question (spec §3.2).
