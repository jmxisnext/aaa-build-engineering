# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 5b41559 - chore: jam closeout (session since = a read-only pre-publish audit, no new repo commits)

## What was just built
- **Pre-publish security & hygiene audit** (no repo changes — the deliverable was an external
  remediation script). Results: **gitleaks clean across full history** (0 leaks, both this repo and
  `[redacted]`); `ci/.env` safe (only `TEAMCITY_VERSION`); no tracked key/token/PII files. The one
  real exposure: this repo is **ALREADY PUBLIC** (`jmxisnext/aaa-build-engineering`) and the **18
  unpushed commits would NEWLY publish [redacted] IP** — [redacted] / [redacted] / [redacted] /
  [redacted] + the [redacted] thesis + `mythogenic` — via `docs/ideation/2026-06-24-gameplay-
  systems-sad/` (first appearance in history; verified). `chronicle-kernel` by name is *already*
  public (pre-06-22).
- **Remediation decided + scripted** (delivered as `prepush-scrub.sh` in the session scratchpad —
  gated/dry-run by default): relocate `docs/ideation/` → unpublished `[redacted]`; gitignore
  `.superpowers/` + `.pytest_cache/`; trim the new anchor refs from SEEDS/HANDOFF; optionally purge
  `docs/superpowers/` from history (force-push). **Not yet run.**

## Live edge
**DO NOT push the 18 unpushed commits as-is** — `docs/ideation/` would leak the [redacted]
strategy into a public repo. The scrub is designed but not executed. Capstone (the actual portfolio
payoff) is clean and good to publish once the scrub lands. Stack is **down**.

## Next
1. **Scrub, then publish.** Minimum force-free fix for the must-not-leak anchor IP (it's only in
   unpushed commits): relocate the folder to `[redacted]`, then from this repo run
   `git filter-repo --path docs/ideation/2026-06-24-gameplay-systems-sad --invert-paths` and a
   normal `git push`. Force-push is needed ONLY if you also purge already-public `docs/superpowers/`
   in the same filter-repo pass. `pip install git-filter-repo` first (not installed). The fuller
   gated runbook is `prepush-scrub.sh` (scratchpad is ephemeral — regenerate if gone).
2. **Then** (lower priority) scope **Track 5 Step 3 cooker GUI tool** (PySide6 vs WPF) — the last
   open aaa-build thread; or switch to `[redacted]` (probe-001 code-complete, blocked on a UEFN install).

To re-demo the Capstone: start p4d + broker + `docker compose -f ci/docker-compose.yml up -d`, wait
for agents, then `pwsh -File capstone/demo-capstone.ps1`.
