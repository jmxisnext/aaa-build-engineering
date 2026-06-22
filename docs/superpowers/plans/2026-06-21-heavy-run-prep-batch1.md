# Heavy-Run Prep — Batch 1 (turnkey + warm Horde) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the next heavy Horde session reduce to one command + the run — by configuring a shared warm DDC and a one-command preflight that verifies the machine-state checklist and enforces the serialization guardrails.

**Architecture:** Two new PowerShell scripts under `unreal/scripts/` following the repo's existing pattern (pure logic in `_unreal-common.ps1`, unit-tested directly; scripts carry a `-DryRun` and are smoke-tested as child processes via the `_assert.ps1` harness). Plus two trivial config/doc fixes.

**Tech Stack:** PowerShell 7 (pwsh), the repo's `_assert.ps1` test harness (no Pester), Docker Compose `.env` for the version pin.

## Global Constraints

- **Offline only.** No heavy services are brought up by this batch; no live Horde/UE/TeamCity run.
- **Test harness:** dot-source `unreal/tests/_assert.ps1`; assertions are `Assert-True/Assert-Equal/Assert-Match`; every test file ends with `Assert-Summary`. Tests must pass with **no live services** (param-contract via `Get-Command`, pure-function unit tests, and `-DryRun` child-process smoke).
- **Script pattern:** `[CmdletBinding()] param(...)` with a `-DryRun` switch that performs **zero** side effects and exits 0; mirror `unreal/scripts/emit-run-metric.ps1`.
- **Drive placement (verbatim from spec / `dev-machine-specs`):** DDC → **D:** (NVMe scratch); installs → G:; source → J:. Never put the DDC on C:.
- **RAM ceiling:** 31 GB — the UE+Horde stack must **never** run concurrently with the TeamCity/Docker stack.
- **Commit after each task.** Commit trailers per repo convention.
- **Already verified, NOT in scope:** the CSRF-on-writes fix — `ci/scripts/_ci-common.ps1` `Invoke-TC` already sends `X-TC-CSRF-Token` on POST/PUT/DELETE and `bench-agents.ps1` already routes all writes through it (SEEDS.md line 16 hypothesis disproven).

---

### Task 1: Shared DDC config — `set-shared-ddc.ps1`

**Files:**
- Create: `unreal/scripts/set-shared-ddc.ps1`
- Test: `unreal/tests/set-shared-ddc.Tests.ps1`
- Modify: `unreal/README.md` (add a short "Shared DDC" section)

**Interfaces:**
- Produces: `unreal/scripts/set-shared-ddc.ps1` — params `-Path` (default `D:\DDC-Shared`), `-Scope` (`ValidateSet User,Machine`, default `User`), `-DryRun`. Sets the `UE-SharedDataCachePath` environment variable and creates the folder. Refuses a `C:` path.
- Consumed by: Task 2's preflight (which reads `UE-SharedDataCachePath`).

- [ ] **Step 1: Write the failing test**

Create `unreal/tests/set-shared-ddc.Tests.ps1`:

```powershell
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
$script = Join-Path $here "..\scripts\set-shared-ddc.ps1"

# --- param contract ---
$cmd = Get-Command $script
Assert-True $cmd.Parameters.ContainsKey('Path')   'has -Path'
Assert-True $cmd.Parameters.ContainsKey('Scope')  'has -Scope'
Assert-True $cmd.Parameters.ContainsKey('DryRun') 'has -DryRun'
$scopeSet = ($cmd.Parameters['Scope'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
Assert-True ($scopeSet -contains 'User')    '-Scope allows User'
Assert-True ($scopeSet -contains 'Machine') '-Scope allows Machine'

# --- -DryRun writes nothing: the real env var is unchanged ---
$before = [Environment]::GetEnvironmentVariable('UE-SharedDataCachePath','User')
$out = & pwsh -NoProfile -File $script -Path 'D:\DDC-Shared' -DryRun 2>&1
Assert-Equal 0 $LASTEXITCODE 'set-shared-ddc -DryRun exits 0'
Assert-Match 'UE-SharedDataCachePath' ($out | Out-String) 'DryRun mentions the env var'
$after = [Environment]::GetEnvironmentVariable('UE-SharedDataCachePath','User')
Assert-Equal "$before" "$after" 'DryRun did NOT change the real env var'

# --- refuses a C: DDC path ---
$null = & pwsh -NoProfile -File $script -Path 'C:\DDC' -DryRun 2>&1
Assert-True ($LASTEXITCODE -ne 0) 'refuses a C: DDC path (non-zero exit)'

Assert-Summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File unreal/tests/set-shared-ddc.Tests.ps1`
Expected: FAIL — `Get-Command` throws because `unreal/scripts/set-shared-ddc.ps1` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `unreal/scripts/set-shared-ddc.ps1`:

