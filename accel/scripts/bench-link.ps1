<#
.SYNOPSIS
  Linker-time profiling benchmark: the bench.ps1 sibling for the *link* step.
  bench.ps1 is compile-only (/c, no link); this one compiles once and then
  measures only the LINK, several ways, on a symbol-bloat fixture.

.DESCRIPTION
  Link time is driven by *symbol count*, not per-TU compile cost -- so this uses
  a different fixture from samples/bench (which is compile-cost-heavy by design).
  It stamps $TU translation units of $Symbols tiny functions each (TU*Symbols
  total symbols) plus a main.cpp that references half of them, compiles them
  once (untimed, /MP /Z7 /Gy /O2), then times these link configurations
  best-of-$Reps:

    full link (/INCREMENTAL:NO)   re-links every obj from scratch
    incremental (/INCREMENTAL)    after a 1-symbol edit -> patch in place
    /DEBUG:FULL  vs  /DEBUG:FASTLINK   PDB strategy (merge vs leave-in-objs)
    /OPT:REF                      drop unreferenced COMDATs (dead-strip)
    /OPT:REF,ICF                  + fold identical COMDATs (the dup-body groups)
    /LTCG (separate /GL objs)     whole-program: codegen MOVES to link time

  The point mirrors the rest of Track 3: each lever attacks a different cost.
  /INCREMENTAL trades binary size + LTCG/OPT compatibility for fast iteration
  relinks; /DEBUG:FASTLINK trades a portable PDB for link speed; /OPT:REF,ICF
  trades link time for a smaller exe; /LTCG trades (large) link time for runtime
  perf. There is no single "fast link" switch -- you profile (link /time+, the
  linker's analog of cl /Bt+) and pick.

  The fixture is fully deterministic; the linked exe is run and its output
  asserted, so a wrong link fails the script (like smoke-build.ps1).

  Usage:  pwsh -File .\accel\scripts\bench-link.ps1 [-TU 64] [-Symbols 250] [-Reps 3]
#>
param([int]$TU = 64, [int]$Symbols = 250, [int]$Reps = 3, [string]$Json)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "activate-msvc.ps1")

$sampleDir = (Resolve-Path (Join-Path $here "..\samples\link")).Path
$work   = Join-Path $sampleDir "_build"
$gen    = Join-Path $work "gen"
$obj    = Join-Path $work "obj"      # /Z7 /Gy objs for the normal link configs
$objgl  = Join-Path $work "objgl"    # /GL objs for the LTCG config
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $gen, $obj, $objgl | Out-Null

$cores = [int]$env:NUMBER_OF_PROCESSORS

# ---------------------------------------------------------------------------
# Fixture generation. Each function body is `return x * a + b;` with (a,b)
# derived from a small modulus so distinct indices collide -> genuine
# ICF-foldable duplicate groups. main references the EVEN global indices, so
# the odd ones are linked-but-unreferenced "bloat" that /OPT:REF can strip.
# ---------------------------------------------------------------------------
function Write-Fixture([int]$TU, [int]$Symbols) {
    Get-ChildItem $gen -Filter *.cpp -ErrorAction SilentlyContinue | Remove-Item -Force
    $decls = New-Object System.Text.StringBuilder
    $calls = New-Object System.Text.StringBuilder
    $idx = 0
    for ($t = 0; $t -lt $TU; $t++) {
        $tag = "{0:D2}" -f $t
        $sb = New-Object System.Text.StringBuilder
        for ($s = 0; $s -lt $Symbols; $s++) {
            $name = "sym_{0}_{1:D4}" -f $tag, $s
            $a = ($idx % 7) + 1
            $b = $idx % 13
            [void]$sb.AppendLine("int $name(int x){ return x * $a + $b; }")
            if (($idx % 2) -eq 0) {            # even index -> referenced by main
                [void]$decls.AppendLine("int $name(int);")
                [void]$calls.AppendLine("    s += $name(1);")
            }
            $idx++
        }
        $sb.ToString() | Set-Content -Path (Join-Path $gen "tu$tag.cpp") -Encoding ascii
    }
    @"
#include <cstdio>
$($decls.ToString())
int main(){
    long long s = 0;
$($calls.ToString())
    std::printf("LINKBENCH ok sum=%lld syms=$($TU*$Symbols)\n", s);
    return 0;
}
"@ | Set-Content -Path (Join-Path $gen "main.cpp") -Encoding ascii
    return $idx
}

