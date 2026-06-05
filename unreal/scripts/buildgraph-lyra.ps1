<#
.SYNOPSIS
  Track 4, rung #4: run the Lyra compile -> cook -> package pipeline as a single
  BuildGraph script (RunUAT BuildGraph). The bridge from three standalone wrappers to
  one declarative pipeline that TeamCity drives in rung #5.

.DESCRIPTION
  Auto-discovers the engine + Lyra .uproject (see _unreal-common.ps1), then invokes
  RunUAT.bat BuildGraph against unreal/buildgraph/lyra-pipeline.xml. The project + archive
  dir are injected with -set: so the graph follows the same discovery as the other wrappers.
  Times the run, tees the full log to unreal/.logs/, emits a JSON metric to unreal/.metrics/.

  Run:
      pwsh -File unreal/scripts/buildgraph-lyra.ps1 -ListOnly   # validate: parse + print the node graph (no build)
      pwsh -File unreal/scripts/buildgraph-lyra.ps1             # run the whole pipeline for real
      pwsh -File unreal/scripts/buildgraph-lyra.ps1 -DryRun     # resolve + print the command only

.NOTES
  -ListOnly is the cheap first check (UAT startup + schema parse, ~1 min, no compile/cook).
  A real run re-runs Compile -> Cook -> Package; with a warm DDC the cook is far cheaper than
  the ~24 min cold cook. Exit 0 on success.
#>
[CmdletBinding()]
param(
  [string]$Script,                          # default: ..\buildgraph\lyra-pipeline.xml
  [string]$Target = 'Lyra Pipeline',
  [string]$ArchiveDir = 'D:\LyraPackaged',
  [string]$EnginePath,
  [string]$Uproject,
  [string]$DDCPath = 'D:\UE-DDC',
  [switch]$ListOnly,                         # parse + print the graph, do not build
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

$unrealDir = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $unrealDir 'buildgraph\lyra-pipeline.xml' }
if (-not (Test-Path $Script)) { throw "BuildGraph script not found: $Script" }

$EnginePath = Find-UnrealEngine -EnginePath $EnginePath
if (-not $EnginePath) { throw 'No UE5 engine found (pass -EnginePath).' }
$uat = Join-Path $EnginePath 'Engine\Build\BatchFiles\RunUAT.bat'
if (-not (Test-Path $uat)) { throw "RunUAT.bat not found: $uat" }

$Uproject = Find-LyraUproject -Uproject $Uproject
if (-not $Uproject -or -not (Test-Path $Uproject)) { throw 'Lyra .uproject not found (pass -Uproject).' }

$uatArgs = @(
  'BuildGraph',
  "-Script=$Script",
  "-Target=$Target",
  "-set:ProjectPath=$Uproject",
  "-set:ArchiveDir=$ArchiveDir"
)
if ($ListOnly) { $uatArgs += '-ListOnly' }

Write-Host "Engine : $EnginePath"
Write-Host "Script : $Script"
Write-Host "Target : $Target$(if ($ListOnly){'  (ListOnly - validate, no build)'})"
Write-Host "Cmd    : RunUAT.bat $($uatArgs -join ' ')"
if ($DryRun) { Write-Host 'DryRun - not invoking RunUAT.'; exit 0 }

New-Item -ItemType Directory -Force -Path $DDCPath | Out-Null
${env:UE-LocalDataCachePath} = $DDCPath

$logDir = Join-Path $unrealDir '.logs'
$metricDir = Join-Path $unrealDir '.metrics'
New-Item -ItemType Directory -Force -Path $logDir, $metricDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$mode = if ($ListOnly) { 'listonly' } else { 'run' }
$logFile = Join-Path $logDir "buildgraph-Lyra-$mode-$stamp.log"

Write-Host "Log    : $logFile"
Write-Host "Starting BuildGraph ($mode)..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $uat @uatArgs 2>&1 | Tee-Object -FilePath $logFile
$exit = $LASTEXITCODE
$sw.Stop()
$dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)

$metric = [pscustomobject]@{
  track       = 'unreal'
  step        = 'buildgraph'
  target      = $Target
  listOnly    = [bool]$ListOnly
  success     = ($exit -eq 0)
  exitCode    = $exit
  durationSec = $dur
  script      = $Script
  engine      = $EnginePath
  uproject    = $Uproject
  utc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$metricFile = Join-Path $metricDir "buildgraph-Lyra-$mode-$stamp.json"
$metric | ConvertTo-Json | Set-Content -Path $metricFile -Encoding UTF8

Write-Host ''
if ($exit -eq 0) {
  Write-Host "BUILDGRAPH $($mode.ToUpper()) OK - '$Target' in ${dur}s" -ForegroundColor Green
} else {
  Write-Host "BUILDGRAPH FAILED (exit $exit) after ${dur}s - see $logFile" -ForegroundColor Red
}
Write-Host "metric: $metricFile"
exit $exit
