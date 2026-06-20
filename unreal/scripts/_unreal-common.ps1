<#
.SYNOPSIS
  Shared Track-4 helpers: locate the installed UE5 engine + Lyra project
  (Find-UnrealEngine / Find-LyraUproject) and run a timed build step with metric
  emission (Invoke-TimedBuildStep). Dot-sourced by check-prereqs.ps1 and the
  compile/cook/package/BuildGraph wrappers so this logic lives in exactly one
  place (a fourth copy is how it drifts - cf. perforce lessons-learned).
#>

function Find-UnrealEngine {
  [CmdletBinding()] param([string]$EnginePath)
  if ($EnginePath) { return $EnginePath }
  # canonical source: the Epic launcher manifest lists every installed engine
  $manifest = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
  if (Test-Path $manifest) {
    try {
      $items = (Get-Content $manifest -Raw | ConvertFrom-Json).InstallationList
      $eng = $items | Where-Object { $_.AppName -like 'UE_5.*' } |
             Sort-Object AppName -Descending | Select-Object -First 1
      if ($eng) { return $eng.InstallLocation }
    } catch { }
  }
  return $null
}

function Find-LyraUproject {
  [CmdletBinding()] param([string]$Uproject)
  if ($Uproject) { return $Uproject }
  # 'Create Project' sample projects are NOT in the launcher manifest - scan the
  # usual project roots. Sample folder is 'LyraStarterGame', project is 'Lyra.uproject'.
  $roots = @(
    'G:\UnrealProjects', 'G:\Unreal Projects',
    (Join-Path $env:USERPROFILE 'Documents\Unreal Projects'),
    'D:\UnrealProjects', 'G:\', 'D:\'
  ) | Where-Object { Test-Path $_ }
  foreach ($root in $roots) {
    $u = Get-ChildItem -Path $root -Filter 'Lyra*.uproject' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($u) { return $u.FullName }
  }
  return $null
}

# Run a build/cook/package/graph step under a stopwatch, tee its full output to
# unreal/.logs/, write a JSON metric to unreal/.metrics/, and return the result.
# The four rung wrappers (compile/cook/package/buildgraph) each previously carried
# an identical copy of this spine. The tool invocation is injected as $Action — a
# scriptblock that receives the resolved log path and must set $LASTEXITCODE, e.g.
#     { param($LogFile) & $build @buildArgs 2>&1 | Tee-Object -FilePath $LogFile }
# — so the spine is engine-agnostic and unit-testable with a fake command. The
# tee'd output is routed to the host (not returned) so it can't contaminate the
# result object.
#
# $Metric carries the step's domain-specific fields (target/platform/clean/...);
# the common fields (track, step, success, exitCode, durationSec, engine, uproject,
# utc) are added here. Callers keep their own success/fail console line (the wording
# differs per rung) using the returned Exit/DurationSec/LogFile/MetricFile.
function Invoke-TimedBuildStep {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Step,
    [Parameter(Mandatory)][string]$UnrealDir,
    [Parameter(Mandatory)][string]$BaseName,
    [Parameter(Mandatory)][scriptblock]$Action,
    [System.Collections.IDictionary]$Metric = @{},
    [string]$Engine,
    [string]$Uproject,
    [string]$StartMessage = "Starting $Step..."
  )
  $logDir    = Join-Path $UnrealDir '.logs'
  $metricDir = Join-Path $UnrealDir '.metrics'
  New-Item -ItemType Directory -Force -Path $logDir, $metricDir | Out-Null
  $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $logFile = Join-Path $logDir "$BaseName-$stamp.log"

  Write-Host "Log    : $logFile"
  Write-Host $StartMessage
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & $Action $logFile | Out-Host          # route the tee'd build output to the console, not our output
  # Tee-Object / Out-Host (cmdlets) do not reset the native exit code; [int] coerces
  # the empty string (no native exe ran yet) to 0 — correct: cmdlet-only pipelines exit 0.
  $exit = [int]$LASTEXITCODE
  $sw.Stop()
  $dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)

  $m = [ordered]@{ track = 'unreal'; step = $Step }
  foreach ($k in $Metric.Keys) { $m[$k] = $Metric[$k] }
  $m['success']     = ($exit -eq 0)
  $m['exitCode']    = $exit
  $m['durationSec'] = $dur
  if ($Engine)   { $m['engine']   = $Engine }
  if ($Uproject) { $m['uproject'] = $Uproject }
  $m['utc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

  $metricFile = Join-Path $metricDir "$BaseName-$stamp.json"
  ([pscustomobject]$m) | ConvertTo-Json | Set-Content -Path $metricFile -Encoding UTF8

  [pscustomobject]@{ Exit = $exit; DurationSec = $dur; LogFile = $logFile; MetricFile = $metricFile }
}

