<#
.SYNOPSIS
  Measure the build-acceleration win from MSVC /MP (parallel compilation):
  build N heavy translation units serially vs in parallel, best-of-N reps.

.DESCRIPTION
  Generates $TU thin .cpp files that each #include the expensive
  samples/mp-demo/heavy.h, then compiles the whole set two ways:

    serial   : cl /c file1..fileN            (one cl process, TUs sequential)
    parallel : cl /MP /c file1..fileN        (one cl process, TUs across cores)

  Same files, same flags except /MP. Object files are wiped before every rep
  so each timing is a cold compile; the best (fastest) wall-time of $Reps
  wins, which is the honest way to compare -- it discards reps perturbed by
  background noise rather than averaging the noise in.

  Usage:  pwsh -File .\accel\scripts\demo-mp.ps1 [-TU 16] [-Reps 3]
#>
param([int]$TU = 16, [int]$Reps = 3)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "activate-msvc.ps1")

$sampleDir = (Resolve-Path (Join-Path $here "..\samples\mp-demo")).Path
$work = Join-Path $sampleDir "_build"
$gen  = Join-Path $work "gen"
$obj  = Join-Path $work "obj"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $gen, $obj | Out-Null

# 1. Generate N thin TUs, each pulling in the heavy header.
$srcs = @()
for ($i = 0; $i -lt $TU; $i++) {
    $tag = "{0:D2}" -f $i
    $f = Join-Path $gen "tu$tag.cpp"
    @"
#include "../../heavy.h"
long long tu_$tag() { return heavy_work<$i>(); }
"@ | Set-Content -Path $f -Encoding ascii
    $srcs += $f
}

$cores = [int]$env:NUMBER_OF_PROCESSORS
Write-Host ("`nTUs: {0}   logical cores: {1}   reps: {2} (best wall-time wins)`n" -f $TU, $cores, $Reps)

function Invoke-Build([string]$label, [string[]]$extraFlags) {
    $best = [double]::MaxValue
    for ($r = 1; $r -le $Reps; $r++) {
        Get-ChildItem $obj -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & cl.exe /nologo /c /EHsc /std:c++17 /O2 @extraFlags "/Fo$obj\" @srcs | Out-Null
        $sw.Stop()
        if ($LASTEXITCODE -ne 0) { throw "$label build failed (exit $LASTEXITCODE)" }
        $sec = $sw.Elapsed.TotalSeconds
        Write-Host ("  {0,-18} rep {1}: {2,6:N2}s" -f $label, $r, $sec)
        if ($sec -lt $best) { $best = $sec }
    }
    return $best
}

$serial   = Invoke-Build "serial (no /MP)" @()
$parallel = Invoke-Build "parallel (/MP)"  @("/MP")
$speedup  = $serial / $parallel

Write-Host ("`n  serial   best: {0,6:N2}s" -f $serial)
Write-Host ("  parallel best: {0,6:N2}s" -f $parallel)
Write-Host ("  speedup:       {0,5:N2}x  on {1} logical cores" -f $speedup, $cores)
