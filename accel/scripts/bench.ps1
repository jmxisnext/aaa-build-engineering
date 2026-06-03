<#
.SYNOPSIS
  Build-acceleration benchmark: compile N heavy translation units four ways
  and report a single before/after table. This is the reusable harness the
  Track 3 levers plug into -- one consistent comparison across /MP, unity,
  and (later) PCH / FASTBuild.

.DESCRIPTION
  Generates $TU thin .cpp files that each `#include "heavy.h"` (the expensive
  fixture in samples/bench/), then times these configurations, best-of-$Reps
  cold reps each (object dir wiped before every rep):

    serial (per-TU)      cl /c    tu00..tuNN          header parsed N x, 1 core
    /MP (per-TU)         cl /MP /c tu00..tuNN         header parsed N x, all cores
    unity (1 file)       cl /c unity_all.cpp          header parsed 1 x, 1 core
    unity xK + /MP       cl /MP /c unity_c00..cKK     header parsed K x, all cores

  The point of the spread: /MP *parallelizes* the redundant per-TU header
  parsing; unity *eliminates* it (one parse) but serializes onto one core;
  chunked-unity + /MP does both (parse K<<N times, across cores) -- the
  production sweet spot. Compile-only (/c, no link) so it's apples-to-apples.

  Usage:  pwsh -File .\accel\scripts\bench.ps1 [-TU 32] [-Reps 3] [-Chunks 0]
          (-Chunks 0 = auto: ~TU/4, capped at the core count)
#>
param([int]$TU = 32, [int]$Reps = 3, [int]$Chunks = 0)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "activate-msvc.ps1")

$fixtureDir = (Resolve-Path (Join-Path $here "..\samples\bench")).Path
$work = Join-Path $fixtureDir "_build"
$gen  = Join-Path $work "gen"
$obj  = Join-Path $work "obj"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $gen, $obj | Out-Null

$cores = [int]$env:NUMBER_OF_PROCESSORS
if ($Chunks -le 0) {
    $Chunks = [math]::Max(2, [int][math]::Round($TU / 4.0))
    $Chunks = [math]::Min($Chunks, $cores)
}

# 1. Generate N thin TUs, each pulling in the heavy header (resolved via /I).
$srcs = @()
for ($i = 0; $i -lt $TU; $i++) {
    $tag = "{0:D2}" -f $i
    $f = Join-Path $gen "tu$tag.cpp"
    "#include `"heavy.h`"`r`nlong long tu_$tag() { return heavy_work<$i>(); }" |
        Set-Content -Path $f -Encoding ascii
    $srcs += $f
}

# 2. One big unity file (#include every TU; #pragma once means heavy.h parses once).
$unityAll = Join-Path $gen "unity_all.cpp"
($srcs | ForEach-Object { "#include `"$(Split-Path -Leaf $_)`"" }) -join "`r`n" |
    Set-Content -Path $unityAll -Encoding ascii

# 3. K unity chunks (round-robin distribute TUs), to run unity *and* /MP together.
$chunkFiles = @()
for ($k = 0; $k -lt $Chunks; $k++) {
    $cf = Join-Path $gen ("unity_c{0:D2}.cpp" -f $k)
    $lines = for ($j = $k; $j -lt $TU; $j += $Chunks) { "#include `"$(Split-Path -Leaf $srcs[$j])`"" }
    ($lines -join "`r`n") | Set-Content -Path $cf -Encoding ascii
    $chunkFiles += $cf
}

function Measure-Build {
    param([string]$Label, [string[]]$CliArgs)
    $best = [double]::MaxValue
    for ($r = 1; $r -le $Reps; $r++) {
        Get-ChildItem $obj -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & cl.exe /nologo /c /EHsc /std:c++17 /O2 "/I$fixtureDir" "/Fo$obj\" @CliArgs | Out-Null
        $sw.Stop()
        if ($LASTEXITCODE -ne 0) { throw "$Label build failed (exit $LASTEXITCODE)" }
        if ($sw.Elapsed.TotalSeconds -lt $best) { $best = $sw.Elapsed.TotalSeconds }
    }
    [pscustomobject]@{ Config = $Label; Best = [math]::Round($best, 2) }
}

Write-Host ("`nTUs={0}  cores={1}  chunks={2}  reps={3} (best cold wall-time)`n" -f $TU, $cores, $Chunks, $Reps)

$results = @(
    Measure-Build "serial (per-TU)"          $srcs
    Measure-Build "/MP (per-TU)"             (@("/MP") + $srcs)
    Measure-Build "unity (1 file)"           @($unityAll)
    Measure-Build ("unity x{0} + /MP" -f $Chunks) (@("/MP") + $chunkFiles)
)

$base = ($results | Where-Object { $_.Config -eq "serial (per-TU)" }).Best
Write-Host ("{0,-22} {1,9} {2,11}" -f "config", "best(s)", "vs serial")
Write-Host ("-" * 44)
foreach ($r in $results) {
    Write-Host ("{0,-22} {1,9:N2} {2,10:N2}x" -f $r.Config, $r.Best, ($base / $r.Best))
}