# Map a source token to its display orchestrator name. Used by the buildgraph wrapper,
# the stamp script, and the Horde run-metric emitter so the three label runs consistently
# (the dashboard groups buildgraph metrics by `source`; `orchestrator` is the display name).
function Get-OrchestratorName {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Source)
  switch ($Source) {
    'horde'      { 'Horde' }
    'teamcity'   { 'TeamCity' }
    'standalone' { 'standalone' }
    default      { $Source }
  }
}

# Assemble the RunUAT BuildGraph argument array. Single source of truth for the wrapper's
# UAT invocation so the new `-set:Source` threading is testable without an engine. Source is
# only emitted when supplied: an absent source keeps the existing TeamCity baseline behaviour
# (collect-metrics defaults a sourceless buildgraph metric to 'teamcity'), so adding the param
# is a zero-regression change to the green path. The graph's own Source Option (DefaultValue
# 'teamcity') applies when -set:Source is not passed.
function Build-BuildGraphArgs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$ArchiveDir,
    [string]$Source,
    [switch]$ListOnly
  )
  $a = @(
    'BuildGraph',
    "-Script=$Script",
    "-Target=$Target",
    "-set:ProjectPath=$ProjectPath",
    "-set:ArchiveDir=$ArchiveDir"
  )
  if ($Source)   { $a += "-set:Source=$Source" }
  if ($ListOnly) { $a += '-ListOnly' }
  return $a
}

# Build a post-run `step=buildgraph` metric object from already-known job facts (the run
# already happened, so there is nothing to time -- this is NOT Invoke-TimedBuildStep). This
# formalizes the 2026-06-13 hand-assembled Horde metric: under Horde the BuildGraph XML runs
# directly (the wrapper never executes), so the orchestrator-parity row needs an explicit
# emitter. Returns an [ordered] dict; the caller (emit-run-metric.ps1) serializes it. Fields
# mirror the shape the dashboard collector reads (step/listOnly/source/target/durationSec/
# success/utc) plus optional provenance (orchestrator/hordeJobId/hordeServer/changelist/stages).
function New-RunMetric {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('standalone','teamcity','horde')][string]$Source,
    [Parameter(Mandatory)][double]$DurationSec,
    [string]$Target = 'Lyra Pipeline',
    [int]$ExitCode = 0,
    [string]$Orchestrator,
    [string]$JobId,
    [string]$Server,
    [string]$Changelist,
    [object[]]$Stages,
    [string]$Script,
    [string]$Engine,
    [string]$Uproject,
    [string]$Utc
  )
  if (-not $Orchestrator) { $Orchestrator = Get-OrchestratorName -Source $Source }
  if (-not $Utc) { $Utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
  $m = [ordered]@{
    track        = 'unreal'
    step         = 'buildgraph'
    target       = $Target
    listOnly     = $false
    success      = ($ExitCode -eq 0)
    exitCode     = $ExitCode
    durationSec  = $DurationSec
    source       = $Source
    orchestrator = $Orchestrator
  }
  if ($JobId)      { $m['hordeJobId'] = $JobId }
  if ($Server)     { $m['hordeServer'] = $Server }
  if ($Changelist) { $m['changelist'] = $Changelist }
  if ($Script)     { $m['script'] = $Script }
  if ($Engine)     { $m['engine'] = $Engine }
  if ($Uproject)   { $m['uproject'] = $Uproject }
  if ($Stages)     { $m['stages'] = $Stages }
  $m['utc'] = $Utc
  return $m
}
