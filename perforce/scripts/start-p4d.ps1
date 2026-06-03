# Start the sandbox P4D server backgrounded.
# Idempotent — does nothing if a p4d process is already running.

$ErrorActionPreference = "Stop"

$BinDir   = "C:\PerforceSandbox\bin"
$DepotDir = "C:\PerforceSandbox\depot"
$LogFile  = "C:\PerforceSandbox\depot\p4d.log"
$Port     = "1666"

if (-not (Test-Path "$BinDir\p4d.exe")) {
    throw "p4d.exe not found at $BinDir\p4d.exe — see perforce/README.md for install steps."
}

$running = Get-Process p4d -ErrorAction SilentlyContinue
if ($running) {
    Write-Output "p4d already running (PID $($running.Id))."
    return
}

if (-not (Test-Path $DepotDir)) {
    New-Item -ItemType Directory -Path $DepotDir -Force | Out-Null
}

Start-Process -FilePath "$BinDir\p4d.exe" `
    -ArgumentList "-r",$DepotDir,"-p",$Port,"-L",$LogFile `
    -WindowStyle Hidden

Start-Sleep -Seconds 1

$p = Get-Process p4d -ErrorAction SilentlyContinue
if ($p) {
    Write-Output "p4d started (PID $($p.Id)) on port $Port, root $DepotDir."
} else {
    throw "p4d failed to start — check $LogFile."
}
