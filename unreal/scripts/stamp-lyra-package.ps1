<#
.SYNOPSIS
  Track 4, rung #5 (capability half): version-stamp a packaged Lyra build with its
  Perforce / engine changelist provenance. Extends the Track-2 build-info.json pattern
  (ci/scripts/bootstrap-builds.ps1 "version stamp" step) to the Unreal package, so a
  shipped Lyra build self-reports which changelist produced it -- the thing QA needs to
  say "repro'd on CL N" and release needs to map a binary back to source.

.DESCRIPTION
  Writes build-info.json INTO the staged build root ($ArchiveDir\$PlatformDir) so the
  provenance travels inside the artifact, plus a CL-named sidecar next to the archive
  (Lyra-<Platform>-<Config>-CL<N>.buildinfo.json) so the filename self-reports the CL --
  the cheap equivalent of the Track-2 tarball name hoops-brawl-cl<N>.tar.gz (the 1.72 GB
  Lyra build is not re-archived just to rename it).

  Honest provenance (verified ground truth, not fabricated):
    * engine_changelist  - always real, read from <Engine>\Engine\Build\Build.version
                           (Changelist). This is the engine build that produced the binaries.
    * p4_changelist      - the CONTENT depot changelist. Lyra is a launcher sample, NOT in
                           Perforce on this box, so standalone this is null. From TeamCity it
                           is -Changelist %build.vcs.number% (the stream VCS root's CL).
    * changelist         - the headline CL: p4_changelist when supplied, else engine_changelist.
                           changelist_source records which, so nothing is misrepresented.

  Run AFTER package-lyra.ps1 (UAT wipes the archive dir per-platform before laying down a
  fresh build, which would erase an earlier stamp). Times the run, tees a log to
  unreal\.logs\, emits a metric JSON to unreal\.metrics\ -- same convention as the other
  rung wrappers (the timing/log/metric spine is a parked refactor seed; kept inline here).

  Run:
      pwsh -File unreal/scripts/stamp-lyra-package.ps1                       # stamp on-disk pkg w/ engine CL
      pwsh -File unreal/scripts/stamp-lyra-package.ps1 -Changelist 44521     # stamp w/ a content P4 CL
      pwsh -File unreal/scripts/stamp-lyra-package.ps1 -DryRun               # resolve + print, write nothing
  From TeamCity (rung #5 wiring):
      ... -Changelist %build.vcs.number% -BuildNumber %build.number% -BuildId %teamcity.build.id% -Source teamcity

.NOTES
  Exit 0 on success, non-zero if the package or engine version is missing. Fast (<1 s) --
  it only reads version metadata and writes two small JSON files.
#>
[CmdletBinding()]
param(
  [string]$ArchiveDir   = 'D:\LyraPackaged',
  [string]$PlatformDir  = 'Windows',          # staged subdir (UE maps build Win64 -> Windows, lesson #4)
  [string]$Platform     = 'Win64',
  [string]$Configuration= 'Development',
  [string]$Changelist,                         # CONTENT depot CL; TeamCity: %build.vcs.number%
  [string]$BuildNumber,                        # TeamCity: %build.number%
  [string]$BuildId,                            # TeamCity: %teamcity.build.id%
  [ValidateSet('standalone','teamcity')]
  [string]$Source       = 'standalone',
  [string]$EnginePath,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_unreal-common.ps1')

$unrealDir = Split-Path -Parent $PSScriptRoot

# --- the package must already exist (stamp is a post-package step) ---
$buildRoot = Join-Path $ArchiveDir $PlatformDir
if (-not (Test-Path $buildRoot)) {
  throw "Packaged build not found: $buildRoot (run package-lyra.ps1 first)."
}

# --- engine changelist: authoritative, from Build.version ---
$EnginePath = Find-UnrealEngine -EnginePath $EnginePath
if (-not $EnginePath) { throw 'No UE5 engine found (pass -EnginePath).' }
$bvPath = Join-Path $EnginePath 'Engine\Build\Build.version'
if (-not (Test-Path $bvPath)) { throw "Build.version not found: $bvPath" }
$bv = Get-Content $bvPath -Raw | ConvertFrom-Json
$engineCL     = "$($bv.Changelist)"
$engineVer    = "$($bv.MajorVersion).$($bv.MinorVersion).$($bv.PatchVersion)"
$engineBranch = "$($bv.BranchName)"

# --- headline CL: content P4 CL when supplied, else fall back to the engine CL ---
$p4CL = if ($Changelist) { $Changelist } else { $null }
if ($p4CL) { $headlineCL = $p4CL; $clSource = 'p4' }
else       { $headlineCL = $engineCL; $clSource = 'engine-build-version' }

$buildInfo = [ordered]@{
  project               = 'Lyra'
  changelist            = $headlineCL
  changelist_source     = $clSource
  p4_changelist         = $p4CL
  engine_changelist     = $engineCL
  engine_version        = $engineVer
  engine_branch         = $engineBranch
  platform              = $Platform
  configuration         = $Configuration
  teamcity_build_number = if ($BuildNumber) { $BuildNumber } else { $null }
  teamcity_build_id     = if ($BuildId) { $BuildId } else { $null }
  built_at_utc          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  source                = $Source
  archive               = $buildRoot
}
$json = $buildInfo | ConvertTo-Json

$infoInPackage = Join-Path $buildRoot 'build-info.json'
$sidecarName   = "Lyra-$Platform-$Configuration-CL$headlineCL.buildinfo.json"
$sidecar       = Join-Path $ArchiveDir $sidecarName

Write-Host "Package : $buildRoot"
Write-Host "Engine  : $EnginePath  (CL $engineCL, $engineVer $engineBranch)"
Write-Host "Stamp CL: $headlineCL  (source: $clSource)"
Write-Host "In pkg  : $infoInPackage"
Write-Host "Sidecar : $sidecar"
if ($DryRun) { Write-Host 'DryRun - writing nothing.'; Write-Host '----- build-info.json (preview) -----'; Write-Host $json; exit 0 }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$json | Set-Content -Path $infoInPackage -Encoding UTF8
# Clean prior CL-named sidecars for this platform+config first, so a glob artifact
# rule (Lyra-*CL*.buildinfo.json) can't sweep up a stale one and double-publish.
# Same stale-glob trap as the Track-2 tarball step (ci lesson #12).
Get-ChildItem $ArchiveDir -Filter "Lyra-$Platform-$Configuration-CL*.buildinfo.json" -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -ne $sidecar } | Remove-Item -Force -ErrorAction SilentlyContinue
$json | Set-Content -Path $sidecar -Encoding UTF8
$sw.Stop()
$dur = [math]::Round($sw.Elapsed.TotalSeconds, 2)

Write-Host ''
Write-Host '---- build-info.json (CL provenance stamp) ----'
Get-Content $infoInPackage -Raw | Write-Host

# --- metric (same shape/convention as the other rung wrappers) ---
$logDir = Join-Path $unrealDir '.logs'
$metricDir = Join-Path $unrealDir '.metrics'
New-Item -ItemType Directory -Force -Path $logDir, $metricDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$metric = [pscustomobject]@{
  track            = 'unreal'
  step             = 'stamp'
  changelist       = $headlineCL
  changelistSource = $clSource
  p4Changelist     = $p4CL
  engineChangelist = $engineCL
  platform         = $Platform
  configuration    = $Configuration
  source           = $Source
  buildInfoPath    = $infoInPackage
  sidecarPath      = $sidecar
  success          = $true
  durationSec      = $dur
  utc              = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$metricFile = Join-Path $metricDir "stamp-Lyra-$Platform-$Configuration-$stamp.json"
$metric | ConvertTo-Json | Set-Content -Path $metricFile -Encoding UTF8

Write-Host ''
Write-Host "STAMP OK - Lyra $Platform $Configuration @ CL $headlineCL ($clSource) in ${dur}s" -ForegroundColor Green
Write-Host "metric: $metricFile"
exit 0