# Rewrite tu00 with the first symbol's body perturbed by $rev -- a genuine
# 1-symbol edit so the incremental linker has something real to patch.
function Edit-OneSymbol([int]$rev) {
    $tag = "00"
    $f = Join-Path $gen "tu$tag.cpp"
    $lines = Get-Content -Path $f
    $lines[0] = "int sym_${tag}_0000(int x){ return x * 1 + $rev; }"
    Set-Content -Path $f -Value $lines -Encoding ascii
}

function Compile-All([string]$outObj, [string[]]$extraFlags) {
    $srcs = Get-ChildItem $gen -Filter *.cpp | ForEach-Object { $_.FullName }
    & cl.exe /nologo /c /MP /EHsc /std:c++17 @extraFlags "/Fo$outObj\" @srcs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cl failed compiling into $outObj" }
}
function Compile-One([string]$tag, [string]$outObj, [string[]]$extraFlags) {
    $src = Join-Path $gen "tu$tag.cpp"
    & cl.exe /nologo /c /MP /EHsc /std:c++17 @extraFlags "/Fo$outObj\" $src | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cl failed recompiling $tag" }
}

function Invoke-Link([string[]]$a) {
    $script:linkOut = (& link.exe /nologo @a 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Write-Host $script:linkOut; throw "link failed: $($a -join ' ')" }
}
function Exe-KB([string]$exe) { [math]::Round((Get-Item $exe).Length / 1KB) }

# Times only the link. $Pre (untimed) runs before each rep and receives the rep #.
function Measure-Link([string]$Label, [scriptblock]$Pre, [string[]]$LinkArgs, [string]$OutExe) {
    $best = [double]::MaxValue
    for ($r = 1; $r -le $Reps; $r++) {
        & $Pre $r
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Link $LinkArgs
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -lt $best) { $best = $sw.Elapsed.TotalSeconds }
    }
    [pscustomobject]@{ Config = $Label; Best = [math]::Round($best, 3); KB = (Exe-KB $OutExe) }
}

# ===========================================================================
# 1. Default-size build: generate, compile the /Z7 obj set and the /GL set once.
# ===========================================================================
Write-Host ("`nLINKER bench  TUs={0}  symbols/TU={1}  total={2}  cores={3}  reps={4}" -f `
    $TU, $Symbols, ($TU * $Symbols), $cores, $Reps)
$total = Write-Fixture $TU $Symbols
Write-Host ("Generated {0} symbols ({1} referenced by main); compiling obj sets..." -f $total, [math]::Floor($total/2))
Compile-All $obj   @('/O2', '/Gy', '/Z7')          # function-level COMDATs + embedded debug
Compile-All $objgl @('/O2', '/GL')                 # whole-program -> codegen deferred to link

$objs   = Get-ChildItem $obj   -Filter *.obj | ForEach-Object { $_.FullName }
$objsGl = Get-ChildItem $objgl -Filter *.obj | ForEach-Object { $_.FullName }
$exe    = Join-Path $work "app.exe"          # shared by the full/opt/debug configs
$exeInc = Join-Path $work "app_inc.exe"      # isolated so incremental state can't leak
$exeGl  = Join-Path $work "app_ltcg.exe"

# Correctness: do one real full link, run it, assert output (smoke-build style).
Invoke-Link (@('/INCREMENTAL:NO', '/DEBUG:FULL', '/OPT:NOREF,NOICF', "/OUT:$exe") + $objs)
$out = & $exe
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'LINKBENCH ok') { throw "linked exe misbehaved: $out" }
Write-Host "  exe runs: $out"

# ===========================================================================
# 2. Link configurations (compile fixed; only the link varies).
# ===========================================================================
$noEdit  = { param($r) }                                  # configs that don't edit
$edit    = { param($r) Edit-OneSymbol $r; Compile-One "00" $obj @('/O2','/Gy','/Z7') }
$editGl  = { param($r) Edit-OneSymbol $r; Compile-One "00" $objgl @('/O2','/GL') }

$results = @()

# Full link from scratch (the clean-build link cost; NOREF/NOICF = keep everything).
$results += Measure-Link "full /INCREMENTAL:NO" $noEdit `
    (@('/INCREMENTAL:NO','/DEBUG:FULL','/OPT:NOREF,NOICF',"/OUT:$exe") + $objs) $exe

# Incremental: warm up once (untimed) to lay down the .ilk, then time relinks
# after a genuine 1-symbol edit each rep.
Invoke-Link (@('/INCREMENTAL','/DEBUG:FULL',"/OUT:$exeInc") + $objs)
$results += Measure-Link "incremental (+1 edit)" $edit `
    (@('/INCREMENTAL','/DEBUG:FULL',"/OUT:$exeInc") + $objs) $exeInc

# Same 1-symbol edit, but full re-link -- shows what incremental saves you.
$results += Measure-Link "full re-link (+1 edit)" $edit `
    (@('/INCREMENTAL:NO','/DEBUG:FULL','/OPT:NOREF,NOICF',"/OUT:$exe") + $objs) $exe

# PDB strategy: FASTLINK leaves debug in the objs instead of merging the PDB.
$results += Measure-Link "/DEBUG:FASTLINK" $noEdit `
    (@('/INCREMENTAL:NO','/DEBUG:FASTLINK','/OPT:NOREF,NOICF',"/OUT:$exe") + $objs) $exe

# Size levers (full link). REF drops the unreferenced (odd) symbols; ICF folds
# the identical-body groups. Both cost link time, both shrink the exe.
$results += Measure-Link "/OPT:REF" $noEdit `
    (@('/INCREMENTAL:NO','/DEBUG:FULL','/OPT:REF,NOICF',"/OUT:$exe") + $objs) $exe
$results += Measure-Link "/OPT:REF,ICF" $noEdit `
    (@('/INCREMENTAL:NO','/DEBUG:FULL','/OPT:REF,ICF',"/OUT:$exe") + $objs) $exe

# LTCG: whole-program. With /GL objs the *codegen* happens here, at link.
try {
    $results += Measure-Link "/LTCG (/GL objs)" $editGl `
        (@('/INCREMENTAL:NO','/LTCG','/DEBUG:FULL','/OPT:REF,ICF',"/OUT:$exeGl") + $objsGl) $exeGl
} catch { Write-Host "  (/LTCG config skipped: $($_.Exception.Message))" }

