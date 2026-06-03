# Start the sandbox p4broker backgrounded. Idempotent.

$ErrorActionPreference = "Stop"

$BinDir = "C:\PerforceSandbox\bin"
$Conf   = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "p4broker.conf"

if (-not (Test-Path "$BinDir\p4broker.exe")) {
    throw "p4broker.exe not found at $BinDir\p4broker.exe — see perforce/broker/README.md."
}

$running = Get-Process p4broker -ErrorAction SilentlyContinue
if ($running) {
    Write-Output "p4broker already running (PID $($running.Id))."
    return
}

# p4broker reads cwd to find relative paths; ensure we're in the broker dir
# so that logfile = broker.log resolves predictably.
$brokerDir = "C:\PerforceSandbox\broker"
if (-not (Test-Path $brokerDir)) {
    New-Item -ItemType Directory -Path $brokerDir -Force | Out-Null
}

Start-Process -FilePath "$BinDir\p4broker.exe" `
    -ArgumentList "-c", $Conf `
    -WorkingDirectory $brokerDir `
    -WindowStyle Hidden

Start-Sleep -Seconds 1

$p = Get-Process p4broker -ErrorAction SilentlyContinue
if ($p) {
    Write-Output "p4broker started (PID $($p.Id)) — listening on :1667, forwarding to :1666."
    Write-Output "Log: $brokerDir\broker.log"
} else {
    throw "p4broker failed to start. Check $brokerDir\broker.log."
}
