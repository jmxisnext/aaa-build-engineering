<#
.SYNOPSIS
  Locate the newest installed MSVC C++ toolchain and import its environment
  into the *current* PowerShell session, so `cl`, `link`, `nmake`, and
  `msbuild` are on PATH.

.DESCRIPTION
  This machine has a working MSVC toolchain (VS 2017 Community and/or the
  VS 2019 Build Tools), but `cl.exe` is not on PATH by default -- it lives
  behind a "Developer Command Prompt" that runs vcvars64.bat. That is the
  single most common reason a from-scratch C++ build "can't find cl" on
  Windows: the compiler is installed, just not activated.

  This script finds vcvars64.bat for the newest install via `vswhere`,
  runs it in a cmd subshell, and replays the resulting environment back
  into this PowerShell session. That is the canonical "vcvars in
  PowerShell" trick -- vcvars only mutates the cmd process it runs in, so
  you have to capture `set` output and replay it.

  DOT-SOURCE it so the env survives into your interactive shell:

      . .\accel\scripts\activate-msvc.ps1

  Running it without the leading dot activates the toolchain only inside
  the script's own child process -- correct when another script
  dot-sources it (see smoke-build.ps1), useless for an interactive shell.

.NOTES
  Idempotent: if cl.exe already resolves, it reports and returns without
  re-importing. Prefers the newest install (vswhere -latest), so a
  VS 2019 Build Tools install wins over VS 2017 Community automatically.
#>

$ErrorActionPreference = "Stop"
# Native (non-cmdlet) exit codes must NOT throw -- we check $LASTEXITCODE
# ourselves. PS 7.4+ would otherwise abort on `cl` (which exits 2 when
# given no input files). Harmless no-op variable on Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# Idempotent: already active?
$existing = Get-Command cl.exe -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "MSVC already active: $($existing.Source)"
    return
}

# 1. Locate vswhere (ships with every modern VS / Build Tools installer).
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere not found at $vswhere -- is any Visual Studio / Build Tools installed?"
}

# 2. Ask for the newest install carrying the x64 C++ toolchain.
$installPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $installPath) {
    # Fall back to the newest install of any kind, then verify vcvars below.
    $installPath = & $vswhere -latest -products * -property installationPath
}
if (-not $installPath) {
    throw "vswhere found no Visual Studio install with a C++ toolchain."
}

$vcvars = Join-Path $installPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    throw "vcvars64.bat not found under $installPath -- the C++ workload may not be installed."
}

Write-Host "Activating MSVC from: $installPath"

# 3. Run vcvars in a cmd subshell (silence its banner) and replay the
#    resulting environment into this PowerShell session.
$dumped = cmd /c "`"$vcvars`" >nul 2>&1 && set"
if ($LASTEXITCODE -ne 0) {
    throw "vcvars64.bat failed (exit $LASTEXITCODE)."
}
foreach ($line in $dumped) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_()]*)=(.*)$') {
        Set-Item -Path "env:$($matches[1])" -Value $matches[2]
    }
}

# 4. Verify the import worked.
$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $cl) {
    throw "Imported vcvars but cl.exe is still not on PATH -- unexpected."
}
$verLine = (cmd /c "cl 2>&1") | Select-Object -First 1
Write-Host "MSVC active: $($cl.Source)"
Write-Host "  $verLine"