```powershell
<#
.SYNOPSIS
  Configure the shared UE DDC so the TeamCity and Horde cooks share one warm cache on the D:\
  NVMe scratch drive (turns a ~24-min cold Lyra cook into ~1 min). Sets UE-SharedDataCachePath
  and creates the folder. Idempotent; -DryRun writes nothing.

.DESCRIPTION
  Both cooks run on this one box (WS01) through the same installed engine, so a single local
  folder on D:\ is genuinely shared between them. UE-SharedDataCachePath overrides the engine's
  Shared DDC node path. Default scope = User (no admin); -Scope Machine needs an elevated shell.

      pwsh -File unreal/scripts/set-shared-ddc.ps1                       # D:\DDC-Shared, User
      pwsh -File unreal/scripts/set-shared-ddc.ps1 -Scope Machine        # all accounts (elevated)
      pwsh -File unreal/scripts/set-shared-ddc.ps1 -DryRun

.NOTES
  Exit 0 on success. A NEW shell (and an agent restart) picks up the var. See unreal/README.md.
#>
[CmdletBinding()]
param(
  [string]$Path = 'D:\DDC-Shared',
  [ValidateSet('User','Machine')][string]$Scope = 'User',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$var = 'UE-SharedDataCachePath'

if ($Path -match '^[Cc]:') {
  throw "Refusing to put the DDC on C: ($Path) - use the D:\ NVMe scratch drive (ROADMAP_NEXT 'Hardware reality')."
}

$current = [Environment]::GetEnvironmentVariable($var, $Scope)
Write-Host "$var ($Scope scope): current=[$current]  ->  target=[$Path]"

if ($DryRun) {
  Write-Host 'DryRun - creating nothing, setting nothing.' -ForegroundColor DarkCyan
  exit 0
}

New-Item -ItemType Directory -Force -Path $Path | Out-Null
[Environment]::SetEnvironmentVariable($var, $Path, $Scope)
Write-Host "OK - $var set to $Path ($Scope). Open a NEW shell (and restart the Horde agent) to pick it up." -ForegroundColor Green
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File unreal/tests/set-shared-ddc.Tests.ps1`
Expected: `ALL PASS`.

- [ ] **Step 5: Document the DDC in `unreal/README.md`**

Append this section to `unreal/README.md` (read the file first; add at the end):

```markdown
## Shared DDC (cook-warm optimizer)

Both the TeamCity-driven and Horde-driven Lyra cooks run on this one box, so they can share a
single Derived Data Cache on the D:\ NVMe scratch drive. A warm shared DDC turns a cold
(~24.6 min, Vulkan SM6 perms uncached) cook into ~1 min.

- Configure once: `pwsh -File unreal/scripts/set-shared-ddc.ps1` (sets `UE-SharedDataCachePath`
  to `D:\DDC-Shared`). Open a new shell / restart the Horde agent so it inherits the var.
- **Warm once, reuse:** run a TeamCity cook (which you do anyway) to fill the cache; the next
  Horde cook reads the same folder and skips the shader compile. `horde-preflight.ps1` checks the
  var is set before a heavy run.
```

