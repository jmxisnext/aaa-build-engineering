<#
.SYNOPSIS
  Build-acceleration benchmark on a REAL, recognizable C++ codebase: the bgfx
  renderer core (extern/bgfx/src). Replaces the synthetic 32-TU regex fixture
  with the actual engine -- so the before/after numbers are honest and the unity
  build is bgfx's OWN shipped amalgamation (src/amalgamated.cpp), not a synthetic
  concatenation. Workload tier injection #1 from ROADMAP_NEXT.md.

.DESCRIPTION
  Run accel/scripts/setup-bgfx.ps1 first (vendors bgfx/bx/bimg, pinned to the
  last revision that builds with the installed MSVC 19.29 -- see that script).

  Why bgfx/src and not examples/common (the roadmap's literal target): measured,
  examples/common is too light (~3.9 s serial over 24 tiny TUs, most 0.1-0.5 s,
  and its entry/ backends are config-guarded 1 KB no-ops) -- overhead-bound, so
  /MP can't show an honest win. bgfx/src is the heavy renderer (renderer_vk/gl/
  d3d11/d3d12 + bgfx.cpp, ~0.7-1.1 s each) AND ships src/amalgamated.cpp, bgfx's
  real unity build. Same vendored repo, the part with real compile cost.

  Configurations (best-of-$Reps cold reps, obj dir wiped before each rep,
  compile-only /c -- identical method to bench.ps1 so the two are comparable):

    serial (per-file)   cl /c src/*.cpp            every TU, 1 core
    /MP (per-file)      cl /MP /c src/*.cpp        every TU, all cores
    unity (amalgamated) cl /c src/amalgamated.cpp  bgfx's real 1-TU build

  Then two things bench.ps1 never measured, both on real code:

    * single-file-edit incremental -- the real edit-build loop. Per-file keeps
      TU granularity (edit one .cpp -> recompile only it); the amalgamation does
      not (edit one .cpp -> recompile the whole engine). Measured for a HEAVY
      file and a TRIVIAL file, so the unity incremental penalty is explicit.
    * /d2cgsummary -- MSVC's per-function codegen-cost profiler on the heaviest
      TU; the "where does the back-end time actually go" view (companion to the
      /Bt+ front/back split bench.ps1 used).

  Usage:
    pwsh -File .\accel\scripts\bench-bgfx.ps1            # full run, 3 reps
    pwsh -File .\accel\scripts\bench-bgfx.ps1 -Reps 1    # quick
    pwsh -File .\accel\scripts\bench-bgfx.ps1 -Probe     # just the per-TU table
#>
param([int]$Reps = 3, [switch]$Probe)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "activate-msvc.ps1")

$ext = (Resolve-Path (Join-Path $here "..\extern")).Path
$src = Join-Path $ext "bgfx\src"
if (-not (Test-Path (Join-Path $src "amalgamated.cpp"))) {
    throw "bgfx not vendored at $src -- run accel\scripts\setup-bgfx.ps1 first."
}

# --- The locked build recipe (validated against the pinned triple) -----------
# directx-headers FIRST so bgfx's bundled d3d12.h (newer feature levels) wins
# over the VS2019 Windows SDK's older one; khronos supplies vulkan-local + gl.
$inc = @(
    "/I$ext\bgfx\3rdparty\directx-headers\include\directx",
    "/I$ext\bgfx\3rdparty\khronos",
    "/I$ext\bgfx\include", "/I$ext\bgfx\3rdparty",
    "/I$ext\bx\include",   "/I$ext\bx\3rdparty",
    "/I$ext\bimg\include"
)
$def   = @("/D__STDC_LIMIT_MACROS", "/D__STDC_FORMAT_MACROS", "/D__STDC_CONSTANT_MACROS", "/DBX_CONFIG_DEBUG=0")
# bx enforces /Zc:__cplusplus + /Zc:preprocessor on MSVC; /std:c++17 matches bench.ps1.
$flags = @("/nologo", "/c", "/EHsc", "/std:c++17", "/Zc:__cplusplus", "/Zc:preprocessor", "/O2")

$work = Join-Path $src "_build"
$obj  = Join-Path $work "obj"
New-Item -ItemType Directory -Force -Path $obj | Out-Null

# Per-file set = exactly what amalgamated.cpp #includes: every src/*.cpp EXCEPT
# the amalgamation itself. Inactive-platform stubs (agc/gnm/nvn, egl/html5) are
# kept -- they're in the real build too, just guard to near-nothing.
$perFile = Get-ChildItem $src -Filter *.cpp |
    Where-Object { $_.Name -ne "amalgamated.cpp" } | Sort-Object Name
$amalg = Join-Path $src "amalgamated.cpp"
$cores = [int]$env:NUMBER_OF_PROCESSORS

function RunCl([string[]]$files, [bool]$MP = $false) {
    $a = @() + $flags + $def + $inc
    if ($MP) { $a = @("/MP") + $a }
    & cl.exe @a $files "/Fo$obj\" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cl failed (exit $LASTEXITCODE)" }
}
function ClearObj { Get-ChildItem $obj -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force }

# --- Probe: compile each TU alone, time + obj size, partition real vs no-op ---
Write-Host ("`nbgfx core src/  --  {0} per-file TUs + amalgamated.cpp   cores={1}" -f $perFile.Count, $cores)
Write-Host "(pinned bgfx/bx/bimg -- see samples/bgfx/vendored.lock.json)`n"

$probeRows = foreach ($f in $perFile) {
    ClearObj
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    try { RunCl -files @($f.FullName) } catch { $ok = $false }
    $sw.Stop()
    $o = Join-Path $obj ($f.BaseName + ".obj")
    [pscustomobject]@{
        TU    = $f.Name
        Sec   = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ObjKB = if (Test-Path $o) { [math]::Round((Get-Item $o).Length / 1KB, 0) } else { 0 }
        Note  = if (-not $ok) { "FAIL" } elseif ((Test-Path $o) -and (Get-Item $o).Length -lt 5KB) { "guarded/stub" } else { "" }
    }
}
$probeRows | Sort-Object Sec -Descending | Format-Table -AutoSize
$serialSum = ($probeRows | Measure-Object Sec -Sum).Sum
# Heaviest by OBJ SIZE (codegen volume) -- stable; single-rep wall-time is
# cache-noisy (a cold first TU can outrank a genuinely bigger one). Trivial =
# cheapest REAL-work TU (skip the guarded/stub no-ops).
$heaviest  = ($probeRows | Sort-Object ObjKB -Descending | Select-Object -First 1).TU
$trivial   = ($probeRows | Where-Object { $_.Note -eq '' } | Sort-Object Sec | Select-Object -First 1).TU
Write-Host ("per-file serial sum: {0:N2} s    heaviest: {1}    trivial: {2}" -f $serialSum, $heaviest, $trivial)
if ($Probe) { return }

# --- A. Clean compile: serial vs /MP vs unity (best-of-Reps cold) -------------
function Measure-Config([string]$Label, [scriptblock]$Build) {
    $best = [double]::MaxValue
    for ($r = 1; $r -le $Reps; $r++) {
        ClearObj
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $Build
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -lt $best) { $best = $sw.Elapsed.TotalSeconds }
    }
    [pscustomobject]@{ Config = $Label; Best = [math]::Round($best, 2) }
}

$files = $perFile.FullName
$results = @()
$results += Measure-Config "serial (per-file)"   { RunCl -files $files }
$results += Measure-Config "/MP (per-file)"      { RunCl -files $files -MP $true }
$results += Measure-Config "unity (amalgamated)" { RunCl -files @($amalg) }

$base = ($results | Where-Object { $_.Config -eq "serial (per-file)" }).Best
Write-Host ("`nA. Clean compile  ({0} TUs, best of {1} cold reps, /c)`n" -f $perFile.Count, $Reps)
Write-Host ("{0,-22} {1,9} {2,11}" -f "config", "best(s)", "vs serial")
Write-Host ("-" * 44)
foreach ($r in $results) {
    Write-Host ("{0,-22} {1,9:N2} {2,10:N2}x" -f $r.Config, $r.Best, ($base / $r.Best))
}

# --- B. Single-file-edit incremental: the real edit-build loop ----------------
# cl has no internal incremental compile -- "incremental" is which TUs a build
# system rebuilds. Editing a leaf .cpp rebuilds: per-file -> just that TU;
# amalgamation -> the whole engine. Measured for a heavy file and a trivial one.
function Time-Compile([string[]]$files) {
    $best = [double]::MaxValue
    for ($r = 1; $r -le $Reps; $r++) {
        ClearObj
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        RunCl -files $files
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -lt $best) { $best = $sw.Elapsed.TotalSeconds }
    }
    [math]::Round($best, 2)
}
$heavyFile = (Join-Path $src $heaviest)
$trivFile  = (Join-Path $src $trivial)
$tHeavy = Time-Compile @($heavyFile)
$tTriv  = Time-Compile @($trivFile)
$tUnity = ($results | Where-Object { $_.Config -eq "unity (amalgamated)" }).Best
Write-Host "`nB. Single-file-edit incremental rebuild  (recompile what changed)`n"
Write-Host ("{0,-34} {1,9}" -f "edit -> rebuild", "best(s)")
Write-Host ("-" * 45)
Write-Host ("{0,-34} {1,9:N2}" -f "per-file: edit $heaviest (heavy)", $tHeavy)
Write-Host ("{0,-34} {1,9:N2}" -f "per-file: edit $trivial (trivial)", $tTriv)
Write-Host ("{0,-34} {1,9:N2}" -f "amalgamated: edit ANY 1 file", $tUnity)
Write-Host ("`n  -> editing the trivial file: per-file rebuilds {0:N2}s, the amalgamation {1:N2}s ({2:N1}x) --" -f $tTriv, $tUnity, ($tUnity / [math]::Max($tTriv, 0.01)))
Write-Host "     that's the granularity the unity build trades away for its clean-build speed."

# --- C. Where does the heaviest TU's time go? codegen summary + front/back ----
# /d2cgsummary is the back-end (codegen) profiler the roadmap asked for; /Bt+
# adds the front-end vs back-end split (same tool the synthetic-fixture REPORT
# used) -- together they show bgfx is FRONT-END bound, which is why /d2cgsummary
# finds no hot codegen function and why the parse-once levers are what fit here.
Write-Host "`nC. Profiling the heaviest TU ($heaviest) -- where does its time go?`n"
ClearObj
$cg = (& cl.exe @flags $def $inc "/d2cgsummary" $heavyFile "/Fo$obj\" 2>&1) | Out-String
$cgElapsed = if ($cg -match 'Code Generation Summary[\s\S]*?Elapsed Time:\s*([0-9.]+)') { [double]$matches[1] } else { 0 }
$cgFuncs   = if ($cg -match 'Total Function Count:\s*(\d+)') { $matches[1] } else { "?" }
$bt = (& cl.exe @flags $def $inc "/Bt+" $heavyFile "/Fo$obj\" 2>&1) | Out-String
$fe = if ($bt -match 'c1xx\.dll\)=([0-9.]+)s') { [double]$matches[1] } else { 0 }
$be = if ($bt -match 'c2\.dll\)=([0-9.]+)s')   { [double]$matches[1] } else { 0 }
$tot = [math]::Max($fe + $be, 0.0001)
Write-Host ("  /d2cgsummary  back-end codegen elapsed {0:N2}s   anomalistic (hot) functions: {1}" -f $cgElapsed, $cgFuncs)
Write-Host ("  /Bt+          front-end (parse + template instantiation) {0:N2}s  ({1,4:P0})" -f $fe, ($fe / $tot))
Write-Host ("                back-end  (codegen)                        {0:N2}s  ({1,4:P0})" -f $be, ($be / $tot))
Write-Host ("`n  -> {0} is front-end-bound -- the cost is parsing + instantiating headers" -f $heaviest)
Write-Host "     (Vulkan/D3D/Windows decls), not codegen. That's why /d2cgsummary finds no hot"
Write-Host "     function, and why the parse-once levers (unity's amalgamation, or a"
Write-Host "     declaration-heavy PCH) are the ones that fit this workload -- not /LTCG-class"
Write-Host "     codegen tuning. Profile before picking the lever (the Track 3 thesis)."
Write-Host ""
