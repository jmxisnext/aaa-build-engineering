<#
.SYNOPSIS
  Policy-gated end-to-end proof of the VCS trigger. Exits non-zero if either
  case fails, so it doubles as a CI self-test.

.DESCRIPTION
  Case A (allowed): submit as allowlisted build-svc through the broker :1667
    -> broker PASS -> change-commit hook -> chain fires within -FireTimeoutSec, green.
  Case B (frozen-out): submit as non-allowlisted james through :1667
    -> broker REJECT -> no changelist lands, no build within -NoFireWindowSec.

  Admin setup (creating users/clients, seeding the heartbeat file) goes DIRECT
  to p4d :1666 as super james. Only the two TESTED submits go through the broker.
#>
param(
    [string]$Token,
    [string]$BaseUrl    = "http://localhost:8111",
    [string]$PackageId  = "AAASandbox_Package",
    [string]$P4d        = "localhost:1666",
    [string]$Broker     = "localhost:1667",
    [string]$Stream     = "//game/main",
    [string]$AllowUser  = "build-svc",
    [string]$DenyUser   = "james",
    [string]$WsRoot     = "C:\PerforceSandbox\ws",
    [int]$FireTimeoutSec  = 90,
    [int]$NoFireWindowSec = 30
)
$ErrorActionPreference = "Stop"

# ---------- TeamCity read auth (superuser scrape) ----------
function Get-SuperUserToken {
    $line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log."
}
if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
$H = @{ Authorization = $auth; Accept = "application/json" }

