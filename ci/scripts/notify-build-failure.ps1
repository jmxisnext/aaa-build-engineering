<#
.SYNOPSIS
  Build-failure notification for the AAA Sandbox chain (file-write notifier).

.DESCRIPTION
  Queries the TeamCity REST API for FAILED builds in the AAASandbox project and,
  for each failure it hasn't already reported, writes a structured record to
  ci/data/notifications/failures.log and prints a console alert. Idempotent: a
  per-build seen-set (.seen) means re-running never double-notifies, so this is
  safe to run on a schedule, as a post-chain step, or by hand.

  One watcher covers the WHOLE chain — a failure in Compile, Smoke Test, Cook
  Data, or Package is caught the same way, without bolting an on-failure step
  onto every config. Each record carries the failing config, the build number,
  the **P4 changelist** the build came from (so QA can say "broken in CL 31"),
  the status text (e.g. which tests failed), and a direct URL.

  Why poll-and-write rather than a TeamCity email rule: it's the same REST-driven,
  outside-the-repo-state pattern as bootstrap-builds.ps1 / setup-vcs-trigger.ps1,
  it needs no SMTP/plugin, and it's fully self-testable (break a test, run the
  chain, run this — assert the record appears). The roadmap's "file-write" option.

.EXAMPLE
  pwsh -File .\scripts\notify-build-failure.ps1
  pwsh -File .\scripts\notify-build-failure.ps1 -Token <tc-token>
#>
param(
    [string]$BaseUrl   = "http://localhost:8111",
    [string]$Token,
    [string]$ProjectId = "AAASandbox",
    [int]   $Count     = 25,
    [string]$NotifyDir = (Join-Path $PSScriptRoot "..\data\notifications")
)

$ErrorActionPreference = "Stop"

# ---------- auth (same fallback chain as bootstrap-builds.ps1) ----------
function Get-SuperUserToken {
    $log = docker exec teamcity-server cat /opt/teamcity/logs/teamcity-server.log
    $line = $log | Select-String "Super user authentication token: " | Select-Object -Last 1
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}
if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }

$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
    Accept        = "application/json"
}

# ---------- query failed builds ----------
$fields  = "build(id,number,status,statusText,buildTypeId,buildType(name),webUrl,finishDate,revisions(revision(version)))"
$locator = "affectedProject:(id:$ProjectId),status:FAILURE,state:finished,count:$Count"
$uri     = "$BaseUrl/app/rest/builds?locator=$locator&fields=$fields"

$resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
$builds = @($resp.build)

# ---------- idempotency + output paths ----------
if (-not (Test-Path $NotifyDir)) { New-Item -ItemType Directory -Path $NotifyDir -Force | Out-Null }
$seenFile = Join-Path $NotifyDir ".seen"
$logFile  = Join-Path $NotifyDir "failures.log"
$seen = @{}
if (Test-Path $seenFile) { Get-Content $seenFile | Where-Object { $_ } | ForEach-Object { $seen[$_] = $true } }

$new = 0
foreach ($b in $builds) {
    if ($seen.ContainsKey([string]$b.id)) { continue }
    $cl = if ($b.revisions.revision) { @($b.revisions.revision)[0].version } else { "(none)" }
    $record = @"
========================================================================
BUILD FAILURE   detected $(Get-Date -Format s)
  config         : $($b.buildType.name)  ($($b.buildTypeId))
  build          : #$($b.number)  (id $($b.id))
  p4 changelist  : $cl
  status         : $($b.statusText)
  finished       : $($b.finishDate)
  url            : $($b.webUrl)
========================================================================
"@
    Add-Content -Path $logFile -Value $record
    Add-Content -Path $seenFile -Value ([string]$b.id)
    Write-Host "[NOTIFY] FAILURE  $($b.buildType.name) #$($b.number)  CL $cl  -- $($b.statusText)" -ForegroundColor Red
    $new++
}

if ($new -eq 0) {
    Write-Host "No new build failures. (checked $($builds.Count) failed build(s); all already notified.)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "$new new failure notification(s) written to $logFile" -ForegroundColor Yellow
}
