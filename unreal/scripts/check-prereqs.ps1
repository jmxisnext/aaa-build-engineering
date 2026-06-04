<#
.SYNOPSIS
  Track 4 prerequisite gate-check. Verifies the three heavy prereqs for building
  Lyra via UnrealBuildTool: Visual Studio 2022 (C++ x64 toolset), an installed
  Unreal Engine 5.x, and the Lyra project. Prints a PASS/FAIL table and exits
  non-zero if anything is missing, so the (future) compile/BuildGraph scripts can
  gate on it.

.DESCRIPTION
  Auto-discovers the engine + Lyra installs from the Epic launcher manifest
  (LauncherInstalled.dat) when present, and finds VS via vswhere. Paths can be
  overridden for source builds / non-launcher installs.

  Run it anytime to see what is still red:
      pwsh -File unreal/scripts/check-prereqs.ps1

.NOTES
  Idempotent, read-only. Exit 0 = all green; exit 1 = something missing.
#>
[CmdletBinding()]
param(
  [string]$EnginePath,    # override: root dir containing Engine\Build\BatchFiles\RunUAT.bat
  [string]$LyraUproject   # override: full path to LyraStarterGame.uproject
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
  $results.Add([pscustomobject]@{
    Check  = $name
    Status = $(if ($ok) { 'PASS' } else { 'FAIL' })
    Detail = $detail
  })
}

# --- 1. Visual Studio 2022 with the C++ x64 toolset (UE 5.4+ requires VS2022) ---
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  $vs = & $vswhere -version '[17.0,18.0)' -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -latest -format json | ConvertFrom-Json
  if ($vs) {
    Add-Check 'Visual Studio 2022 (C++ x64 toolset)' $true `
      "$($vs.displayName) $($vs.installationVersion)"
  } else {
    $any = & $vswhere -version '[17.0,18.0)' -products '*' -latest -format json | ConvertFrom-Json
    if ($any) {
      Add-Check 'Visual Studio 2022 (C++ x64 toolset)' $false `
        "VS2022 present ($($any.installationVersion)) but MISSING 'Desktop development with C++' (VC.Tools.x86.x64)"
    } else {
      Add-Check 'Visual Studio 2022 (C++ x64 toolset)' $false `
        'No VS2022 found (only 2017/2019 present - too old for UE 5.4+)'
    }
  }
} else {
  Add-Check 'Visual Studio 2022 (C++ x64 toolset)' $false 'vswhere.exe not found'
}

# --- launcher manifest: canonical list of launcher-installed engines + projects ---
$manifest = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
$launcherItems = @()
if (Test-Path $manifest) {
  try { $launcherItems = (Get-Content $manifest -Raw | ConvertFrom-Json).InstallationList } catch { }
}

# --- 2. Unreal Engine 5.x ---
$engineRoot = $EnginePath
if (-not $engineRoot) {
  $eng = $launcherItems | Where-Object { $_.AppName -like 'UE_5.*' } |
         Sort-Object AppName -Descending | Select-Object -First 1
  if ($eng) { $engineRoot = $eng.InstallLocation }
}
$runUat = if ($engineRoot) { Join-Path $engineRoot 'Engine\Build\BatchFiles\RunUAT.bat' } else { $null }
if ($runUat -and (Test-Path $runUat)) {
  $ver = '?'
  $bv = Join-Path $engineRoot 'Engine\Build\Build.version'
  if (Test-Path $bv) {
    try {
      $v = Get-Content $bv -Raw | ConvertFrom-Json
      $ver = "$($v.MajorVersion).$($v.MinorVersion).$($v.PatchVersion)"
    } catch { }
  }
  Add-Check 'Unreal Engine 5.x' $true "UE $ver @ $engineRoot"
} else {
  Add-Check 'Unreal Engine 5.x' $false `
    'No UE5 install found (Epic Games Launcher -> Unreal Engine; or pass -EnginePath)'
}

# --- 3. Lyra project ---
$lyra = $LyraUproject
if (-not $lyra) {
  $cand = $launcherItems |
          Where-Object { $_.AppName -like '*Lyra*' -or $_.InstallLocation -like '*Lyra*' } |
          Select-Object -First 1
  if ($cand) {
    $u = Get-ChildItem -Path $cand.InstallLocation -Filter '*.uproject' -Recurse -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($u) { $lyra = $u.FullName }
  }
}
if ($lyra -and (Test-Path $lyra)) {
  Add-Check 'Lyra project' $true $lyra
} else {
  Add-Check 'Lyra project' $false `
    'LyraStarterGame.uproject not found (Launcher Samples -> Lyra -> Create Project; or pass -LyraUproject)'
}

# --- report ---
Write-Host ''
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -eq 0) {
  Write-Host 'ALL PREREQS GREEN - ready to compile Lyra via UBT.' -ForegroundColor Green
  exit 0
} else {
  Write-Host "$($failed.Count) prereq(s) still RED - see Detail above." -ForegroundColor Yellow
  exit 1
}
