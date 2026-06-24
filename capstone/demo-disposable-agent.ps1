<#
.SYNOPSIS
  Slice 2 (the headline stretch): demonstrate EPHEMERAL CI - a disposable agent
  container spun up for a build and disposed after, auto-authorized with no manual
  approval. Standalone + additive: it does not touch the Slice 1 demo.

.DESCRIPTION
  TeamCity Professional (free) caps at 3 agent licenses and the sandbox already uses
  all 3, so a genuinely-new 4th agent CANNOT be authorized (LicenseNotGrantedException).
  The faithful local model - and exactly how a cloud/K8s agent profile works - is
  EPHEMERAL COMPUTE on a LICENSED IDENTITY: the disposable container reuses a standing
  agent's name + authorization token, so it reclaims that agent's existing license and
  auto-authorizes on connect. The container is fresh and disposed (`docker run --rm`);
  the license/identity is the stable, licensed slot.

  Lifecycle (with before/during/after proof = docker ps + the Agents list + licensing):
    1. BEFORE   - standing state (compose agent serves the identity)
    2. SPIN UP  - stop the standing compose agent, launch a --rm disposable reusing its
                  identity on the compose network; it reconnects AUTHORIZED, same license
    3. BUILD    - force a Cook Assets build onto the disposable (the other agent disabled)
    4. DISPOSE  - remove the container; the agent goes offline (the --rm lifecycle)
    5. RESTORE  - restart the standing compose agent, re-enable the other agent

  A try/finally guarantees RESTORE runs even if a step fails - the demo never leaves the
  standing agent stopped or the other agent disabled.

.NOTES
  Reuses, does not rebuild: the existing teamcity-agent image + the standing agent's
  persisted identity (ci/data/teamcity_agent2/conf). The license cap and the K8s
  production-scale path are written up in the Slice 3 Zen/DDC doc - this is the local,
  bundled-tooling-only disposable-agent answer.
#>
param(
    [string]$Token,
    [string]$BaseUrl             = "http://localhost:8111",
    [string]$Network             = "ci_default",
    [string]$ServerUrlInternal   = "http://teamcity-server:8111",
    [string]$StandingContainer   = "teamcity-agent-02",
    [string]$StandingConf        = (Join-Path (Split-Path $PSScriptRoot -Parent) "ci\data\teamcity_agent2\conf\buildAgent.properties"),
    [string]$DisposableContainer = "tc-disposable",
    [string]$OtherAgent          = "agent-linux-01",
    [string]$CookBuildType       = "AAASandbox_CookAssets",
    [int]   $ConnectTimeoutSec   = 120,
    [int]   $BuildTimeoutSec     = 300,
    [switch]$NoBuild
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $Repo 'ci\scripts\_ci-common.ps1')   # Resolve-TeamCityToken, Connect-TeamCity, Invoke-TC

# ---------- console narration ----------
function Step([string]$n, [string]$msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Ok  ([string]$msg) { Write-Host "  OK: $msg"   -ForegroundColor Green }
function Info([string]$msg) { Write-Host "  $msg"       -ForegroundColor Gray }
function Die ([string]$msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red; exit 1 }

# ---------- helpers ----------
function Get-AgentProp([string]$path, [string]$key) {
    if (-not (Test-Path $path)) { Die "standing agent conf not found: $path" }
    $line = Get-Content $path | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if (-not $line) { Die "key '$key' not found in $path" }
    ($line -split '=', 2)[1].Trim()
}
function Get-AgentId([string]$name) {
    $a = Invoke-TC GET "/app/rest/agents?locator=name:$name,authorized:any,connected:any&fields=agent(id,name)"
    [int](@($a.agent)[0].id)
}
function Set-AgentEnabled([int]$id, [bool]$enabled, [string]$why) {
    Invoke-TC PUT "/app/rest/agents/id:$id/enabledInfo" -Body @{ status = $enabled; comment = @{ text = $why } } | Out-Null
}
function Wait-AgentState([string]$name, [scriptblock]$cond, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $a = Invoke-TC GET "/app/rest/agents?locator=name:$name,authorized:any,connected:any&fields=agent(name,connected,authorized)"
        $g = @($a.agent)[0]
        if ($g -and (& $cond $g)) { return $g }
        Start-Sleep -Seconds 3
    }
    return $null
}
function Show-State([string]$label) {
    Write-Host "  -- $label --" -ForegroundColor DarkCyan
    docker ps --filter "name=teamcity-agent" --filter "name=$DisposableContainer" --format "     container {{.Names}}: {{.Status}}"
    $ag = Invoke-TC GET "/app/rest/agents?locator=authorized:any,connected:any&fields=agent(name,connected,authorized,enabled)"
    @($ag.agent) | Where-Object { $_.name -like 'agent-*' } | ForEach-Object {
        Write-Host ("     agent {0,-18} connected={1} authorized={2} enabled={3}" -f $_.name, $_.connected, $_.authorized, $_.enabled)
    }
    $la = Invoke-TC GET "/app/rest/server/licensingData?fields=maxAgents,agentsLeft"
    Write-Host ("     license: {0}/{1} authorized, {2} free" -f ($la.maxAgents - $la.agentsLeft), $la.maxAgents, $la.agentsLeft)
}

Write-Host "================ CAPSTONE - EPHEMERAL DISPOSABLE AGENT ================" -ForegroundColor Cyan

