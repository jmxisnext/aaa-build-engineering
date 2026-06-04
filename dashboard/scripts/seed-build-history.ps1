<#
.SYNOPSIS
  Drive a real CI build history for the dashboard demo: bring TeamCity up, ensure the
  AAASandbox chain exists, and trigger builds across changelists so the CI panel has a
  real trend to show. Re-uses ci/scripts wholesale.
.DESCRIPTION
  demo-vcs-trigger.ps1 is a policy-gated submit proof (1 allowlisted submit -> a green
  Package build through the change-commit hook; 1 denied submit -> rejected). It takes
  no build-count param, so -Builds is the *target* history size: the wrapper runs the
  trigger -Builds times, each producing one fresh changelist + chain run, accumulating a
  multi-CL history. (All runs are green; injecting red builds is a Task-9 follow-up --
  see the note in the dashboard plan.)
.EXAMPLE
  pwsh -File .\dashboard\scripts\seed-build-history.ps1 -DryRun
  pwsh -File .\dashboard\scripts\seed-build-history.ps1 -Builds 12
#>
param([int]$Builds = 12, [switch]$DryRun)
$ErrorActionPreference = "Stop"
$ci = (Resolve-Path (Join-Path $PSScriptRoot "..\..\ci")).Path

$plan = @(
    "docker compose -f $ci\docker-compose.yml up -d        # TeamCity server + 2 agents"
    "pwsh -File $ci\scripts\bootstrap-builds.ps1            # ensure AAASandbox chain exists (idempotent)"
    "pwsh -File $ci\scripts\demo-vcs-trigger.ps1  x$Builds  # policy-gated submit -> 1 green Package build per run"
)
Write-Host "seed-build-history plan ($Builds builds target):`n"
$plan | ForEach-Object { Write-Host "  $_" }
if ($DryRun) { Write-Host "`n-DryRun: nothing executed."; return }

Write-Host "`nBringing infra up + driving builds (this takes several minutes)..."
& docker compose -f "$ci\docker-compose.yml" up -d
pwsh -File "$ci\scripts\bootstrap-builds.ps1"
for ($i = 1; $i -le $Builds; $i++) {
    Write-Host "`n-- build $i/$Builds --"
    pwsh -File "$ci\scripts\demo-vcs-trigger.ps1"
}
Write-Host "`nDone. Now run collect-metrics.ps1 to capture the history."