- [ ] **Step 6: Commit**

```bash
git add unreal/scripts/set-shared-ddc.ps1 unreal/tests/set-shared-ddc.Tests.ps1 unreal/README.md
git commit -m "feat(unreal): shared DDC config (set-shared-ddc.ps1) for warm cross-orchestrator cooks"
```

---

### Task 2: Horde preflight — `Get-PreflightVerdict` + `horde-preflight.ps1`

**Files:**
- Modify: `unreal/scripts/_unreal-common.ps1` (append `Get-PreflightVerdict`)
- Create: `unreal/scripts/horde-preflight.ps1`
- Test: `unreal/tests/horde-preflight.Tests.ps1`
- Modify: `unreal/horde/README.md` (correct the stale item-4 status)

**Interfaces:**
- Consumes: `Get-PreflightVerdict -Checks <object[]>` from `_unreal-common.ps1`; the `UE-SharedDataCachePath` var from Task 1.
- Produces: `Get-PreflightVerdict([object[]]$Checks)` → `[pscustomobject]@{ Total; Failed; Warned; Ready[bool]; ExitCode[int] }` (ExitCode 0 iff no `FAIL`; `WARN` never fails). `horde-preflight.ps1` — params `-Server` (default `http://localhost:13340`), `-P4Port` (default `localhost:1666`), `-AgentRoot` (default `G:\HordeAgent`), `-Start`, `-DryRun`.

- [ ] **Step 1: Write the failing test**

Create `unreal/tests/horde-preflight.Tests.ps1`:

```powershell
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
. (Join-Path $here "..\scripts\_unreal-common.ps1")
$script = Join-Path $here "..\scripts\horde-preflight.ps1"

# --- pure verdict logic ---
$allPass = @(
  [pscustomobject]@{ Check='a'; Status='PASS'; Detail='' }
  [pscustomobject]@{ Check='b'; Status='WARN'; Detail='' }
)
$v1 = Get-PreflightVerdict -Checks $allPass
Assert-True  $v1.Ready      'no FAIL -> Ready'
Assert-Equal 0 $v1.ExitCode 'no FAIL -> exit 0'
Assert-Equal 1 $v1.Warned   'counts WARN'

$withFail = $allPass + [pscustomobject]@{ Check='c'; Status='FAIL'; Detail='' }
$v2 = Get-PreflightVerdict -Checks $withFail
Assert-True  (-not $v2.Ready) 'a FAIL -> not Ready'
Assert-Equal 1 $v2.ExitCode   'a FAIL -> exit 1'
Assert-Equal 1 $v2.Failed     'counts FAIL'

# --- param contract ---
$cmd = Get-Command $script
foreach ($pn in 'Server','P4Port','AgentRoot','Start','DryRun') {
  Assert-True $cmd.Parameters.ContainsKey($pn) "has -$pn"
}

# --- integration smoke: runs read-only without crashing, prints a check table ---
$out = & pwsh -NoProfile -File $script -DryRun 2>&1
Assert-True ($LASTEXITCODE -in 0,1) 'preflight -DryRun exits 0 or 1 (no crash)'
Assert-Match 'Check' ($out | Out-String) 'prints a check table'

Assert-Summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File unreal/tests/horde-preflight.Tests.ps1`
Expected: FAIL — `Get-PreflightVerdict` is not defined (and the script does not exist yet).

- [ ] **Step 3a: Add the pure verdict function to `_unreal-common.ps1`**

Read `unreal/scripts/_unreal-common.ps1`, then append:

