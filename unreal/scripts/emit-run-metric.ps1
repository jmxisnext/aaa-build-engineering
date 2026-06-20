<#
.SYNOPSIS
  Track 4, Horde parity: emit a post-run `step=buildgraph` metric for an orchestrator run
  that did NOT go through buildgraph-lyra.ps1 -- i.e. a Horde job, where the Horde agent runs
  the BuildGraph XML directly (the PowerShell wrapper never executes). Formalizes the metric
  that was hand-assembled for the 2026-06-13 Horde run so the NEXT live run regenerates it
  reproducibly.

.DESCRIPTION
  The dashboard's "Orchestrator parity -- Horde vs TeamCity" row groups buildgraph metrics by
  `source` (collect-metrics.ps1). The TeamCity/standalone side gets its buildgraph metric from
  the wrapper; the Horde side has no wrapper, so this script writes the Horde-side metric from
  the job facts the operator reads off the completed Horde job (duration, outcome, job id).

  Writes unreal/.metrics/buildgraph-Lyra-<source>-<stamp>.json. Does NOT time anything (the run
  already happened) -- the duration is supplied. Touches nothing in the green TeamCity path.

  Run (after a Horde job completes; facts from the Horde dashboard / job page):
      pwsh -File unreal/scripts/emit-run-metric.ps1 -Source horde -DurationSec 1711 `
           -JobId 6a2da13d2729362a627914ca -Server http://localhost:13340 -Changelist 51
      pwsh -File unreal/scripts/emit-run-metric.ps1 -Source horde -DurationSec 1711 -DryRun

.NOTES
  Exit 0 on success. Engine/uproject are auto-discovered for provenance only (best-effort; the
  metric still emits if they are absent). The collect-metrics reader only requires
  source/target/durationSec/success/utc, all of which are always written.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('standalone','teamcity','horde')]
  [string]$Source,
  [Parameter(Mandatory)][double]$DurationSec,
  [string]$Target = 'Lyra Pipeline',
  [int]$ExitCode = 0,                          # 0 = Success; non-zero -> success:false
  [string]$Orchestrator,                       # display name; derived from -Source when omitted
  [string]$JobId,                              # Horde job id (provenance)
  [string]$Server,                             # Horde server URL (provenance)
  [string]$Changelist,                         # content CL the job ran at
  [object[]]$Stages,                           # optional per-node [{step,durationSec,outcome}]
  [string]$Script,                             # default: ..\buildgraph\lyra-pipeline.xml
  [string]$EnginePath,
  [string]$Uproject,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

$unrealDir = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $unrealDir 'buildgraph\lyra-pipeline.xml' }

# provenance only -- best-effort, never fatal (the run already happened elsewhere)
if (-not $EnginePath) { $EnginePath = Find-UnrealEngine }
if (-not $Uproject)   { $Uproject   = Find-LyraUproject }

$metric = New-RunMetric -Source $Source -DurationSec $DurationSec -Target $Target -ExitCode $ExitCode `
  -Orchestrator $Orchestrator -JobId $JobId -Server $Server -Changelist $Changelist -Stages $Stages `
  -Script $Script -Engine $EnginePath -Uproject $Uproject
$json = ([pscustomobject]$metric) | ConvertTo-Json -Depth 5

Write-Host "Source       : $($metric.source)  (orchestrator: $($metric.orchestrator))"
Write-Host "Target       : $($metric.target)"
Write-Host "DurationSec  : $($metric.durationSec)  (success: $($metric.success))"
if ($JobId)  { Write-Host "Horde job    : $JobId @ $Server" }
if ($DryRun) { Write-Host 'DryRun - writing nothing.'; Write-Host '----- metric (preview) -----'; Write-Host $json; exit 0 }

$metricDir = Join-Path $unrealDir '.metrics'
New-Item -ItemType Directory -Force -Path $metricDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$metricFile = Join-Path $metricDir "buildgraph-Lyra-$Source-$stamp.json"
$json | Set-Content -Path $metricFile -Encoding UTF8

Write-Host ''
Write-Host "RUN METRIC OK - $Source buildgraph @ ${DurationSec}s" -ForegroundColor Green
Write-Host "metric: $metricFile"
exit 0
