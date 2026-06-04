<#
.SYNOPSIS
  Demonstrate the p4p Perforce Proxy cache: fill on first sync, hit on second.

.DESCRIPTION
  The proxy's job is to serve file *content* from a local cache so a second
  client (or a whole remote office) does not re-pull the same revisions across
  the WAN. This script proves that behavior with a measurable, format-independent
  signal: the proxy cache directory.

    1. (re)start p4p with an EMPTY cache.
    2. Client A force-syncs $DepotPath THROUGH the proxy  -> cache FILLS.
    3. Client B force-syncs the SAME revisions THROUGH it -> cache does NOT grow,
       i.e. every file was served from the proxy cache, zero upstream fetches.

  The assertion is: cacheFilesAfterB == cacheFilesAfterA  (delta 0 = all hits).

  -SeedMB > 0 first submits N MB of incompressible binary fixtures (a stand-in
  for the real binary art a studio caches) so the numbers reflect a WAN-realistic
  payload instead of a few KB of sandbox text; the fixtures are obliterated on
  cleanup. This is the "workload tier" knob for Track 1 — off by default so the
  out-of-the-box run is fast and side-effect-free.

  Self-contained: creates throwaway stream clients, cleans them + the fixtures up
  in a finally block. Requires p4p.exe (see start-p4p.ps1 for the one-time
  download) and a running p4d on :1666.
#>
param(
    [string]$P4        = "C:\Program Files\Perforce\p4.exe",
    [string]$ProxyPort = "localhost:1668",
    [string]$DepotPath = "//game/main/...",
    [int]   $SeedMB    = 0,
    [string]$ProxyDir  = "J:\jammers-lab\aaa-build-engineering\perforce\proxy",
    [string]$CacheDir  = "C:\PerforceSandbox\proxy\cache"
)

$ErrorActionPreference = "Stop"
$env:P4USER = "james"

if (-not (Test-Path "C:\PerforceSandbox\bin\p4p.exe")) {
    Write-Host "p4p.exe is not installed yet — the proxy binary download is the one" -ForegroundColor Yellow
    Write-Host "outstanding step. See start-p4p.ps1 / README.md for the exact command." -ForegroundColor Yellow
    return
}

$A_CLIENT = "proxy-demo-a"; $A_ROOT = "C:\PerforceSandbox\workspaces\$A_CLIENT"
$B_CLIENT = "proxy-demo-b"; $B_ROOT = "C:\PerforceSandbox\workspaces\$B_CLIENT"
$SEED_CLIENT = "proxy-seed"; $SEED_ROOT = "C:\PerforceSandbox\workspaces\$SEED_CLIENT"
$seededPaths = @()

function Cache-Stats {
    $files = Get-ChildItem $CacheDir -Recurse -File -ErrorAction SilentlyContinue
    $sum = ($files | Measure-Object Length -Sum).Sum
    return @{ Count = ($files | Measure-Object).Count; MB = [math]::Round(($sum / 1MB), 2) }
}

function New-StreamClient([string]$name, [string]$root, [string]$stream) {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    @"
Client: $name
Owner: james
Root: $root
Options: noallwrite noclobber nocompress unlocked nomodtime normdir
SubmitOptions: submitunchanged
LineEnd: local
Stream: $stream
"@ | & $P4 -p $ProxyPort client -i | Out-Null
}

try {
    Write-Host "== p4p proxy cache demo ==" -ForegroundColor Cyan

    # 0. Fresh proxy cache --------------------------------------------------
    & "$ProxyDir\stop-p4p.ps1" | Out-Null
    Remove-Item "$CacheDir\*" -Recurse -Force -ErrorAction SilentlyContinue
    & "$ProxyDir\start-p4p.ps1" | Out-Null

    # 0b. Optional: seed WAN-realistic binary fixtures ----------------------
    if ($SeedMB -gt 0) {
        Write-Host "Seeding $SeedMB MB of binary fixtures into //game/main/Content/proxy-fixture/ ..."
        New-StreamClient $SEED_CLIENT $SEED_ROOT "//game/main"
        & $P4 -p $ProxyPort -c $SEED_CLIENT sync -q | Out-Null
        $dir = "$SEED_ROOT\Content\proxy-fixture"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        for ($i = 1; $i -le 5; $i++) {
            $bytes = New-Object byte[] ([int]([math]::Ceiling($SeedMB / 5.0)) * 1MB)
            (New-Object Random).NextBytes($bytes)
            $fp = "$dir\asset_$i.bin"; [IO.File]::WriteAllBytes($fp, $bytes)
            & $P4 -p $ProxyPort -c $SEED_CLIENT add -t binary $fp | Out-Null
            $seededPaths += "//game/main/Content/proxy-fixture/asset_$i.bin"
        }
        & $P4 -p $ProxyPort -c $SEED_CLIENT submit -d "proxy demo: binary fixtures [large-ok]" | Out-Null
    }

    # 1. Two consumers, two roots ------------------------------------------
    New-StreamClient $A_CLIENT $A_ROOT "//game/main"
    New-StreamClient $B_CLIENT $B_ROOT "//game/main"

    $before = Cache-Stats

    # 2. Client A — first sync fills the cache ------------------------------
    $tA = Measure-Command { & $P4 -p $ProxyPort -c $A_CLIENT sync -f -q $DepotPath | Out-Null }
    $afterA = Cache-Stats

    # 3. Client B — same revisions, should all be cache hits ----------------
    $tB = Measure-Command { & $P4 -p $ProxyPort -c $B_CLIENT sync -f -q $DepotPath | Out-Null }
    $afterB = Cache-Stats

    # 4. Report -------------------------------------------------------------
    $delta = $afterB.Count - $afterA.Count
    Write-Host ""
    Write-Host ("  cache before        : {0} files / {1} MB" -f $before.Count, $before.MB)
    Write-Host ("  after client A sync : {0} files / {1} MB  (FILLED in {2:N1}s)" -f $afterA.Count, $afterA.MB, $tA.TotalSeconds) -ForegroundColor Green
    Write-Host ("  after client B sync : {0} files / {1} MB  (grew by {2} -> {3} in {4:N1}s)" -f `
        $afterB.Count, $afterB.MB, $delta, $(if ($delta -eq 0) {"ALL CACHE HITS"} else {"some misses"}), $tB.TotalSeconds) `
        -ForegroundColor $(if ($delta -eq 0) {"Green"} else {"Red"})
    Write-Host ""
    if ($delta -eq 0 -and $afterA.Count -gt 0) {
        Write-Host "RESULT: PASS — client B's sync was served entirely from the proxy cache (0 upstream fetches)." -ForegroundColor Green
    } else {
        Write-Host "RESULT: check the numbers above and p4p.log." -ForegroundColor Yellow
    }
    Write-Host "p4p.log tail:" -ForegroundColor DarkGray
    Get-Content "C:\PerforceSandbox\proxy\p4p.log" -Tail 6 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
finally {
    foreach ($c in @($A_CLIENT, $B_CLIENT, $SEED_CLIENT)) {
        & $P4 -p $ProxyPort -c $c revert //... 2>&1 | Out-Null
        & $P4 -p $ProxyPort client -d $c 2>&1 | Out-Null
    }
    foreach ($p in $seededPaths) { & $P4 -p $ProxyPort obliterate -y $p 2>&1 | Out-Null }
    Remove-Item $A_ROOT, $B_ROOT, $SEED_ROOT -Recurse -Force -ErrorAction SilentlyContinue
}
