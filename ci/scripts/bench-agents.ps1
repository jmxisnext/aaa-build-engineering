<#
.SYNOPSIS
  Measure the build chain's wall-clock with 1 vs 2 build agents (idempotent).

.DESCRIPTION
  The AAA Sandbox chain fans out at Compile:

      Compile ──┬─> Smoke Test ─┐
                └─> Cook Data ──┴─> Package

  Smoke Test and Cook Data both depend only on Compile, so once Compile is
  done they are *eligible to run at the same time*. With one agent they
  serialize (one waits for the other); with two they run concurrently.

  This script measures that difference directly:

    1. Ensure both agents are authorized.
    2. Run the chain with agent-02 DISABLED  -> leaves serialize  (1 agent).
    3. Run the chain with agent-02 ENABLED   -> leaves overlap     (2 agents).

  With -Repeat N it runs that A/B pair N times and reports the median (plus
  min/max spread) per config — one sample is noise; the median is the number
  to quote. Each run forces rebuildAllDependencies so the whole DAG rebuilds
  fresh — no reusing a prior finished Compile — making runs comparable.

  Run a warmup chain first (a manual Package run) so p4 workspaces + artifact
  caches are warm; otherwise the first measured run pays one-time costs the
  rest don't. With -Repeat the median absorbs a single cold trial anyway.

  Auth: same as bootstrap-builds.ps1 — pass -Token, set $env:TEAMCITY_TOKEN,
  or let it scrape the CURRENT superuser token from teamcity-server.log.
  NB: the log is volume-persisted and holds stale tokens from prior boots;
  we take the LAST occurrence, which is the live process's token. See
  lessons-learned.md §6.

.EXAMPLE
  ./bench-agents.ps1                 # single A/B pair
  ./bench-agents.ps1 -Repeat 5       # 5 pairs, report medians
  ./bench-agents.ps1 -Repeat 5 -ShowBuilds   # also dump per-build tables
#>

param(
    [string]$Token,
    [string]$BaseUrl     = "http://localhost:8111",
    [string]$TopBuildType = "AAASandbox_Package",
    [int]$Agent2Id        = 11,
    [int]$Repeat          = 1,
    [int]$TimeoutSec      = 300,
    [switch]$ShowBuilds
)

$ErrorActionPreference = "Stop"

# ---------- auth ----------

function Get-SuperUserToken {
    # LAST occurrence — the persisted log carries stale tokens from prior boots.
    $line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}

if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))

# ---------- REST helpers ----------

function Invoke-TC {
    param([string]$Method, [string]$Path, $Body,
          [string]$ContentType = "application/json",
          [string]$Accept = "application/json")
    $p = @{ Method = $Method; Uri = "$BaseUrl$Path"
            Headers = @{ Authorization = $auth; Accept = $Accept } }
    if ($null -ne $Body) {
        $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 8 }
        $p.ContentType = $ContentType
    }
    Invoke-RestMethod @p
}

function Set-AgentEnabled {
    param([int]$Id, [bool]$Enabled, [string]$Why)
    $body = @{ status = $Enabled; comment = @{ text = $Why } }
    Invoke-TC PUT "/app/rest/agents/id:$Id/enabledInfo" -Body $body | Out-Null
}

function Set-AgentAuthorized {
    param([int]$Id)
    Invoke-TC PUT "/app/rest/agents/id:$Id/authorized" -Body "true" `
        -ContentType "text/plain" -Accept "text/plain" | Out-Null
}

# TeamCity stamps are yyyyMMddTHHmmsszzz (e.g. 20260603T170347+0000).
# All builds share one server clock, so we drop the TZ suffix and parse the
# first 15 chars — only relative durations matter here.
function ConvertFrom-TCDate {
    param([string]$s)
    if (-not $s) { return $null }
    [datetime]::ParseExact($s.Substring(0,15), "yyyyMMddTHHmmss",
        [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    $n = $s.Count
    if ($n % 2 -eq 1) { return [math]::Round($s[[int](($n-1)/2)], 1) }
    return [math]::Round(($s[$n/2 - 1] + $s[$n/2]) / 2, 1)
}

function Get-Chain {
    param([int]$TopId)
    $loc = "snapshotDependency:(to:(id:$TopId),includeInitial:true),defaultFilter:false"
    $fields = "build(id,buildTypeId,state,status,queuedDate,startDate,finishDate,agent(name))"
    $r = Invoke-TC GET ("/app/rest/builds?locator={0}&fields={1}" -f `
        [uri]::EscapeDataString($loc), [uri]::EscapeDataString($fields))
    $r.build
}

function Invoke-ChainRun {
    param([string]$Label)
    $body = @{
        buildType         = @{ id = $TopBuildType }
        triggeringOptions = @{ rebuildAllDependencies = $true }
        comment           = @{ text = "bench-agents: $Label" }
    }
    $q = Invoke-TC POST "/app/rest/buildQueue" -Body $body
    $topId = [int]$q.id

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $chain = Get-Chain -TopId $topId
        $top = $chain | Where-Object { $_.id -eq $topId }
        if ($top -and $top.state -eq 'finished') { break }
        Start-Sleep -Seconds 4
    }
    $chain = Get-Chain -TopId $topId
    foreach ($b in $chain) {
        if ($b.status -ne 'SUCCESS') {
            Write-Host "    WARN: $($b.buildTypeId) finished $($b.status)" -ForegroundColor Yellow
        }
    }
    $chain | ForEach-Object {
        $start = ConvertFrom-TCDate $_.startDate
        $finish = ConvertFrom-TCDate $_.finishDate
        [pscustomobject]@{
            Name   = $_.buildTypeId -replace 'AAASandbox_',''
            Agent  = $_.agent.name
            Status = $_.status
            Start  = $start
            Finish = $finish
            DurSec = if ($start -and $finish) { [math]::Round(($finish - $start).TotalSeconds,1) } else { $null }
        }
    }
}