```powershell
function Get-PreflightVerdict {
  # Pure: aggregate check results (Status in PASS/WARN/FAIL) into a run-readiness verdict.
  # WARN is advisory and never fails the gate; any FAIL makes the run NOT ready (exit 1).
  param([object[]]$Checks)
  $all  = @($Checks)
  $fail = @($all | Where-Object { $_.Status -eq 'FAIL' }).Count
  $warn = @($all | Where-Object { $_.Status -eq 'WARN' }).Count
  [pscustomobject]@{
    Total    = $all.Count
    Failed   = $fail
    Warned   = $warn
    Ready    = ($fail -eq 0)
    ExitCode = $(if ($fail -eq 0) { 0 } else { 1 })
  }
}
```

- [ ] **Step 3b: Write the preflight script**

Create `unreal/scripts/horde-preflight.ps1`:

```powershell
<#
.SYNOPSIS
  Track 4 / Horde session preflight: one command that makes the heavy run "just the run".
  Verifies the machine-state checklist (junction, sentinel, Executor=Local, server, agent, p4d,
  shared DDC) AND enforces the serialization guardrails (no concurrent TeamCity/Docker stack; warn
  on low free RAM). Read-only by default; -Start brings up p4d + the agent if down.

.DESCRIPTION
  Prints a PASS/WARN/FAIL table and exits non-zero on any FAIL, so the expensive run can gate on it.
  Verdict aggregation is the unit-tested Get-PreflightVerdict (_unreal-common.ps1).

      pwsh -File unreal/scripts/horde-preflight.ps1          # check only
      pwsh -File unreal/scripts/horde-preflight.ps1 -Start   # also start p4d + agent if down
      pwsh -File unreal/scripts/horde-preflight.ps1 -DryRun  # check only, never start (CI-safe)

.NOTES
  Exit 0 = run-ready; exit 1 = a FAIL. Idempotent.
#>
[CmdletBinding()]
param(
  [string]$Server    = 'http://localhost:13340',
  [string]$P4Port    = 'localhost:1666',
  [string]$AgentRoot = 'G:\HordeAgent',
  [switch]$Start,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

function Test-Tcp([string]$TcpHost, [int]$Port) {
  $c = New-Object Net.Sockets.TcpClient
  try { $c.Connect($TcpHost, $Port); return $true } catch { return $false } finally { $c.Dispose() }
}

$p4h, $p4p = $P4Port.Split(':')

if ($Start -and -not $DryRun) {
  if (-not (Test-Tcp $p4h ([int]$p4p))) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # unreal\scripts -> unreal -> repo
    $startP4 = Join-Path $repo 'perforce\scripts\start-p4d.ps1'
    if (Test-Path $startP4) { Write-Host 'Starting p4d ...' -ForegroundColor Cyan; & $startP4 }
    else { Write-Host "WARN: $startP4 not found; start p4d manually." -ForegroundColor Yellow }
  }
  $online = $false
  try { $online = [bool]((Invoke-RestMethod "$Server/api/v1/agents" -TimeoutSec 5) | Where-Object { $_.online }) } catch {}
  if (-not $online) {
    $dll = Join-Path $AgentRoot 'HordeAgent.dll'
    if (Test-Path $dll) {
      Write-Host 'Starting Horde agent (detached) ...' -ForegroundColor Cyan
      Start-Process dotnet -ArgumentList "`"$dll`"" -WorkingDirectory $AgentRoot -WindowStyle Hidden
    } else { Write-Host "WARN: $dll not found; start the agent manually." -ForegroundColor Yellow }
  }
  Start-Sleep -Seconds 5   # let services settle before the checks read them
}

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$name, [string]$status, [string]$detail) {
  $checks.Add([pscustomobject]@{ Check = $name; Status = $status; Detail = $detail })
}
function PF([bool]$ok) { if ($ok) { 'PASS' } else { 'FAIL' } }

