# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: fb1cff5 - docs: live-verify CI cook round-trip; capture first-build + cooker-source findings

## What was just built
- **CI-cook live validation DONE** (`fb1cff5` + live infra work). Brought up the TeamCity/Docker
  stack + p4d/broker, provisioned `AAASandbox_CookAssets`, and proved the warm-cache round-trip
  live: cold `cooked 8 / cached 0` → warm `cooked 0 / cached 8` (guard `cached=8`), 144 428 B both
  runs. Closes the long-standing gated spec §8 item.
- **Two findings captured** (`ci/lessons-learned.md` #15): the self artifact-dep **can't bootstrap
  the first build** (404 on `lastSuccessful`; TeamCity has no optional-dep flag → **seed-first**:
  detach dep → cold build → re-attach); and the cooker source had to be **imported into `//tools/`**
  (P4 Change 52, `import pipeline/... //tools/pipeline/...`) because `pipeline/` isn't in the
  `//game/main` stream the agent checks out.
- Fixed `depot-layout.md` import syntax (view-first); marked spec §8 + `ROADMAP_NEXT.md` step 3
  live-verified; fed the dashboard **"Cook (Track 5)"** panel with the real warm-cache numbers.
- Parked **UE6/Verse → its own experiment** (`SEEDS.md` 2026-06-24): Verse is a gameplay language,
  not a build tool; Track-5 step-3 tool stays **C# WPF / PySide6**.

## Live edge
CI-cook validation is closed. Phase 2's remaining Track-5 piece is the **C# WPF (or PySide6) artist
tool** over `pipeline/cook.py` (the last "to come" item); after that, **Step 4 Capstone stitch**
(submit→CI→cook→package, repo-as-demo). UE6/Verse is deliberately parked to a separate experiment to
keep aaa-build's build-engineering identity pure.

## Next
Pick one:
1. **Track 5 step 3 — C# WPF / PySide6 artist tool** over `pipeline/cook.py` (the remaining Track-5
   artifact; cooker side ready — dep-edges in `.toc`, `--dry-run`, `--pack`). Verse was considered
   and rejected (gameplay language, not a build tool — see `SEEDS.md` 2026-06-24).
2. **Quick doc fix (drift from this session):** `README.md:13` + `CLAUDE.md:11` still say "live
   TeamCity validation gated" though it's now validated (`fb1cff5`). Clear both.
3. **Harden the first-build seed** (lessons #15): automate the seed-first step in
   `bootstrap-builds.ps1` (or document it in the runbook) so a fresh-server (`down -v`)
   `Cook Assets` doesn't 404 on the self artifact-dep.
4. **Stand up the UE6/Verse experiment** (`/jam:new`) per the `SEEDS.md` 2026-06-24 handoff prompt.
