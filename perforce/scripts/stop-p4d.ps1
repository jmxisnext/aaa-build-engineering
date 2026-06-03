# Stop the sandbox P4D server cleanly via `p4 admin stop`.
# Falls back to Stop-Process if the admin command can't reach it.

$ErrorActionPreference = "Stop"

$running = Get-Process p4d -ErrorAction SilentlyContinue
if (-not $running) {
    Write-Output "p4d is not running."
    return
}

$env:P4PORT = "localhost:1666"
$env:P4USER = "james"

try {
    & p4 admin stop 2>&1 | Out-String | Write-Output
    Start-Sleep -Seconds 1
}
catch {
    Write-Warning "p4 admin stop failed — falling back to Stop-Process."
}

$still = Get-Process p4d -ErrorAction SilentlyContinue
if ($still) {
    Stop-Process -Id $still.Id -Force
    Write-Output "p4d force-killed (PID $($still.Id))."
} else {
    Write-Output "p4d stopped cleanly."
}