function Get-RunSummary {
    param([string]$Title, $Builds)
    if ($ShowBuilds) {
        Write-Host "  == $Title ==" -ForegroundColor DarkCyan
        $Builds | Sort-Object Start | Format-Table Name, Agent, Status, DurSec,
            @{n='Start';e={$_.Start.ToString('HH:mm:ss')}},
            @{n='Finish';e={$_.Finish.ToString('HH:mm:ss')}} -AutoSize | Out-String | Write-Host
    }
    $smoke = $Builds | Where-Object Name -eq 'SmokeTest'
    $cook  = $Builds | Where-Object Name -eq 'CookData'
    $leafStart  = ($smoke.Start, $cook.Start | Measure-Object -Minimum).Minimum
    $leafFinish = ($smoke.Finish, $cook.Finish | Measure-Object -Maximum).Maximum
    [pscustomobject]@{
        LeafSpanSec   = [math]::Round(($leafFinish - $leafStart).TotalSeconds,1)
        LeavesOverlap = ($cook.Start -lt $smoke.Finish) -and ($smoke.Start -lt $cook.Finish)
        ChainSpanSec  = [math]::Round((($Builds.Finish | Measure-Object -Maximum).Maximum - `
                          ($Builds.Start | Measure-Object -Minimum).Minimum).TotalSeconds,1)
    }
}

# ---------- run ----------

Write-Host "Agent-pool benchmark at $BaseUrl  (repeat=$Repeat)" -ForegroundColor Cyan
Set-AgentAuthorized -Id $Agent2Id   # no-op if already authorized

$trials = @()
for ($t = 1; $t -le $Repeat; $t++) {
    Write-Host "`n---- trial $t/$Repeat ----" -ForegroundColor Cyan

    Set-AgentEnabled -Id $Agent2Id -Enabled $false -Why "bench-agents: 1-agent trial $t"
    Start-Sleep -Seconds 2
    $s1 = Get-RunSummary -Title "1 agent" -Builds (Invoke-ChainRun -Label "1-agent t$t")

    Set-AgentEnabled -Id $Agent2Id -Enabled $true -Why "bench-agents: 2-agent trial $t"
    Start-Sleep -Seconds 2
    $s2 = Get-RunSummary -Title "2 agents" -Builds (Invoke-ChainRun -Label "2-agent t$t")

    $rec = [pscustomobject]@{
        Trial      = $t
        OneLeaf    = $s1.LeafSpanSec
        TwoLeaf    = $s2.LeafSpanSec
        OneChain   = $s1.ChainSpanSec
        TwoChain   = $s2.ChainSpanSec
        OneOverlap = $s1.LeavesOverlap   # expect False
        TwoOverlap = $s2.LeavesOverlap   # expect True
    }
    $trials += $rec
    Write-Host ("  leaf: 1ag={0}s  2ag={1}s   chain: 1ag={2}s  2ag={3}s   overlap[1ag={4} 2ag={5}]" -f `
        $rec.OneLeaf, $rec.TwoLeaf, $rec.OneChain, $rec.TwoChain, $rec.OneOverlap, $rec.TwoOverlap)
}

# ---------- aggregate ----------

Write-Host "`n================ PER-TRIAL ================" -ForegroundColor Cyan
$trials | Format-Table Trial, OneLeaf, TwoLeaf, OneChain, TwoChain, OneOverlap, TwoOverlap -AutoSize | Out-String | Write-Host

$oneLeaf  = [double[]]($trials.OneLeaf);  $twoLeaf  = [double[]]($trials.TwoLeaf)
$oneChain = [double[]]($trials.OneChain); $twoChain = [double[]]($trials.TwoChain)
function StatLine { param($Label, [double[]]$V)
    "{0,-22} median={1,6}  min={2,6}  max={3,6}  n={4}" -f $Label,
        (Get-Median $V), ($V | Measure-Object -Minimum).Minimum, ($V | Measure-Object -Maximum).Maximum, $V.Count
}

Write-Host "================ MEDIANS =================" -ForegroundColor Cyan
Write-Host (StatLine "leaf  1 agent  (s)"  $oneLeaf)
Write-Host (StatLine "leaf  2 agents (s)"  $twoLeaf)
Write-Host (StatLine "chain 1 agent  (s)"  $oneChain)
Write-Host (StatLine "chain 2 agents (s)"  $twoChain)

$mOneLeaf = Get-Median $oneLeaf; $mTwoLeaf = Get-Median $twoLeaf
$mOneChain = Get-Median $oneChain; $mTwoChain = Get-Median $twoChain
$leafSpeedup = if ($mTwoLeaf -gt 0) { [math]::Round($mOneLeaf / $mTwoLeaf, 2) } else { 0 }
$overlapOK = (@($trials | Where-Object { $_.TwoOverlap -and -not $_.OneOverlap }).Count -eq $Repeat)

Write-Host "`n================ VERDICT =================" -ForegroundColor Cyan
Write-Host ("leaf phase (median):  {0}s -> {1}s  = {2}s saved, {3}x" -f `
    $mOneLeaf, $mTwoLeaf, [math]::Round($mOneLeaf-$mTwoLeaf,1), $leafSpeedup) -ForegroundColor White
Write-Host ("whole chain (median): {0}s -> {1}s  = {2}s saved" -f `
    $mOneChain, $mTwoChain, [math]::Round($mOneChain-$mTwoChain,1)) -ForegroundColor White
Write-Host ("overlap pattern consistent across all {0} trials: {1}" -f $Repeat, $overlapOK) -ForegroundColor White