function Get-LatestPackageId {
    $loc = "buildType:$PackageId,count:1,defaultFilter:false,running:any,canceled:any"
    $f   = "build(id,number,state,status)"
    $r = Invoke-RestMethod -Headers $H -Uri ("$BaseUrl/app/rest/builds?locator={0}&fields={1}" -f `
            [uri]::EscapeDataString($loc), [uri]::EscapeDataString($f))
    if ($r.count -lt 1) { return 0 }
    [int](@($r.build)[0].id)
}
function Wait-NewBuild([int]$Baseline, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $id = Get-LatestPackageId
        if ($id -gt $Baseline) {
            do {
                Start-Sleep -Seconds 3
                $b = Invoke-RestMethod -Headers $H -Uri "$BaseUrl/app/rest/builds/id:$id"
            } while ($b.state -ne 'finished' -and (Get-Date) -lt $deadline)
            return $b
        }
        Start-Sleep -Seconds 4
    }
    return $null
}

# ---------- admin setup (direct to p4d as super james) ----------
function Ensure-Identities {
    # Ensure build-svc user exists (may already exist from earlier tasks).
    "User: $AllowUser`nEmail: $AllowUser@example.invalid`nFullName: Build Service Account`n" |
        & p4 -p $P4d -u james user -f -i | Out-Null

    foreach ($pair in @(@($AllowUser, "$AllowUser-ws"), @($DenyUser, "$DenyUser-ws"))) {
        $owner = $pair[0]; $client = $pair[1]
        $root = Join-Path $WsRoot $owner
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        # If the client already exists as a legacy non-stream client (e.g. from
        # a prior task that created build-svc-ws with a View: mapping), delete
        # it first.  A client with both View: and Stream: is invalid; creating
        # fresh avoids that conflict.  Super user can delete any client.
        $existing = & p4 -p $P4d -u james clients -e $client 2>$null
        if ($existing) {
            & p4 -p $P4d -u james client -d -f $client | Out-Null
            Write-Host "[setup] deleted stale client $client" -ForegroundColor DarkGray
        }

        "Client: $client`nOwner: $owner`nRoot: $root`nStream: $Stream`n" |
            & p4 -p $P4d -u james client -i | Out-Null
    }
    Write-Host "[setup] identities + clients ready" -ForegroundColor DarkGray
}
function Ensure-Heartbeat {
    $env:P4PORT = $P4d; $env:P4USER = "james"; $env:P4CLIENT = "$DenyUser-ws"
    if (-not (& p4 files "$Stream/ci-demo/heartbeat.txt" 2>$null)) {
        $root = Join-Path $WsRoot $DenyUser
        & p4 sync -q "$Stream/..." 2>$null | Out-Null
        $path = Join-Path $root "ci-demo\heartbeat.txt"
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content -Path $path -Value "seed"
        & p4 add "$Stream/ci-demo/heartbeat.txt" | Out-Null
        & p4 submit -d "ci-demo: seed heartbeat" | Out-Null   # direct to p4d, bypasses freeze
        Write-Host "[setup] seeded $Stream/ci-demo/heartbeat.txt" -ForegroundColor DarkGray
    }
}

# ---------- the two cases ----------
function Invoke-CaseA {
    Write-Host "`n== Case A: allowlisted submit fires the chain ==" -ForegroundColor Cyan
    $baseline = Get-LatestPackageId
    $env:P4PORT = $Broker; $env:P4USER = $AllowUser; $env:P4CLIENT = "$AllowUser-ws"
    & p4 sync -q "$Stream/ci-demo/heartbeat.txt" | Out-Null
    & p4 edit "$Stream/ci-demo/heartbeat.txt" | Out-Null
    Add-Content (Join-Path (Join-Path $WsRoot $AllowUser) "ci-demo\heartbeat.txt") ("ping {0}" -f (Get-Date).ToString("s"))
    $out = & p4 submit -d "ci-demo: case A allowed submit" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: allowlisted submit was blocked:`n$out" -ForegroundColor Red; return $false }
    Write-Host "  submit OK through broker; waiting up to ${FireTimeoutSec}s for the chain..."
    $b = Wait-NewBuild $baseline $FireTimeoutSec
    if (-not $b)                  { Write-Host "  FAIL: no new Package build fired" -ForegroundColor Red; return $false }
    if ($b.status -ne 'SUCCESS')  { Write-Host "  FAIL: chain fired but status=$($b.status)" -ForegroundColor Red; return $false }
    Write-Host "  PASS: build #$($b.number) fired and succeeded" -ForegroundColor Green
    return $true
}
function Invoke-CaseB {
    Write-Host "`n== Case B: frozen-out submit fires nothing ==" -ForegroundColor Cyan
    $baseline = Get-LatestPackageId
    $before = (& p4 -p $P4d -u james changes -m1 "$Stream/ci-demo/heartbeat.txt") -join ""
    $env:P4PORT = $Broker; $env:P4USER = $DenyUser; $env:P4CLIENT = "$DenyUser-ws"
    & p4 sync -q "$Stream/ci-demo/heartbeat.txt" | Out-Null
    & p4 edit "$Stream/ci-demo/heartbeat.txt" | Out-Null
    Add-Content (Join-Path (Join-Path $WsRoot $DenyUser) "ci-demo\heartbeat.txt") ("frozen {0}" -f (Get-Date).ToString("s"))
    $out = (& p4 submit -d "ci-demo: case B frozen submit" 2>&1) -join "`n"
    $rejected = $LASTEXITCODE -ne 0
    & p4 revert "$Stream/ci-demo/heartbeat.txt" | Out-Null    # clean the workspace either way
    if (-not $rejected) { Write-Host "  FAIL: frozen-out submit SUCCEEDED (broker did not block)" -ForegroundColor Red; return $false }
    if ($out -notmatch 'freeze|broker|reject') { Write-Host "  WARN: submit failed but message wasn't clearly a broker reject:`n$out" -ForegroundColor Yellow }
    $after = (& p4 -p $P4d -u james changes -m1 "$Stream/ci-demo/heartbeat.txt") -join ""
    if ($after -ne $before) { Write-Host "  FAIL: a changelist landed despite the freeze" -ForegroundColor Red; return $false }
    Write-Host "  rejected as expected; watching ${NoFireWindowSec}s to confirm no build..."
    $b = Wait-NewBuild $baseline $NoFireWindowSec
    if ($b) { Write-Host "  FAIL: a build fired (#$($b.number)) with no committed change" -ForegroundColor Red; return $false }
    Write-Host "  PASS: broker rejected, no changelist, no build" -ForegroundColor Green
    return $true
}

Ensure-Identities
Ensure-Heartbeat
$a = Invoke-CaseA
$b = Invoke-CaseB
Write-Host "`n================ RESULT ================" -ForegroundColor Cyan
Write-Host ("Case A (allowed fires):   {0}" -f $(if ($a) {'PASS'} else {'FAIL'}))
Write-Host ("Case B (frozen no-fire):  {0}" -f $(if ($b) {'PASS'} else {'FAIL'}))
if (-not ($a -and $b)) { exit 1 }
Write-Host "`nVCS trigger verified end-to-end, policy-gated." -ForegroundColor Green
