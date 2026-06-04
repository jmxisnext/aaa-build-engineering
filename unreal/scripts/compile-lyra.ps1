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
  A cold LyraEditor build is 423 compile/link actions against the *installed* engine
  (engine prebuilt - only the Lyra game + plugin modules compile). Measured ~84-108s on
  a 7800X3D (8c/16t), MaxParallelActions=8. Exit 0 on success, non-zero otherwise.
  Paths with spaces: pass -Uproject quoted.
#>
[CmdletBinding()]
param(
  [string]$Target = 'LyraEditor',
  [string]$Platform = 'Win64',
  [ValidateSet('Debug','DebugGame','Development','Shipping','Test')]
  [string]$Configuration = 'Development',
  [string]$EnginePath,   # default: newest UE_5.* from the launcher manifest
  [string]$Uproject,     # default: scanned Lyra*.uproject
  [int]$MaxParallelActions = 8,  # cap concurrent compile actions to fit the commit ceiling.
                                 # 0 = uncapped (all cores). (Track 4 lesson #1: C3859/C1076.)
  [switch]$NoUBA,        # disable Unreal Build Accelerator (-NoUBA). UBA reserves large virtual
                         # memory; on this no-pagefile box (commit limit = 31GB) that tips
                         # cl.exe PCH allocs over the commit limit. UBA is Phase 2 step 2.
  [switch]$Clean,        # force a TRUE cold rebuild by clearing the project's build outputs.
                         # (UBT's own -Clean is *clean-only* - removes target binaries but leaves
                         # the obj/PCH + action-graph makefile, so the next build relinks in
                         # seconds, NOT a cold baseline. See lessons-learned.md #2.)
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
if ($MaxParallelActions -gt 0) { $buildArgs += "-MaxParallelActions=$MaxParallelActions" }
if ($NoUBA) { $buildArgs += '-NoUBA' }
# NOTE: -Clean is deliberately NOT forwarded to UBT - its -Clean is clean-only (lesson #2).
# A genuinely cold rebuild is forced below by deleting the project's build outputs.

Write-Host "Engine : $EnginePath"
Write-Host "Project: $Uproject"
Write-Host "Build  : $Target $Platform $Configuration$(if ($Clean){' (clean)'})"
Write-Host "Cmd    : Build.bat $($buildArgs -join ' ')"
if ($DryRun) { Write-Host 'DryRun - not invoking Build.bat.'; exit 0 }

if ($Clean) {
  # True cold rebuild: delete the project's build outputs so every compile action re-runs.
  # Scope is the PROJECT only (root + every project plugin) - engine dirs are never touched.
  # Just -Clean'ing the target binaries is not enough: the obj/PCH live under each plugin's
  # own Intermediate\Build too, and a surviving makefile lets UBT short-circuit (lesson #2).
  $projDir = Split-Path -Parent $Uproject
  Write-Host "Clean  : forcing COLD rebuild - clearing build outputs under $projDir"
  Remove-Item (Join-Path $projDir 'Intermediate\Build') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $projDir 'Binaries') -Recurse -Force -ErrorAction SilentlyContinue
  $pluginsDir = Join-Path $projDir 'Plugins'
  if (Test-Path $pluginsDir) {
    Get-ChildItem $pluginsDir -Recurse -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -in 'Intermediate','Binaries' } |
      ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

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
  noUBA         = [bool]$NoUBA
  maxParallel   = $MaxParallelActions
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
