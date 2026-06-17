<#
.SYNOPSIS
  Build-acceleration benchmark: compile N heavy translation units several ways
  and report a single before/after table. The reusable harness the Track 3
  levers plug into -- one consistent comparison across /MP, unity, and PCH.

.DESCRIPTION
  Generates $TU thin .cpp files that each `#include "pch.h"` (-> heavy.h, the
  expensive fixture in samples/bench/), then times these configurations,
  best-of-$Reps cold reps each (object dir wiped before every rep):

    serial (per-TU)    cl /c    tu00..tuNN          header parsed N x, 1 core
    /MP (per-TU)       cl /MP /c tu00..tuNN         header parsed N x, all cores
    unity (1 file)     cl /c unity_all.cpp          header parsed 1 x, 1 core
    unity xK + /MP     cl /MP /c unity_c00..cKK     header parsed K x, all cores
    PCH clean + /MP    /Yc once + /MP /Yu tuNN      header parsed 1 x (into .pch)
    PCH warm + /MP     (/Yc prebuilt) /MP /Yu tuNN  header parse already paid

  /MP *parallelizes* the redundant header parse; unity *eliminates* it (one
  parse) but merges TUs (kills incremental granularity); PCH also eliminates it
  (parse once into a .pch) WITHOUT merging TUs -- so /Yu /MP keeps per-TU
  granularity. "warm" models the incremental case: the .pch is built once and
  reused, which is the realistic steady state. Compile-only (/c, no link).

  Usage:  pwsh -File .\accel\scripts\bench.ps1 [-TU 32] [-Reps 3] [-Chunks 0]
          (-Chunks 0 = auto: ~TU/4, capped at the core count)
#>
param([int]$TU = 32, [int]$Reps = 3, [int]$Chunks = 0, [string]$Json)

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
$pch = Join-Path $obj "heavy.pch"

# 1. N thin TUs -- first line #include "pch.h" so /Yu can substitute the .pch.
$srcs = @()
for ($i = 0; $i -lt $TU; $i++) {
    $tag = "{0:D2}" -f $i
    $f = Join-Path $gen "tu$tag.cpp"
    "#include `"pch.h`"`r`nlong long tu_$tag() { return heavy_work<$i>(); }" |
        Set-Content -Path $f -Encoding ascii
    $srcs += $f
}
# 2. pch.cpp -- the single TU compiled with /Yc to create the .pch.
$pchCpp = Join-Path $gen "pch.cpp"
"#include `"pch.h`"" | Set-Content -Path $pchCpp -Encoding ascii
# 3. One big unity file (#pragma once => heavy.h parses once).
$unityAll = Join-Path $gen "unity_all.cpp"
($srcs | ForEach-Object { "#include `"$(Split-Path -Leaf $_)`"" }) -join "`r`n" |
    Set-Content -Path $unityAll -Encoding ascii
# 4. K unity chunks (round-robin) -- unity *and* /MP together.
$chunkFiles = @()
for ($k = 0; $k -lt $Chunks; $k++) {
    $cf = Join-Path $gen ("unity_c{0:D2}.cpp" -f $k)
    $lines = for ($j = $k; $j -lt $TU; $j += $Chunks) { "#include `"$(Split-Path -Leaf $srcs[$j])`"" }
    ($lines -join "`r`n") | Set-Content -Path $cf -Encoding ascii
    $chunkFiles += $cf
}

function RunCl([string[]]$a) {
    & cl.exe /nologo /c /EHsc /std:c++17 /O2 "/I$fixtureDir" "/Fo$obj\" @a | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cl failed: $($a -join ' ')" }
}

# Wipe the obj dir before each timed rep so every config is a cold compile (the
# .pch survives — only *.obj is removed — which is what the PCH-warm case needs).
$wipeObj = { Get-ChildItem $obj -Filter *.obj -ErrorAction SilentlyContinue | Remove-Item -Force }

Write-Host ("`nTUs={0}  cores={1}  chunks={2}  reps={3} (best cold wall-time)`n" -f $TU, $cores, $Chunks, $Reps)

$results = @()
$results += Measure-BestOf "serial (per-TU)" -Reps $Reps -Pre $wipeObj -Action { RunCl $srcs }
$results += Measure-BestOf "/MP (per-TU)"    -Reps $Reps -Pre $wipeObj -Action { RunCl (@('/MP') + $srcs) }
$results += Measure-BestOf "unity (1 file)"  -Reps $Reps -Pre $wipeObj -Action { RunCl $unityAll }
$results += Measure-BestOf ("unity x{0} + /MP" -f $Chunks) -Reps $Reps -Pre $wipeObj -Action { RunCl (@('/MP') + $chunkFiles) }
# PCH clean: the .pch is (re)built inside the timed region -> honest clean build.
$results += Measure-BestOf "PCH clean + /MP" -Reps $Reps -Pre $wipeObj -Action {
    RunCl @('/Ycpch.h', "/Fp$pch", $pchCpp)
    RunCl (@('/MP', '/Yupch.h', "/Fp$pch") + $srcs)
}
# PCH warm: prebuild the .pch ONCE (untimed); reps wipe *.obj but the .pch
# survives -> models the steady-state incremental build.
RunCl @('/Ycpch.h', "/Fp$pch", $pchCpp)
$results += Measure-BestOf "PCH warm + /MP" -Reps $Reps -Pre $wipeObj -Action { RunCl (@('/MP', '/Yupch.h', "/Fp$pch") + $srcs) }

Write-SpeedupTable $results -BaselineConfig "serial (per-TU)" -VsLabel "vs serial"

Write-MetricsJson -Sample 'compile' -Results $results -Path $Json -Lead ([ordered]@{ tu = $TU })