$base = ($results | Where-Object { $_.Config -eq "full /INCREMENTAL:NO" }).Best
Write-Host ("`n{0,-24} {1,9} {2,9} {3,12}" -f "config", "link(s)", "exe(KB)", "vs full")
Write-Host ("-" * 57)
foreach ($r in $results) {
    $ratio = $base / $r.Best
    $vs = if ($ratio -ge 1) { "{0,7:N2}x faster" -f $ratio } else { "{0,7:N1}x slower" -f (1 / $ratio) }
    Write-Host ("{0,-24} {1,9:N3} {2,9} {3,14}" -f $r.Config, $r.Best, $r.KB, $vs)
}

# ===========================================================================
# 3. link /time+ -- the linker's own pass breakdown (analog of cl /Bt+).
# ===========================================================================
Write-Host "`n--- link /time+ pass breakdown (full link) ---"
Invoke-Link (@('/INCREMENTAL:NO','/DEBUG:FULL','/OPT:REF,ICF','/time+',"/OUT:$exe") + $objs)
($script:linkOut -split "`r?`n" | Where-Object { $_ -match ':\s|Pass|time|Total' } |
    Select-Object -First 25) | ForEach-Object { Write-Host $_ }

# ===========================================================================
# 4. Symbol-scaling sweep -- show link time grows with symbol count.
# ===========================================================================
Write-Host "`n--- symbol-bloat sweep (full link, best-of-2) ---"
Write-Host ("{0,12} {1,9} {2,9}" -f "symbols", "link(s)", "exe(KB)")
Write-Host ("-" * 32)
foreach ($mult in 1, 2, 4) {
    $sw_syms = $Symbols * $mult
    [void](Write-Fixture $TU $sw_syms)
    Get-ChildItem $obj -Filter *.obj | Remove-Item -Force
    Compile-All $obj @('/O2', '/Gy', '/Z7')
    $sweepObjs = Get-ChildItem $obj -Filter *.obj | ForEach-Object { $_.FullName }
    $best = [double]::MaxValue
    for ($r = 1; $r -le 2; $r++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Link (@('/INCREMENTAL:NO','/DEBUG:FULL','/OPT:NOREF,NOICF',"/OUT:$exe") + $sweepObjs)
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -lt $best) { $best = $sw.Elapsed.TotalSeconds }
    }
    Write-Host ("{0,12} {1,9:N3} {2,9}" -f ($TU * $sw_syms), [math]::Round($best,3), (Exe-KB $exe))
}

if ($Json) {
    $payload = [ordered]@{ sample='link'; cores=$cores; generatedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        results=@($results | ForEach-Object { @{ config=$_.Config; best=$_.Best } }) }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $Json -Encoding ascii
    Write-Host "wrote metrics: $Json"
}
