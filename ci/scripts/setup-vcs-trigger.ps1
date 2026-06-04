<#
.SYNOPSIS
  Make the stack instant-CI-ready (idempotent): deploy hook + durable token +
  VCS trigger on Package + p4d change-commit trigger. Re-run after
  `docker compose down -v`.
.EXAMPLE
  ./setup-vcs-trigger.ps1
#>
param(
    [string]$Token,
    [string]$BaseUrl      = "http://localhost:8111",
    [string]$ProjectId    = "AAASandbox",
    [string]$PackageId    = "AAASandbox_Package",
    [string]$HookUser     = "ci-hook",
    [string]$TokenName    = "p4-commit-hook",
    [string]$P4Port       = "localhost:1666",
    [string]$P4User       = "james",
    [string]$TriggerHome  = "C:\PerforceSandbox\triggers",
    [string]$RepoTriggers = "J:\jammers-lab\aaa-build-engineering\perforce\triggers",
    [string]$NotifyScript = "C:\PerforceSandbox\triggers\notify-teamcity.ps1"   # the DEPLOYED path
)
$ErrorActionPreference = "Stop"

# ---------- auth (superuser scrape — same pattern as bootstrap-builds.ps1) ----------
function Get-SuperUserToken {
    $line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}
if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))

function Invoke-TC {
    param([string]$Method, [string]$Path, $Body,
          [string]$ContentType = "application/json", [string]$Accept = "application/json")
    $h = @{ Authorization = $auth; Accept = $Accept }
    $p = @{ Method = $Method; Uri = "$BaseUrl$Path"; Headers = $h }
    if ($null -ne $Body) {
        $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $h["Content-Type"] = $ContentType
    }
    Invoke-RestMethod @p
}

# ---------- 0. deploy trigger scripts to the path p4d reads from ----------
# Follows perforce/triggers/deploy.ps1 so the live trigger references
# C:\PerforceSandbox\triggers\ — the git-repo path stays non-load-bearing.
function Invoke-Deploy {
    & (Join-Path $RepoTriggers "deploy.ps1")
}

# ---------- 1. durable token for a least-privilege ci-hook user ----------
function Ensure-HookUser {
    try {
        Invoke-TC GET "/app/rest/users/username:$HookUser" | Out-Null
        Write-Host "[skip]   user $HookUser exists" -ForegroundColor DarkGray
    } catch {
        Write-Host "[create] user $HookUser" -ForegroundColor Green
        Invoke-TC POST "/app/rest/users" -Body @{ username = $HookUser; name = "CI Commit Hook" } | Out-Null
    }
    # Project Developer includes the "Run build" permission the hook needs.
    # This PUT takes no body — the role + scope are in the path.
    Invoke-TC PUT "/app/rest/users/username:$HookUser/roles/PROJECT_DEVELOPER/p:$ProjectId" | Out-Null
    Write-Host "[role]   PROJECT_DEVELOPER @ p:$ProjectId" -ForegroundColor Green
}
function New-HookToken {
    # TeamCity 2023+ restricts token minting to the owning user (self-service only),
    # so POST .../tokens as the superuser returns 403. Workaround: set a random
    # bootstrap password on ci-hook via the superuser, authenticate AS ci-hook to mint
    # its own durable bearer token, then clear the password in a finally so ci-hook has
    # no password-based login path. The bootstrap password is random and lives only in
    # memory for this function's duration.
    $bootPw   = [Convert]::ToBase64String((1..24 | ForEach-Object { [byte](Get-Random -Max 256) }))
    $suAuth   = $auth   # superuser auth from outer scope
    $hookAuth = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${HookUser}:${bootPw}"))

    # Set bootstrap password via superuser (text/plain body)
    Invoke-RestMethod -Method PUT -Uri "$BaseUrl/app/rest/users/username:$HookUser/password" `
        -Headers @{ Authorization = $suAuth; Accept = "text/plain"; "Content-Type" = "text/plain" } `
        -Body $bootPw | Out-Null

    try {
        # Delete stale token if present (auth as ci-hook)
        try {
            Invoke-RestMethod -Method DELETE `
                -Uri "$BaseUrl/app/rest/users/username:$HookUser/tokens/$TokenName" `
                -Headers @{ Authorization = $hookAuth; Accept = "application/json" } | Out-Null
        } catch { }

        # Mint fresh token (auth as ci-hook — owner can always create their own tokens)
        $t = Invoke-RestMethod -Method POST `
            -Uri "$BaseUrl/app/rest/users/username:$HookUser/tokens/$TokenName" `
            -Headers @{ Authorization = $hookAuth; Accept = "application/json" }
        if (-not $t.value) { throw "token mint returned no value" }

        if (-not (Test-Path $TriggerHome)) { New-Item -ItemType Directory -Path $TriggerHome -Force | Out-Null }
        Set-Content -Path (Join-Path $TriggerHome "teamcity-hook.token") -Value $t.value -NoNewline
        Write-Host "[token]  minted -> $TriggerHome\teamcity-hook.token" -ForegroundColor Green
    } finally {
        # Clear the bootstrap password — ci-hook authenticates via bearer token only
        Invoke-RestMethod -Method DELETE -Uri "$BaseUrl/app/rest/users/username:$HookUser/password" `
            -Headers @{ Authorization = $suAuth; Accept = "text/plain" } `
            -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------- 2. VCS trigger on Package ----------
function Ensure-VcsTrigger {
    $existing = Invoke-TC GET "/app/rest/buildTypes/id:$PackageId/triggers"
    if ($existing.trigger | Where-Object { $_.type -eq 'vcsTrigger' }) {
        Write-Host "[skip]   vcsTrigger already on $PackageId" -ForegroundColor DarkGray
        return
    }
    $body = @{ type = "vcsTrigger"; properties = @{ property = @(
        @{ name = "quietPeriodMode"; value = "DO_NOT_USE" }
    )}}
    Invoke-TC POST "/app/rest/buildTypes/id:$PackageId/triggers" -Body $body | Out-Null
    Write-Host "[create] vcsTrigger on $PackageId" -ForegroundColor Green
}

# ---------- 3. p4d change-commit trigger ----------
function Ensure-P4Trigger {
    # TrimEnd: `triggers -o` ends with a newline; trimming it prevents a blank line
    # creeping between the `Triggers:` header and our appended entry on write-back.
    $current = ((& p4 -p $P4Port -u $P4User triggers -o) -join "`n").TrimEnd()
    if ($current -match 'check-for-changes-teamcity') {
        Write-Host "[skip]   p4d change-commit trigger present" -ForegroundColor DarkGray
        return
    }
    $line = "`tcheck-for-changes-teamcity change-commit //game/main/... `"pwsh -NoProfile -File $NotifyScript -Change %change%`""
    if ($current -notmatch '(?m)^Triggers:') { $current += "`nTriggers:" }
    $spec = $current + "`n" + $line + "`n"
    $spec | & p4 -p $P4Port -u $P4User triggers -i | Out-Null
    Write-Host "[create] p4d change-commit trigger" -ForegroundColor Green
}

Write-Host "VCS-trigger setup at $BaseUrl" -ForegroundColor Cyan
Invoke-Deploy
Ensure-HookUser
New-HookToken
Ensure-VcsTrigger
Ensure-P4Trigger
Write-Host "Done. A submit through the broker to //game/main now fires the chain." -ForegroundColor Cyan
