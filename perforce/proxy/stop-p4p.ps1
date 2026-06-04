# Stop the sandbox p4p. Unlike p4d there is no `p4 admin stop` for a proxy —
# it is a stateless cache in front of the server, so killing the process is the
# clean way to stop it. The cache on disk survives and is reused on next start.

$ErrorActionPreference = "Stop"

$running = Get-Process p4p -ErrorAction SilentlyContinue
if (-not $running) {
    Write-Output "p4p is not running."
    return
}

Stop-Process -Id $running.Id -Force
Write-Output "p4p stopped (PID $($running.Id)). Cache at C:\PerforceSandbox\proxy\cache is preserved."