# --- guardrail: the TeamCity/Docker stack must NOT be up (31 GB ceiling: never concurrent) ---
$stackUp = $false
try {
  $names = & docker ps --filter 'name=teamcity-server' --format '{{.Names}}' 2>$null
  $stackUp = [bool]($names -match 'teamcity-server')
} catch { $stackUp = $false }   # docker absent/stopped => no conflict
Add-Check 'Guardrail: TeamCity/Docker stack down' (PF (-not $stackUp)) `
  $(if ($stackUp) { 'teamcity-server is RUNNING - docker compose down before a heavy UE/Horde run' } else { 'no competing CI stack' })

# --- guardrail: free physical RAM (WARN only) ---
$os = Get-CimInstance Win32_OperatingSystem
$freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)   # FreePhysicalMemory is KB; /1MB -> GB
Add-Check 'Free physical RAM' $(if ($freeGB -ge 8) { 'PASS' } else { 'WARN' }) `
  "$freeGB GB free (heavy cook wants headroom under the 31 GB ceiling)"

# --- junction + sentinel (LocalExecutor workaround #1) ---
$junction = Join-Path $AgentRoot 'Engine'
Add-Check 'Agent Engine junction' (PF (Test-Path $junction)) $junction
$sentinel = Join-Path $AgentRoot 'Engine\Source\Programs\Horde\Horde.sln'
Add-Check 'Workspace-root sentinel' (PF (Test-Path $sentinel)) $sentinel

# --- JobDriver Executor=Local (workaround #2) ---
$driverCfg = Join-Path $AgentRoot 'JobDriver\appsettings.json'
$execLocal = $false
if (Test-Path $driverCfg) {
  try { $execLocal = ((Get-Content $driverCfg -Raw | ConvertFrom-Json).Driver.Executor -eq 'Local') } catch {}
}
Add-Check 'JobDriver Executor=Local' (PF $execLocal) $driverCfg

# --- shared DDC env var set + dir exists (the cook-warm optimizer) ---
$ddc = [Environment]::GetEnvironmentVariable('UE-SharedDataCachePath')
$ddcOk = $ddc -and (Test-Path $ddc)
Add-Check 'Shared DDC (UE-SharedDataCachePath)' (PF $ddcOk) `
  $(if ($ddc) { $ddc } else { 'unset - run unreal/scripts/set-shared-ddc.ps1' })

# --- Horde server answering on :13340 ---
$serverOk = $false
try { $null = Invoke-RestMethod "$Server/api/v1/server/info" -TimeoutSec 5; $serverOk = $true } catch {}
Add-Check 'Horde server reachable' (PF $serverOk) $Server

# --- agent online ---
$agentOnline = $false
try { $agentOnline = [bool]((Invoke-RestMethod "$Server/api/v1/agents" -TimeoutSec 5) | Where-Object { $_.online }) } catch {}
Add-Check 'Horde agent online' (PF $agentOnline) 'GET /api/v1/agents (online:true)'

# --- p4d up on :1666 (server validates the P4 cluster at lease assignment) ---
Add-Check 'p4d reachable' (PF (Test-Tcp $p4h ([int]$p4p))) $P4Port

Write-Host ''
$checks | Format-Table Check, Status, Detail -AutoSize | Out-String | Write-Host
$verdict = Get-PreflightVerdict -Checks $checks
if ($verdict.Ready) {
  Write-Host 'PREFLIGHT GREEN - Horde run-ready.' -ForegroundColor Green
} else {
  Write-Host "$($verdict.Failed) check(s) FAILED - not run-ready (see FAIL rows above)." -ForegroundColor Yellow
}
exit $verdict.ExitCode
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File unreal/tests/horde-preflight.Tests.ps1`
Expected: `ALL PASS`. (On a box with Horde down, the smoke run prints the table and exits 1 — the test asserts exit ∈ {0,1} and that a table rendered, so it passes.)

- [ ] **Step 5: Correct the stale Horde README status**

In `unreal/horde/README.md`, replace the `## Status` item 4 line (currently `⬜`) so it reflects the in-graph stamp now in `lyra-pipeline.xml`:

