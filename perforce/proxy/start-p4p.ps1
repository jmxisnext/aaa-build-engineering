# Start the sandbox p4p (Perforce Proxy) backgrounded. Idempotent.
#
# Listens on :1668, forwards metadata to the upstream p4d on :1666, and caches
# file *content* under C:\PerforceSandbox\proxy\cache. A proxy is what you put
# in a remote office so engineers sync large binary assets from a nearby cache
# instead of pulling every revision across the WAN from the master server.
#
# Topology in this sandbox (three p4 processes, one box):
#   client --> p4p   :1668  (proxy   — caches file content)        this script
#   client --> p4broker :1667 (broker — enforces command policy)   ../broker/
#   client --> p4d   :1666  (server  — the source of truth)        ../scripts/

$ErrorActionPreference = "Stop"

$BinDir     = "C:\PerforceSandbox\bin"
$ProxyDir   = "C:\PerforceSandbox\proxy"
$CacheDir   = "$ProxyDir\cache"
$LogFile    = "$ProxyDir\p4p.log"
$ListenPort = "1668"
$Target     = "localhost:1666"

if (-not (Test-Path "$BinDir\p4p.exe")) {
    throw @"
p4p.exe not found at $BinDir\p4p.exe.

The Perforce Proxy binary is NOT part of the P4V bundle and must be downloaded
once, from the same vendor filehost as p4d / p4broker. Run (with your approval):

  Invoke-WebRequest ``
    -Uri  https://filehost.perforce.com/perforce/r25.2/bin.ntx64/p4p.exe ``
    -OutFile '$BinDir\p4p.exe'

Then re-run this script. See proxy/README.md for the full rationale.
"@
}

$running = Get-Process p4p -ErrorAction SilentlyContinue
if ($running) {
    Write-Output "p4p already running (PID $($running.Id))."
    return
}

if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

# -p listen port  -t upstream target  -r cache root  -L log  -v proxy logging.
Start-Process -FilePath "$BinDir\p4p.exe" `
    -ArgumentList "-p",$ListenPort,"-t",$Target,"-r",$CacheDir,"-L",$LogFile,"-v","server=1" `
    -WorkingDirectory $ProxyDir `
    -WindowStyle Hidden

Start-Sleep -Seconds 1

$p = Get-Process p4p -ErrorAction SilentlyContinue
if ($p) {
    Write-Output "p4p started (PID $($p.Id)) — listening on :$ListenPort, forwarding to $Target."
    Write-Output "Cache: $CacheDir"
    Write-Output "Log:   $LogFile"
} else {
    throw "p4p failed to start — check $LogFile."
}
