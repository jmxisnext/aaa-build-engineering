# Track 4 — Horde on one box (Phase 2, Step 2)

**Goal (win condition):** a local **Horde Server + one agent** runs the **unmodified**
`unreal/buildgraph/lyra-pipeline.xml` and produces the same CL-version-stamped package +
`.metrics` the TeamCity path already produces — proving the *same graph runs under two
orchestrators*. Value = **graph portability + Horde job mechanics**, not speed (one box has no
remote agents for UBA to win on — see `../lessons-learned.md` #3).

## Status

1. Horde Server up + one agent enrolled/authorized. ✅ **DONE 2026-06-11.**
2. Agent runs the single **Compile Lyra Editor** node end-to-end via LocalExecutor. ✅ **DONE
   2026-06-11** — 405 UBT actions, `Completed/Success`, same XML TeamCity runs.
3. Full graph (compile → cook → package) under Horde. ⬜ NEXT
4. CL-stamp parity with the TeamCity package. ⬜
5. Dashboard "Horde vs TeamCity" row (Horde job emits `.metrics` as a second source). ⬜

## Topology

One Windows box (`WS01`) runs everything, serialized (31 GB RAM ceiling — never concurrently with
the TeamCity/Docker stack):

| Piece | Where | Notes |
|---|---|---|
| Horde Server | `C:\Program Files\Epic Games\Horde` (MSI) | Bundles MongoDB + Redis; dashboard + API on **:13340** |
| Server config | `C:\ProgramData\Epic\Horde\Server\` | `globals.json`, `aaa.project.json`, `game-main.stream.json` — versioned copies in [`config/`](config/) |
| Agent | `G:\HordeAgent\` | Run via `dotnet HordeAgent.dll`; sandbox at `D:\HordeAgentData\Sandbox` |
| Engine + Lyra | `G:\UnrealEngine\UE_5.6`, `G:\UnrealProjects\LyraStarterGame` | Installed (Launcher) engine — *not* a source build; that fact drives workaround #1 |
| p4d (Track 1 sandbox) | `localhost:1666` | Supplies CL provenance only — LocalExecutor never syncs |

## Install

1. **Server:** `UnrealHordeServer.msi` from the [`EpicGames/UnrealEngine` GitHub release](https://github.com/EpicGames/UnrealEngine/releases)
   matching the engine version (5.6.1). Requires an Epic-linked GitHub account **with the org
   invite accepted** — a pending invite still 404s (accept programmatically:
   `gh api -X PATCH user/memberships/orgs/EpicGames -f state=active`).
2. **Agent:** download zip from the server dashboard (Tools → Agent) or
   `GET /api/v1/tools/horde-agent?action=zip`; unzip to `G:\HordeAgent`.
3. **Server config:** copy the three files in [`config/`](config/) to
   `C:\ProgramData\Epic\Horde\Server\`. The server hot-reloads on change; check
   `/api/v1/server/info` and the dashboard's Server Status for "Configuration updated (success)".
4. **Agent config:** copy [`config/agent-appsettings.User.json`](config/agent-appsettings.User.json)
   to `G:\HordeAgent\appsettings.User.json`. Set `"Executor": "Local"` in the `"Driver"` section of
   `G:\HordeAgent\JobDriver\appsettings.json` (see workaround #2 — `-NoP4` rides in the template
   instead, because driver-side `LocalExecutor` settings don't bind).
5. **Enroll the agent:** start it (`dotnet G:\HordeAgent\HordeAgent.dll`), then approve it.
   Pending agents appear at `GET /api/v1/enrollment` — **not** `/api/v1/agents`:
   ```powershell
   $pending = (Invoke-WebRequest http://localhost:13340/api/v1/enrollment -UseBasicParsing).Content | ConvertFrom-Json
   $body = @{ agents = @(@{ key = $pending.agents[0].key }) } | ConvertTo-Json -Depth 3
   Invoke-WebRequest http://localhost:13340/api/v1/enrollment -Method POST -ContentType "application/json" -Body $body -UseBasicParsing
   ```
   The agent's `Platform=Win64` capability auto-assigns it to the bundled `win-ue5` pool, which the
   stream's `agentTypes.Win64` maps to.

## The three workarounds (LocalExecutor on an installed engine)

Running the Local executor from an **installed agent + installed engine** (no UE source tree, no
Horde source tree) hits three walls. All three are config-level fixes — no binaries patched.
Source line references are UE 5.6.1 (`Engine/Source/Programs/Horde/`).

### 1. `LocalExecutorSettings.WorkspaceDir` can never be configured — junction + stub sentinel

`LocalExecutorFactory` injects `IOptions<LocalExecutorSettings>`, but `DriverApp.RegisterServices`
only binds `DriverSettings` (the parent class) — the nested `LocalExecutor` section is **never
registered with DI**, so `WorkspaceDir` is always `null` no matter what any `appsettings*.json`
says. With `WorkspaceDir == null`, `LocalExecutor.FindWorkspaceRoot()` walks parent directories of
the JobDriver binary looking for `Engine/Source/Programs/Horde/Horde.sln` — which only exists in a
**source** checkout, so an installed deployment dies with *"Unable to find workspace root
directory"*.

**Fix:** make the walk-up succeed at the agent root, and let the agent root *be* the workspace:

```powershell
# G:\HordeAgent\Engine -> the installed engine (RunUAT.bat etc. resolve through this)
cmd /c mklink /J "G:\HordeAgent\Engine" "G:\UnrealEngine\UE_5.6\Engine"
# Empty sentinel so FindWorkspaceRoot() returns G:\HordeAgent\
New-Item -ItemType Directory -Force "G:\HordeAgent\Engine\Source\Programs\Horde" | Out-Null
New-Item -ItemType File "G:\HordeAgent\Engine\Source\Programs\Horde\Horde.sln" | Out-Null
```

The BuildGraph `-Script=` is an absolute path into this repo's working tree, so the workspace root
only needs to provide `Engine/` — which the junction does.

### 2. "No matching clientspecs found!" — `-NoP4` must come from the template

`LocalExecutor` passes `useP4 = null` to `ExecuteAutomationToolAsync`, which only appends `-NoP4`
when `useP4 is false` — so UAT defaults to P4-enabled and dies looking for a clientspec mapping
the agent's CWD. There is no stream/driver setting that flips this for the Local executor.

**Fix:** put `-NoP4` in the template's fixed `arguments` (see
[`config/game-main.stream.json`](config/game-main.stream.json)). Unrecognized batch arguments land
in `_additionalArguments`, which **both** `SetupAsync` and `ExecuteAsync` append to the UAT command
line — so the flag reaches every step including Setup Build.

### 3. Job-submit API `arguments` REPLACE the template's — omit them

`POST /api/v1/jobs` with an `arguments` array **replaces** the template's fixed `arguments`
entirely (it does not merge). First attempt passed only `-Target=...` and the job ran UAT with no
`-Script=` and no `-NoP4`.

**Fix:** omit `arguments` and let template defaults + the default list-parameter apply:

```powershell
$body = @{ streamId = "game-main"; templateId = "lyra-buildgraph" } | ConvertTo-Json
Invoke-WebRequest http://localhost:13340/api/v1/jobs -Method POST -ContentType "application/json" -Body $body -UseBasicParsing
```

To run a different target, either change the template's `default` item, or pass the **complete**
argument list (fixed args + target) in the POST.

## Verifying a run

```powershell
# Job + step states
(Invoke-WebRequest http://localhost:13340/api/v1/jobs/<jobId> -UseBasicParsing).Content | ConvertFrom-Json
# Step log (logId from the step object)
(Invoke-WebRequest "http://localhost:13340/api/v1/logs/<logId>/lines?count=400" -UseBasicParsing).Content | ConvertFrom-Json
```

Green run shape: batch 1 `Setup Build = Completed/Success` (BuildGraph `-ListOnly` export), batch 2
`Compile Lyra Editor = Completed/Success` (UBT compile, 405 actions on the first run).

## Machine-state checklist (session start)

- [ ] `Test-Path G:\HordeAgent\Engine` — junction intact
- [ ] `Test-Path G:\HordeAgent\Engine\Source\Programs\Horde\Horde.sln` — sentinel intact
- [ ] `G:\HordeAgent\JobDriver\appsettings.json` has `"Driver": { "Executor": "Local" }`
- [ ] Stream template `arguments` include `-NoP4`
- [ ] Server answering on `:13340`; agent shows `online: true` in `/api/v1/agents`
