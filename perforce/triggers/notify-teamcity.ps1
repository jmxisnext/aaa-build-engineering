<#
.SYNOPSIS
  Perforce change-commit hook: ask TeamCity to check //game/main *now*.

.DESCRIPTION
  Registered in p4d as a change-commit trigger on //game/main/... (see
  ci/scripts/setup-vcs-trigger.ps1). Runs on the p4d host on every commit.
  After a 10s settle it POSTs TeamCity's commitHookNotification endpoint so
  the VCS trigger on Package fires near-instantly instead of waiting for the
  next scheduled poll.

  Auth: a DURABLE TeamCity access token (Bearer), minted by
  setup-vcs-trigger.ps1 and stored OUTSIDE the repo. The superuser token
  rotates every server restart (lessons-learned #6) and is unusable here.

  Fail-safe: ALWAYS exits 0. change-commit fires after the commit is durable,
  so a hook failure can never block a submit — worst case "instant" degrades
  to "next scheduled VCS poll".
#>
param(
    [string]$Change,
    [string]$BaseUrl   = "http://localhost:8111",
    [string]$VcsRootId = "AAASandbox_GameMainStream",
    [string]$TokenFile = "C:\PerforceSandbox\triggers\teamcity-hook.token",
    [string]$LogFile   = "C:\PerforceSandbox\triggers\hook.log"
)

$ErrorActionPreference = "Continue"   # never let an error escape and wedge p4d

function Write-HookLog([string]$Msg) {
    $line = "{0}  cl={1}  {2}" -f (Get-Date).ToString("s"), $Change, $Msg
    try { Add-Content -Path $LogFile -Value $line } catch { }
}

try {
    # Guard the inputs up front. p4d passes %change% positionally; an empty
    # $Change (e.g. a future param added ahead of it) or $VcsRootId would
    # otherwise build a bad URL and fail silently in the catch below.
    if (-not $Change)    { Write-HookLog "NO CHANGE ARG"; exit 0 }
    if (-not $VcsRootId) { Write-HookLog "NO VCSROOTID";  exit 0 }
    Start-Sleep -Seconds 10                          # let p4d finish processing the change
    if (-not (Test-Path $TokenFile)) { Write-HookLog "NO TOKEN FILE at $TokenFile"; exit 0 }
    $token = (Get-Content -Raw $TokenFile).Trim()
    $uri = "$BaseUrl/app/rest/vcs-root-instances/commitHookNotification?locator=vcsRoot:(id:$VcsRootId)"
    # Invoke-WebRequest (not Invoke-RestMethod) so we can log the StatusCode.
    $resp = Invoke-WebRequest -Method POST -Uri $uri `
        -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -TimeoutSec 30
    Write-HookLog "POST commitHook -> HTTP $($resp.StatusCode)"
} catch {
    Write-HookLog "ERROR: $($_.Exception.Message)"
}
exit 0
