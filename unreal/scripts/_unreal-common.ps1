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
