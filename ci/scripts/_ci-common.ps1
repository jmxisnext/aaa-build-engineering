<#
.SYNOPSIS
  Shared TeamCity REST plumbing for the ci/ track scripts (dot-sourced, not run).

.DESCRIPTION
  Hosts the auth + CSRF + REST-call helpers that bootstrap-builds.ps1,
  bench-agents.ps1, setup-vcs-trigger.ps1, bootstrap-lyra.ps1, and
  notify-build-failure.ps1 previously each carried their own near-copy of.
  Dot-source it:  . (Join-Path $PSScriptRoot '_ci-common.ps1')

  Connection model: call Connect-TeamCity once, keep the result in a $tc
  variable. Invoke-TC reads that $tc by default (its -Conn param defaults to
  $tc via the caller's scope), so existing call sites stay `Invoke-TC GET ...`
  unchanged. Pass -Conn explicitly to target a second connection or to test.

  TeamCity 2026.x rejects session-authenticated *writes* (POST/PUT/DELETE) that
  carry no CSRF token (HTTP 403 "failed CSRF check"). Connect-TeamCity opens one
  web session and fetches the CSRF token once; Invoke-TC sends it as
  X-TC-CSRF-Token on every mutating request (harmless on GETs). (lesson #10)
#>

# Reconciled single variant of the two that diverged across the ci scripts: both
# took the LAST token (the volume-persisted log carries stale tokens from prior
# boots), but one did `cat | Select-String | Select-Object -Last 1` in PowerShell
# while the other did `grep ... | tail -n 1` in-container. Keep the in-container
# grep+tail — it transfers one line, not the whole log. (lessons-learned.md §6)
function Get-SuperUserToken {
    $line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}

# The env -> log-scrape fallback chain that every ci script repeated. An explicit
# -Token wins; then $env:TEAMCITY_TOKEN; then the scraped rotating superuser token.
function Resolve-TeamCityToken {
    param([string]$Token)
    if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
    if (-not $Token) { $Token = Get-SuperUserToken }
    $Token
}

# Open an authenticated TeamCity session. Returns a connection object Invoke-TC
# consumes. -DryRun yields an inert connection (no token resolve, no network) so
# bootstrap-lyra.ps1 -DryRun runs with no server. -NoCsrf skips the CSRF/session
# handshake for GET-only callers (e.g. notify-build-failure) that build their own
# headers.
function Connect-TeamCity {
    param(
        [string]$BaseUrl,
        [string]$Token,
        [switch]$DryRun,
        [switch]$NoCsrf
    )
    if ($DryRun) {
        return [pscustomobject]@{ BaseUrl = $BaseUrl; Auth = $null; Csrf = $null; Session = $null; DryRun = $true }
    }
    $Token = Resolve-TeamCityToken -Token $Token
    $auth  = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
    $csrf = $null; $session = $null
    if (-not $NoCsrf) {
        $csrf = Invoke-RestMethod -Uri "$BaseUrl/authenticationTest.html?csrf" `
            -Headers @{ Authorization = $auth } -SessionVariable session
    }
    [pscustomobject]@{ BaseUrl = $BaseUrl; Auth = $auth; Csrf = $csrf; Session = $session; DryRun = $false }
}

# One REST entry point for the whole track. Reads the ambient $tc connection by
# default. On a -DryRun connection it prints the planned call (the bootstrap-lyra
# -DryRun contract) and sends nothing.
#
# Content-Type goes on the headers hashtable, NOT via -ContentType: PowerShell's
# -ContentType sometimes overrides Accept when both are set, which TeamCity rejects
# as 406 (e.g. PUT settings/artifactRules returns text/plain and rejects
# Accept: application/json). Accept must match the endpoint's response type.
function Invoke-TC {
    param(
        [string]$Method,
        [string]$Path,
        $Body,
        [string]$ContentType = "application/json",
        [string]$Accept      = "application/json",
        $Conn = $tc
    )
    if (-not $Conn) {
        throw "Invoke-TC: no TeamCity connection in scope. Call Connect-TeamCity and keep the result in `$tc (or pass -Conn)."
    }
    if ($Conn.DryRun) {
        $shown = if ($null -ne $Body -and $Body -isnot [string]) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $Body }
        Write-Host "  [DRY] $Method $Path" -ForegroundColor DarkCyan
        if ($shown) { Write-Host "        $shown" -ForegroundColor DarkGray }
        return $null
    }
    $headers = @{ Authorization = $Conn.Auth; Accept = $Accept }
    if ($Method -in @("POST", "PUT", "DELETE")) { $headers["X-TC-CSRF-Token"] = $Conn.Csrf }
    $reqParams = @{
        Method     = $Method
        Uri        = "$($Conn.BaseUrl)$Path"
        Headers    = $headers
        WebSession = $Conn.Session
    }
    if ($null -ne $Body) {
        $reqParams.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        $headers["Content-Type"] = $ContentType
    }
    Invoke-RestMethod @reqParams
}
