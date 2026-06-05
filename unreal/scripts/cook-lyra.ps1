<#
.SYNOPSIS
  Track 4, rung #2: cook Lyra content for a platform via UAT (RunUAT BuildCookRun,
  cook-only) and record the wall-clock cook time. The second rung on the
  compile -> cook -> package -> BuildGraph -> TeamCity ladder.

.DESCRIPTION
  Auto-discovers the engine + Lyra .uproject (see _unreal-common.ps1), then invokes
  the engine's RunUAT.bat BuildCookRun with -cook -skipstage (cook only; staging +
  packaging is rung #3). Times the cook, tees the full log to unreal/.logs/, and emits
  a JSON metric to unreal/.metrics/ (the dashboard feed, mirroring compile-lyra.ps1).

  The local DerivedDataCache is pointed at D: (NVMe scratch) per the drive plan - the
  first cold cook compiles every shader, which is the heavy disk+CPU cost; a fast local
  DDC is the single biggest lever and a warm DDC makes re-cooks far cheaper. Cooked
  output stays in the project's Saved\Cooked (where rung #3 staging expects it).

  Run:
      pwsh -File unreal/scripts/cook-lyra.ps1                 # cook Win64 (Development)
      pwsh -File unreal/scripts/cook-lyra.ps1 -Clean          # wipe cooked output first (cold cook)
      pwsh -File unreal/scripts/cook-lyra.ps1 -DryRun         # resolve + print the command only

.NOTES
  The first cold cook (empty DDC) compiles the full shader set and can take many minutes;
  subsequent cooks reuse the DDC and are much faster. Exit 0 on success, non-zero otherwise.
#>
[CmdletBinding()]
param(
  [string]$Platform = 'Win64',
  [ValidateSet('Debug','DebugGame','Development','Shipping','Test')]
  [string]$ClientConfig = 'Development',
  [string]$EnginePath,            # default: newest UE_5.* from the launcher manifest
  [string]$Uproject,             # default: scanned Lyra*.uproject
  [string]$DDCPath = 'D:\UE-DDC', # local DDC on NVMe scratch (drive plan); the big cold-cook lever
  [switch]$Clean,                 # wipe Saved\Cooked\<Platform> first -> a genuinely cold cook
  [switch]$DryRun                 # resolve + print the command, do not cook
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

$unrealDir = Split-Path -Parent $PSScriptRoot   # ...\unreal\scripts -> ...\unreal

$EnginePath = Find-UnrealEngine -EnginePath $EnginePath
if (-not $EnginePath) { throw 'No UE5 engine found (pass -EnginePath).' }
$uat = Join-Path $EnginePath 'Engine\Build\BatchFiles\RunUAT.bat'
if (-not (Test-Path $uat)) { throw "RunUAT.bat not found: $uat" }

$Uproject = Find-LyraUproject -Uproject $Uproject
if (-not $Uproject -or -not (Test-Path $Uproject)) { throw 'Lyra .uproject not found (pass -Uproject).' }
$projDir = Split-Path -Parent $Uproject

# Cook-only BuildCookRun: -cook (run the cook commandlet), -skipstage (no stage/pak/archive -
# that is rung #3), -nocompileeditor (reuse the editor we already built in rung #1),
# -unattended/-utf8output for clean headless logging.
$uatArgs = @(
  'BuildCookRun',
  "-project=$Uproject",
  '-noP4',
  "-platform=$Platform",
  "-clientconfig=$ClientConfig",
  '-cook',
  '-skipstage',
  '-nocompileeditor',
  '-unattended',
  '-utf8output'
)

Write-Host "Engine : $EnginePath"
Write-Host "Project: $Uproject"
Write-Host "Cook   : $Platform $ClientConfig$(if ($Clean){' (clean cooked output)'})"
Write-Host "DDC    : $DDCPath (local, NVMe)"
Write-Host "Cmd    : RunUAT.bat $($uatArgs -join ' ')"
if ($DryRun) { Write-Host 'DryRun - not invoking RunUAT.'; exit 0 }

# Point the local DDC at fast NVMe scratch (drive plan). Env var is the documented override.
New-Item -ItemType Directory -Force -Path $DDCPath | Out-Null
${env:UE-LocalDataCachePath} = $DDCPath

if ($Clean) {
  # Cold cook: remove the previously cooked output for this platform so every asset re-cooks.
  # (The DDC is intentionally NOT wiped - that is the expensive shader cache we want to reuse;
  # a clean *cook* re-runs the cook commandlet, a clean *DDC* would recompile every shader.)
  # NB: UE maps the build-platform name to a cooked-output folder name - Win64 cooks to
  # 'Saved\Cooked\Windows', not '...\Win64'. Map it or -Clean silently removes nothing.
  $cookDir = switch ($Platform) { 'Win64' { 'Windows' } default { $Platform } }
  $cooked = Join-Path $projDir "Saved\Cooked\$cookDir"
  if (Test-Path $cooked) { Write-Host "Clean  : removing $cooked"; Remove-Item $cooked -Recurse -Force -ErrorAction SilentlyContinue }
}

$logDir = Join-Path $unrealDir '.logs'
$metricDir = Join-Path $unrealDir '.metrics'
New-Item -ItemType Directory -Force -Path $logDir, $metricDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path $logDir "cook-Lyra-$Platform-$ClientConfig-$stamp.log"

Write-Host "Log    : $logFile"
Write-Host 'Starting cook...'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $uat @uatArgs 2>&1 | Tee-Object -FilePath $logFile
$exit = $LASTEXITCODE   # Tee-Object (a cmdlet) does not reset native exit code
$sw.Stop()
$dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)

$metric = [pscustomobject]@{
  track         = 'unreal'
  step          = 'cook'
  target        = 'Lyra'
  platform      = $Platform
  configuration = $ClientConfig
  clean         = [bool]$Clean
  ddcPath       = $DDCPath
  success       = ($exit -eq 0)
  exitCode      = $exit
  durationSec   = $dur
  engine        = $EnginePath
  uproject      = $Uproject
  utc           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$metricFile = Join-Path $metricDir "cook-Lyra-$Platform-$ClientConfig-$stamp.json"
$metric | ConvertTo-Json | Set-Content -Path $metricFile -Encoding UTF8

Write-Host ''
if ($exit -eq 0) {
  Write-Host "COOK SUCCEEDED - Lyra $Platform $ClientConfig in ${dur}s" -ForegroundColor Green
} else {
  Write-Host "COOK FAILED (exit $exit) after ${dur}s - see $logFile" -ForegroundColor Red
}
Write-Host "metric: $metricFile"
exit $exit
