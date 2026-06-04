<#
.SYNOPSIS
  Track 4, slice #1: compile a Lyra target via UnrealBuildTool (UBT) and record
  the wall-clock build time. Default = LyraEditor (Development, Win64) - the
  first green on the compile -> cook -> package -> BuildGraph -> TeamCity ladder.

.DESCRIPTION
  Auto-discovers the engine + Lyra .uproject (see _unreal-common.ps1), then
  invokes the engine's Build.bat. Times the build, tees the full log to
  unreal/.logs/, and emits a small JSON metric to unreal/.metrics/ (the eventual
  dashboard feed, mirroring accel/.metrics). Both dirs are gitignored.

  Run:
      pwsh -File unreal/scripts/compile-lyra.ps1            # LyraEditor Development
      pwsh -File unreal/scripts/compile-lyra.ps1 -Clean     # force full rebuild
      pwsh -File unreal/scripts/compile-lyra.ps1 -DryRun     # resolve paths only

.NOTES
  The first cold LyraEditor build is a full AAA-scale C++ compile (~10-30 min).
  Exit 0 on success, non-zero otherwise. Paths with spaces: pass -Uproject quoted.
#>
[CmdletBinding()]
param(
  [string]$Target = 'LyraEditor',
  [string]$Platform = 'Win64',
  [ValidateSet('Debug','DebugGame','Development','Shipping','Test')]
  [string]$Configuration = 'Development',
  [string]$EnginePath,   # default: newest UE_5.* from the launcher manifest
  [string]$Uproject,     # default: scanned Lyra*.uproject
  [switch]$Clean,        # add -Clean (force full rebuild)
  [switch]$DryRun        # resolve + print the command, do not build
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

$unrealDir = Split-Path -Parent $PSScriptRoot   # ...\unreal\scripts -> ...\unreal

$EnginePath = Find-UnrealEngine -EnginePath $EnginePath
if (-not $EnginePath) { throw 'No UE5 engine found (pass -EnginePath).' }
$build = Join-Path $EnginePath 'Engine\Build\BatchFiles\Build.bat'
if (-not (Test-Path $build)) { throw "Build.bat not found: $build" }

$Uproject = Find-LyraUproject -Uproject $Uproject
if (-not $Uproject -or -not (Test-Path $Uproject)) { throw 'Lyra .uproject not found (pass -Uproject).' }

$buildArgs = @($Target, $Platform, $Configuration, "-Project=$Uproject", '-WaitMutex')
if ($Clean) { $buildArgs += '-Clean' }

Write-Host "Engine : $EnginePath"
Write-Host "Project: $Uproject"
Write-Host "Build  : $Target $Platform $Configuration$(if ($Clean){' (clean)'})"
Write-Host "Cmd    : Build.bat $($buildArgs -join ' ')"
if ($DryRun) { Write-Host 'DryRun - not invoking Build.bat.'; exit 0 }

$logDir = Join-Path $unrealDir '.logs'
$metricDir = Join-Path $unrealDir '.metrics'
New-Item -ItemType Directory -Force -Path $logDir, $metricDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path $logDir "compile-$Target-$Configuration-$stamp.log"

Write-Host "Log    : $logFile"
Write-Host 'Starting build...'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $build @buildArgs 2>&1 | Tee-Object -FilePath $logFile
$exit = $LASTEXITCODE   # Tee-Object (a cmdlet) does not reset native exit code
$sw.Stop()
$dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)

$metric = [pscustomobject]@{
  track         = 'unreal'
  step          = 'compile'
  target        = $Target
  platform      = $Platform
  configuration = $Configuration
  clean         = [bool]$Clean
  success       = ($exit -eq 0)
  exitCode      = $exit
  durationSec   = $dur
  engine        = $EnginePath
  uproject      = $Uproject
  utc           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$metricFile = Join-Path $metricDir "compile-$Target-$Configuration-$stamp.json"
$metric | ConvertTo-Json | Set-Content -Path $metricFile -Encoding UTF8

Write-Host ''
if ($exit -eq 0) {
  Write-Host "BUILD SUCCEEDED - $Target $Configuration in ${dur}s" -ForegroundColor Green
} else {
  Write-Host "BUILD FAILED (exit $exit) after ${dur}s - see $logFile" -ForegroundColor Red
}
Write-Host "metric: $metricFile"
exit $exit
