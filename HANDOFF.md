# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 31f7b7e - chore: jam closeout - update handoff prompt

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets,
the real machine name (scrub to `WS01`), or job-hunt / employer specifics. **No co-author trailer.**
`git push` is permission-blocked for the agent — the human runs `! git push origin main`.
**Unpushed: still 5 commits ahead of origin/main** — push when convenient.

## What was just built (2026-06-11, session 8 - Horde Phase 2 smallest slice)
- **Horde "Compile Lyra Editor" = Completed/Success** — same unmodified `lyra-pipeline.xml` as
  TeamCity. 405 files compiled by UBT via Horde's LocalExecutor. Graph portability demonstrated.
  Job ID `6a2af032c7742580007c490b` on the local Horde server (http://localhost:13340).
- **`unreal/horde/README.md`** — reproducibility artifact: install/enroll steps, the three
  LocalExecutor-on-installed-engine workarounds with root causes, job-submit + verification
  recipes, machine-state checklist. Server/agent configs versioned in `unreal/horde/config/`.

## Live edge
Horde Phase 2 smallest slice is done. The demoable claim now stands: **the same BuildGraph XML runs
under both TeamCity and Horde on this box**. Remaining Step 2 work: full graph
(compile→cook→package) → CL-stamp parity with the TeamCity package → dashboard "Horde vs TeamCity"
row (ingest a `.metrics` from a Horde job as a second source alongside the TeamCity row).

## Next
**Continue Step 2 — grow to full `Lyra Pipeline` (compile→cook→package) under Horde.**

**Everything needed is in `unreal/horde/README.md`** — machine-state checklist (run it at session
start: junction, Horde.sln sentinel, Executor=Local, -NoP4, server+agent up), the three
LocalExecutor workarounds (do NOT re-debug them), and the job-submit recipe.

To run the full pipeline: change the template's default list item in
`C:\ProgramData\Epic\Horde\Server\game-main.stream.json` from "Compile Lyra Editor" to
"Lyra Pipeline (full compile-cook-package)" (keep the versioned copy in `unreal/horde/config/` in
sync), then submit with no `arguments`:
```powershell
$body = @{ streamId = "game-main"; templateId = "lyra-buildgraph" } | ConvertTo-Json
Invoke-WebRequest -Uri "http://localhost:13340/api/v1/jobs" -Method POST -ContentType "application/json" -Body $body -UseBasicParsing
```
Expect the cook step to dominate (~24 min cold / much less on the warm DDC from 2026-06-04 runs).

**After full pipeline green:** emit a `.metrics` file from the Horde job, then add a "Horde vs
TeamCity" row to the dashboard panel.
