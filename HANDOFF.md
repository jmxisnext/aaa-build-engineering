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
**Sequencing locked (planning turn after closeout): Capstone FIRST.** The remaining Track-5 GUI tool
AND the UE6/Verse pivot are both deferred to a single **post-Capstone fork** — once the Capstone caps
the spine, decide: go in the **Verse/UE6 direction** (its own experiment) or build the **cooker GUI
tool** (and if the tool, **PySide6/Qt over WPF** — repo-native Python, `import cooker` directly,
~1–1.5 days, no .NET toolchain). CI-cook validation is closed (this session) and de-risked the
Capstone's cook stage.

## Next
**Capstone — Phase 2 Step 4 (the cap).** Stitch the proven pieces into one end-to-end demo:
P4 submit → policy-gated CI → cook → package → CL-version-stamped artifact, run on a
**containerized / ephemeral agent** (opp #4; Rockstar explicitly requires Docker), plus a
**Zen/DDC writeup** framing the cooker as a mini-DDC/CAS. The pieces all exist — P4 submit-trigger,
CI chain, cook-in-CI (live-verified this session), version-stamp, Horde — so the work is
integration + ephemeral-agent + writeup (~2–3 sessions). **First slice:** a clean end-to-end run
from one P4 submit through to the stamped package, then layer in the ephemeral agent.

**Post-Capstone fork:** Verse/UE6 experiment (`/jam:new`, see `SEEDS.md` 2026-06-24) **vs** the
PySide6 cooker GUI tool.

Side items (not blocking, do if convenient): harden the first-build seed in `bootstrap-builds.ps1`
(lessons #15, fresh-server `down -v` 404); the README `.toc` shape (line 51) omits the `deps`
field that's actually emitted — trivial doc nit.
