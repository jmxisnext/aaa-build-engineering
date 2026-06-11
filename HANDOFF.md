# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: d105e0f - chore: amend chronicle seed - final home shape (private repo consuming this infra)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. **No co-author trailer.** `git push` is permission-blocked for the agent — the human runs `! git push origin main`. **Unpushed: now 5 commits ahead of origin/main** (`bc32e03` sanity-check, `5aa7c52` closeout, `bfb04a2` seeds, `d105e0f` seed amendment, + this closeout) — push when convenient. Also still possibly unpushed: the `jam` plugin at `J:\jammers-lab\.jam` (`131b17d`). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, `unreal/.metrics/`, `dashboard/_preview.html`, `**/.env` (except `ci/.env`) are gitignored.

## What was just built (2026-06-11, session 7 - seeds only; no track work)
- `d105e0f` + `bfb04a2` - **chronicle/gameplay seeds parked** from the 2026-06-11 chronicle-engine
  ideation (record lives privately in `J:\jammers-lab\noosphere\docs\ideation\2026-06-11-chronicle-engine\`).
  Final shape: the **Chronicle G0 kernel lives in its own PRIVATE repo**
  (`J:\jammers-lab\chronicle-kernel`, scaffolded same day) and **consumes this repo's
  infrastructure** - TeamCity tests-on-commit + SHA version-stamp + failure notifier, the
  determinism gate as a byte-diff CI job, optional dashboard feed (generic job names -
  `snapshot.json` is public), post-gate the UE/Lyra/BuildGraph pipeline for a correction-quest
  demo. This repo publicly carries only the pipeline-integration story; kernel code goes public
  only on a passed gate. Two-speed rule in SEEDS: gameplay SKILL tracks any time; demoing the
  game itself gated behind the kernel gate.
- No commits to tracks 1-5 / dashboard this session; ROADMAP state unchanged.

## Live edge
Unchanged: **Horde (Phase 2 Step 2) is NEXT** with its defined demoable artifact (portability
proof: same BuildGraph under Horde *and* TeamCity). New standing decision queued for the next
in-session sequencing call: Horde step 2 vs wiring the chronicle-kernel CI config — do not let the
kernel work displace Horde silently; pick one explicitly at session start.

## Next
1. **Push:** `! git push origin main` (5 commits ahead), and check/push the `jam` plugin repo.
2. **Sequencing call, then execute:** either (a) **Horde Phase 2 Step 2** — smallest slice: Horde
   Server up + one agent authorized + agent runs a single Compile node of
   `unreal/buildgraph/lyra-pipeline.xml` end-to-end; then full graph → CL-stamp parity →
   dashboard Horde-vs-TeamCity row; frame as portability + job mechanics, NOT speed (UBA ~29%
   slower single-box; 64 GB pagefile prevents OOM but isn't real RAM — serialize UE + Horde +
   agent, never concurrent with the TeamCity/Docker stack); or (b) a TeamCity build config for
   `chronicle-kernel` once that repo has a test suite (it currently has none — scaffold only, so
   (a) is the natural pick unless the kernel's protocol+fixture land first).
