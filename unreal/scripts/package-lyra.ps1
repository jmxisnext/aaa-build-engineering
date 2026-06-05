<#
.SYNOPSIS
  Track 4, rung #3: stage + package a runnable Lyra build via UAT (RunUAT BuildCookRun,
  build + stage + pak + archive). Reuses the rung #2 cook (-skipcook). Third rung on the
  compile -> cook -> package -> BuildGraph -> TeamCity ladder.

.DESCRIPTION
  Auto-discovers the engine + Lyra .uproject (see _unreal-common.ps1), then invokes
  RunUAT.bat BuildCookRun to:
    -build    compile the standalone GAME target (LyraGame) - rung #1 only built the EDITOR;
              a runnable package needs the game .exe, not the editor.
    -skipcook reuse the already-cooked content from rung #2 (Saved\Cooked\Windows). If that
              ever errors as "stale/missing cook", switch to -cook -iterate (warm DDC -> fast).
    -stage    lay out the staged build (StagedBuilds\Windows).
    -pak      pack cooked content into .pak/.ucas/.utoc.
    -archive  copy the final shippable build to -archivedirectory.
  Times the run, tees the full log to unreal/.logs/, emits a JSON metric to unreal/.metrics/.

  Version-stamping the package with the Perforce CL (the Track-2 pattern, and the track's
  ultimate demoable artifact) is a deliberate follow-up - it needs the P4 infra up - so this
  wrapper packages first; the stamp is wired in next.

  Run:
      pwsh -File unreal/scripts/package-lyra.ps1                    # package Win64 Development
      pwsh -File unreal/scripts/package-lyra.ps1 -DryRun           # resolve + print the command
      pwsh -File unreal/scripts/package-lyra.ps1 -ArchiveDir D:\X  # override archive location

.NOTES
  Game-target build (~1-2 min) + stage + pak + archive of ~1.8 GB cooked content. Exit 0 on
  success. The archive dir is wiped by UAT per-platform before it lays down the fresh build.
#>
[CmdletBinding()]
param(
  [string]$Platform = 'Win64',
  [ValidateSet('Debug','DebugGame','Development','Shipping','Test')]
  [string]$ClientConfig = 'Development',
  [string]$Target = 'LyraGame',          # standalone GAME target (not LyraEditor)
  [string]$ArchiveDir = 'D:\LyraPackaged',# shippable build lands here (NVMe, off C:)
  [string]$EnginePath,
  [string]$Uproject,
  [string]$DDCPath = 'D:\UE-DDC',         # keep any DDC reads/writes on NVMe (drive plan)
  [switch]$Clean,                          # wipe staged output first for a clean stage
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

$unrealDir = Split-Path -Parent $PSScriptRoot

$EnginePath = Find-UnrealEngine -EnginePath $EnginePath
if (-not $EnginePath) { throw 'No UE5 engine found (pass -EnginePath).' }
$uat = Join-Path $EnginePath 'Engine\Build\BatchFiles\RunUAT.bat'
if (-not (Test-Path $uat)) { throw "RunUAT.bat not found: $uat" }

$Uproject = Find-LyraUproject -Uproject $Uproject
if (-not $Uproject -or -not (Test-Path $Uproject)) { throw 'Lyra .uproject not found (pass -Uproject).' }
$projDir = Split-Path -Parent $Uproject

$uatArgs = @(
  'BuildCookRun',
  "-project=$Uproject",
  '-noP4',
  "-platform=$Platform",
  "-clientconfig=$ClientConfig",
  "-target=$Target",
  '-build',
  '-skipcook',
  '-stage',
  '-pak',
  '-archive',
  "-archivedirectory=$ArchiveDir",
  '-nocompileeditor',
  '-unattended',
  '-utf8output'
)

Write-Host "Engine : $EnginePath"
Write-Host "Project: $Uproject"
Write-Host "Package: $Target $Platform $ClientConfig -> $ArchiveDir"
Write-Host "Cmd    : RunUAT.bat $($uatArgs -join ' ')"
if ($DryRun) { Write-Host 'DryRun - not invoking RunUAT.'; exit 0 }

New-Item -ItemType Directory -Force -Path $DDCPath | Out-Null
${env:UE-LocalDataCachePath} = $DDCPath

if ($Clean) {
  # Clean stage: remove prior staged output for this platform so it lays down fresh.
  # (Win64 stages to StagedBuilds\Windows - same build-vs-cooked platform rename as lesson #4.)
  $stageDir = switch ($Platform) { 'Win64' { 'Windows' } default { $Platform } }
  $staged = Join-Path $projDir "Saved\StagedBuilds\$stageDir"
  if (Test-Path $staged) { Write-Host "Clean  : removing $staged"; Remove-Item $staged -Recurse -Force -ErrorAction SilentlyContinue }
}

$logDir = Join-Path $unrealDir '.logs'
$metricDir = Join-Path $unrealDir '.metrics'
New-Item -ItemType Directory -Force -Path $logDir, $metricDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path $logDir "package-Lyra-$Platform-$ClientConfig-$stamp.log"

Write-Host "Log    : $logFile"
Write-Host 'Starting package (build + stage + pak + archive)...'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $uat @uatArgs 2>&1 | Tee-Object -FilePath $logFile
$exit = $LASTEXITCODE
$sw.Stop()
$dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)

$metric = [pscustomobject]@{
  track         = 'unreal'
  step          = 'package'
  target        = $Target
  platform      = $Platform
  configuration = $ClientConfig
  clean         = [bool]$Clean
  archiveDir    = $ArchiveDir
  success       = ($exit -eq 0)
  exitCode      = $exit
  durationSec   = $dur
  engine        = $EnginePath
  uproject      = $Uproject
  utc           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$metricFile = Join-Path $metricDir "package-Lyra-$Platform-$ClientConfig-$stamp.json"
$metric | ConvertTo-Json | Set-Content -Path $metricFile -Encoding UTF8

Write-Host ''
if ($exit -eq 0) {
  Write-Host "PACKAGE SUCCEEDED - $Target $Platform $ClientConfig in ${dur}s -> $ArchiveDir" -ForegroundColor Green
} else {
  Write-Host "PACKAGE FAILED (exit $exit) after ${dur}s - see $logFile" -ForegroundColor Red
}
Write-Host "metric: $metricFile"
exit $exit
