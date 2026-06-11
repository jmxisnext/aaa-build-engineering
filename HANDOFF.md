# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 31f7b7e - chore: jam closeout - update handoff prompt

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets,
the real machine name (scrub to `WS01`), or job-hunt / employer specifics. **No co-author trailer.**
`git push` is permission-blocked for the agent — the human runs `! git push origin main`.
**Unpushed: still 5 commits ahead of origin/main** — push when convenient.

## What was just built (2026-06-11, session 8 - Horde Phase 2 smallest slice)
*(Session was pure machine-config — no repo commits. All changes live in the Horde install at
G:\HordeAgent and server config at C:\ProgramData\Epic\Horde\Server.)*

- **Horde "Compile Lyra Editor" = Completed/Success** — same unmodified `lyra-pipeline.xml` as
  TeamCity. 405 files compiled by UBT via Horde's LocalExecutor. Graph portability demonstrated.
  Job ID `6a2af032c7742580007c490b` on the local Horde server (http://localhost:13340).

## Live edge
Horde Phase 2 smallest slice is done. The demoable claim now stands: **the same BuildGraph XML runs
under both TeamCity and Horde on this box**. Remaining Step 2 work: full graph
(compile→cook→package) → CL-stamp parity with the TeamCity package → dashboard "Horde vs TeamCity"
row (ingest a `.metrics` from a Horde job as a second source alongside the TeamCity row).

## Next
**Continue Step 2 — grow to full `Lyra Pipeline` (compile→cook→package) under Horde.**

**First, verify machine state (all non-repo config, must be intact):**
- `Test-Path G:\HordeAgent\Engine` → True (junction → G:\UnrealEngine\UE_5.6\Engine)
- `Test-Path G:\HordeAgent\Engine\Source\Programs\Horde\Horde.sln` → True (stub sentinel for FindWorkspaceRoot)
- `G:\HordeAgent\JobDriver\appsettings.json` → contains `"Driver": { "Executor": "Local" }`
- `game-main.stream.json` template arguments include `-NoP4`
- Horde server on port 13340 running; agent process running

**Submit full-pipeline job (after verifying stream template default item is "Lyra Pipeline"):**
```powershell
$body = @{ streamId = "game-main"; templateId = "lyra-buildgraph" } | ConvertTo-Json
Invoke-WebRequest -Uri "http://localhost:13340/api/v1/jobs" -Method POST -ContentType "application/json" -Body $body -UseBasicParsing
```
Or change the template's default list item in `game-main.stream.json` from "Compile Lyra Editor"
to "Lyra Pipeline (full compile-cook-package)" and re-submit with no arguments.

**Why the three workarounds (do NOT re-debug):**
1. `IOptions<LocalExecutorSettings>.WorkspaceDir` is never bound by DriverApp — config file has no
   effect. Fix: `G:\HordeAgent\Engine` junction + stub `Horde.sln` → `FindWorkspaceRoot()` returns
   `G:\HordeAgent\` as workspace root; RunUAT resolves through the junction.
2. LocalExecutor always passes `useP4=null`; `-NoP4` only auto-injected when `useP4=false`. Fix:
   `-NoP4` in template `arguments` → lands in `_additionalArguments` → SetupAsync appends it
   (JobExecutor.cs:793-796).
3. POSTing `{ arguments: [...] }` replaces the template's fixed `arguments` (drops `-Script=`). Fix:
   omit `arguments` from the API call to use template + parameter defaults.

**After full pipeline green:** emit a `.metrics` file from the Horde job, then add a "Horde vs
TeamCity" row to the dashboard panel.
