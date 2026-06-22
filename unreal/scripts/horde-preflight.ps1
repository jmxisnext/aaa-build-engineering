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
