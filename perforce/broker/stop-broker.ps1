# Stop the sandbox p4broker.

$ErrorActionPreference = "Stop"

$running = Get-Process p4broker -ErrorAction SilentlyContinue
if (-not $running) {
    Write-Output "p4broker is not running."
    return
}

Stop-Process -Id $running.Id -Force
Write-Output "p4broker stopped (PID was $($running.Id))."
