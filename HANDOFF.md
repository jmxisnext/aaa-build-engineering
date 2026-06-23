# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 7664313 - docs: live-verify Horde in-graph CL stamp (item 4); capture DDC + config-drift lessons

## What was just built
**Heavy-lift session: "prep for the heavy lift" → the offline prep campaign (batches 1-3) was already
100% committed, so this session ran the live Horde cook and validated the gated items.**

- `docs:` (7664313, this session) — **live-verified the Horde in-graph CL stamp (item 4).** First live
  Horde run stamped `source=teamcity` under Horde; root-caused to **deployed-config drift** — the live
  server (`C:\ProgramData\Epic\Horde\Server\game-main.stream.json`) ran a stale stream template missing
  `-set:Source=horde`, even though the repo had it. Redeployed → ~3-min warm re-run → `build-info.json`
  + `.metrics` now read `source: horde` / `orchestrator: Horde`. Added lessons #5 (shared DDC stays
  sparse when local DDC is warm) + #6 (running Horde config ≠ repo config; verify on a live run).
- `docs:` (712aac5, prior-session tail) — reconciled durable docs after CI cook-wiring shipped.

## Live edge
Phase 2 **Step 2 (Horde) is now fully live-verified** — item 4 closed; `source: horde` in the package
+ dashboard metric. The cold→warm shared-DDC demo was found **not demonstrable on this single box**
(warm local DDC → empty shared node stays sparse; local hits don't back-propagate — lesson #5); its
real payoff is **cross-machine**. The documented cold cook number stays **24.6 min** (2026-06-13).
Live services (p4d + Horde agent) were **shut down** at end of session — box is clear for Docker work.

## Next
Pick one:
1. **CI-cook live validation** (the long-standing gated item, HANDOFF carry-over): bring up the
   TeamCity/Docker stack, trigger `AAASandbox_CookAssets` twice, confirm build #1 cold (`cached 0`)
   → build #2 warm (`cached>0`). Services are DOWN now, so it's clear to start Docker (31 GB ceiling —
   Horde must stay down). The one Track-5 thing offline couldn't prove.
2. **Track 5 step 3 — C# WPF artist tool** over the cooker (cooker side ready: dep-edges in `.toc`,
   `--dry-run`, `--pack`). The remaining "to come" Track-5 item.
3. **Quick win from this session's seeds:** add a repo↔deployed config-drift check to
   `horde-preflight.ps1` — would have caught the `-set:Source=horde` drift offline (lesson #6).