# ---------- preflight (read-only) ----------
Step "0/5" "Preflight"
try {
    $tc  = Connect-TeamCity -BaseUrl $BaseUrl -Token (Resolve-TeamCityToken -Token $Token)
    $srv = Invoke-TC GET "/app/rest/server"
} catch { Die "TeamCity REST not reachable at $BaseUrl ($($_.Exception.Message))" }
$image = (docker inspect $StandingContainer --format '{{.Config.Image}}' 2>$null)
if (-not $image) { Die "standing container '$StandingContainer' not found - is the compose stack up?" }
$agentName  = Get-AgentProp $StandingConf 'name'
$agentToken = Get-AgentProp $StandingConf 'authorizationToken'
Ok "TeamCity $($srv.version); reusing identity '$agentName' (licensed); disposable image $image"

# ---------- the lifecycle (mutating; try/finally guarantees restore) ----------
$disabledOther   = $false
$stoppedStanding = $false
$otherId         = 0
try {
    Step "1/5" "BEFORE - standing state (the compose agent serves '$agentName')"
    Show-State "before"

    Step "2/5" "SPIN UP - disposable container reusing the licensed identity"
    $otherId = Get-AgentId $OtherAgent
    Set-AgentEnabled $otherId $false "capstone disposable-agent demo: force the build onto the disposable"
    $disabledOther = $true
    Info "disabled $OtherAgent (id $otherId) so a build can only land on the disposable"
    docker stop $StandingContainer | Out-Null
    $stoppedStanding = $true
    Info "stopped standing $StandingContainer (frees the identity slot; the license stays with '$agentName')"
    docker rm -f $DisposableContainer 2>$null | Out-Null
    docker run -d --rm --name $DisposableContainer --network $Network --add-host host.docker.internal:host-gateway `
        -e SERVER_URL=$ServerUrlInternal -e AGENT_NAME=$agentName -e AGENT_TOKEN=$agentToken $image | Out-Null
    Info "launched disposable container '$DisposableContainer' (docker run --rm)"
    $g = Wait-AgentState $agentName { param($x) $x.connected -eq $true -and $x.authorized -eq $true } $ConnectTimeoutSec
    if (-not $g) { Die "disposable agent did not connect+authorize within ${ConnectTimeoutSec}s" }
    Ok "disposable agent UP and AUTHORIZED - no manual approval, license reused"
    Show-State "during (disposable container serves '$agentName')"

    if ($NoBuild) {
        Step "3/5" "BUILD - skipped (-NoBuild)"
    } else {
        Step "3/5" "BUILD - run a real build on the disposable agent"
        $q = Invoke-TC POST "/app/rest/buildQueue" -Body @{ buildType = @{ id = $CookBuildType }; comment = @{ text = "capstone: build on disposable agent" } }
        $bid = [int]$q.id
        Info "queued $CookBuildType (id $bid); waiting up to ${BuildTimeoutSec}s..."
        $f = "id,number,state,status,agent(name)"
        $deadline = (Get-Date).AddSeconds($BuildTimeoutSec); $b = $null
        while ((Get-Date) -lt $deadline) {
            $b = Invoke-TC GET ("/app/rest/builds/id:{0}?fields={1}" -f $bid, [uri]::EscapeDataString($f))
            if ($b.state -eq 'finished') { break }
            Start-Sleep -Seconds 3
        }
        if (-not $b -or $b.state -ne 'finished') { Die "build did not finish within ${BuildTimeoutSec}s" }
        if ($b.status -ne 'SUCCESS')             { Die "build #$($b.number) finished $($b.status)" }
        if ($b.agent.name -ne $agentName)        { Die "build ran on $($b.agent.name), not the disposable $agentName" }
        Ok "build #$($b.number) ran GREEN on the disposable agent ($($b.agent.name))"
    }

    Step "4/5" "DISPOSE - remove the container; the agent goes offline"
    docker stop $DisposableContainer | Out-Null   # --rm removes it on stop
    $stillThere = docker ps --filter "name=$DisposableContainer" --format '{{.Names}}'
    Info ("container after dispose: {0}" -f $(if ($stillThere) { $stillThere } else { '(gone)' }))
    Wait-AgentState $agentName { param($x) $x.connected -eq $false } 30 | Out-Null
    Ok "disposable disposed - '$agentName' is now offline (ephemeral compute torn down)"
    Show-State "after disposal"
}
finally {
    Step "5/5" "RESTORE - return the stack to standing state"
    docker rm -f $DisposableContainer 2>$null | Out-Null
    if ($stoppedStanding) {
        docker start $StandingContainer | Out-Null
        Info "restarted standing $StandingContainer"
        Wait-AgentState $agentName { param($x) $x.connected -eq $true } 60 | Out-Null
    }
    if ($disabledOther -and $otherId) {
        Set-AgentEnabled $otherId $true "restore after capstone disposable-agent demo"
        Info "re-enabled $OtherAgent"
    }
    Show-State "restored"
}

Write-Host "`n================ EPHEMERAL DISPOSABLE AGENT: GREEN ================" -ForegroundColor Green
Write-Host "Point at:" -ForegroundColor Green
Write-Host "  - a fresh container was spun up, AUTO-AUTHORIZED (no approval), ran a build, and was disposed"
Write-Host "  - the license never moved: ephemeral COMPUTE on a stable LICENSED IDENTITY (the cloud-agent model)"
Write-Host "  - production scale = a Kubernetes cloud profile (min/max + terminateIdleMinutes) - scoped in the Slice 3 writeup"
