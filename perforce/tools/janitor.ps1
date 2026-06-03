# Convenience wrapper for stale_cl_janitor.py — invokes the venv's python
# so callers don't have to know the venv path.
#
# Usage:
#   .\janitor.ps1                        # dry-run, days=7
#   .\janitor.ps1 --days 0               # dry-run, all pending
#   .\janitor.ps1 --days 0 --apply       # actually shelve+revert
#   .\janitor.ps1 --user-filter someone  # narrow to one user

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvPython = Join-Path $Here ".venv\Scripts\python.exe"
$Script = Join-Path $Here "stale_cl_janitor.py"

if (-not (Test-Path $VenvPython)) {
    throw "venv python not found at $VenvPython — see tools/README.md for setup steps."
}

& $VenvPython $Script @args