Old:
```markdown
4. CL-stamp parity with the TeamCity package. ⬜ — the BuildGraph `Package Lyra` node writes the
```
New:
```markdown
4. CL-stamp parity with the TeamCity package. ✅ **AUTHORED 2026-06-21 (in-graph)** — `lyra-pipeline.xml`
   now has a `Stamp Lyra` node (`Requires="Package Lyra"`, `Aggregate Lyra Pipeline` requires it)
   running `stamp-lyra-package.ps1 -Source $(Source)`, so a live Horde run stamps the package in-graph.
   Verify on the next live run. (Was ⬜ — predated commit c0688df.) The BuildGraph `Package Lyra` node writes the
```

- [ ] **Step 6: Commit**

```bash
git add unreal/scripts/_unreal-common.ps1 unreal/scripts/horde-preflight.ps1 unreal/tests/horde-preflight.Tests.ps1 unreal/horde/README.md
git commit -m "feat(unreal): horde-preflight.ps1 (checklist + serialization guardrails); fix stale CL-stamp status"
```

---

### Task 3: Pin `TEAMCITY_VERSION` for reproducible CI infra

**Files:**
- Create: `ci/.env`
- Modify: `ci/docker-compose.yml` (update the drift note comment)

**Interfaces:**
- Produces: `ci/.env` with `TEAMCITY_VERSION=<pinned>`, which Docker Compose auto-reads, freezing the `:-latest` interpolation in `docker-compose.yml` (server + both agents + the agent image build arg all thread it).

- [ ] **Step 1: Create the pin**

Create `ci/.env`:

```
# Pin the TeamCity server+agent release so `docker compose pull/up` does not silently drift
# (the compose files default to :-latest). Compose auto-loads this file from the project dir.
# Pinned to the running 2026.1 line for reproducibility. Bumping to a newer patch (e.g. 2026.1.1,
# which shipped 2 security fixes) is a DELIBERATE edit here, not an accidental `pull`.
# Verify the exact tag exists: `docker image ls jetbrains/teamcity-server` or Docker Hub.
TEAMCITY_VERSION=2026.1
```

- [ ] **Step 2: Update the compose drift note**

In `ci/docker-compose.yml`, the header comment mentions state under `./data/`. Add one line under the existing top comment block (after line 10, before `services:`):

```yaml
# Version pinning: TEAMCITY_VERSION is set in ci/.env (auto-loaded by compose) so the
# server+agents stay on a fixed release. Change the pin there, never rely on :-latest.
```

- [ ] **Step 3: Verify (offline) the pin resolves**

Run: `pwsh -NoProfile -Command "Get-Content ci/.env"`
Expected: shows `TEAMCITY_VERSION=2026.1`.
(Optional, needs Docker: `docker compose -f ci/docker-compose.yml config | Select-String image` shows `:2026.1`, no `:latest`.)

- [ ] **Step 4: Commit**

```bash
git add ci/.env ci/docker-compose.yml
git commit -m "chore(ci): pin TEAMCITY_VERSION via ci/.env to stop silent image drift"
```

---

## Self-Review

**Spec coverage (Batch 1 items from §3.1/§3.2/§4):**
- `horde-preflight.ps1` + guardrails → Task 2 ✓
- shared-DDC config (Batch-1 pull-forward) → Task 1 ✓
- CSRF fix → **verified already done**, no task (documented in Global Constraints) ✓
- README item-4 status fix → Task 2 Step 5 ✓
- pin `TEAMCITY_VERSION` → Task 3 ✓
- (Cooker dep-edges/`--dry-run`/pack = Batch 2; CI Dockerfile/persistence = Batch 3 — separate plans.)

**Placeholder scan:** none — every code step has complete, runnable content.

**Type/name consistency:** `Get-PreflightVerdict` returns `{Total,Failed,Warned,Ready,ExitCode}` — the same names the test asserts (`Ready`, `ExitCode`, `Warned`, `Failed`). Script params (`Server,P4Port,AgentRoot,Start,DryRun`) match the param-contract test. `UE-SharedDataCachePath` is the single var name across set-shared-ddc, the README, and the preflight check.
