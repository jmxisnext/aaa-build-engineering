<#
.SYNOPSIS
  Gather the three track feeds (CI: TeamCity REST; accel: bench -Json emits; perforce:
  live p4) into dashboard/data/snapshot.json. Each feed independently falls back to the
  prior snapshot's section (marked stale) when its source is unreachable, so a partial
  infra state still produces a complete, committable snapshot.
.EXAMPLE
  pwsh -File .\dashboard\scripts\collect-metrics.ps1
#>
param(
    [string]$BaseUrl   = "http://localhost:8111",
    [string]$Token,
    [string]$ProjectId = "AAASandbox",
    [int]   $Count     = 50,
    [string]$MetricsDir       = (Join-Path $PSScriptRoot "..\..\accel\.metrics"),
    [string]$UnrealMetricsDir    = (Join-Path $PSScriptRoot "..\..\unreal\.metrics"),
    [string]$PipelineMetricsDir  = (Join-Path $PSScriptRoot "..\..\pipeline\.metrics"),
    [string]$Out        = (Join-Path $PSScriptRoot "..\data\snapshot.json")
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot '_dashboard-common.ps1')

function ConvertFrom-TcBuilds {
    param([object[]]$Builds)
    foreach ($b in $Builds) {
        $cl = if ($b.revisions.revision) { [int](@($b.revisions.revision)[0].version) } else { $null }
        # TeamCity emits compact 'yyyyMMddTHHmmsszzz' (e.g. 20260604T192354+0000).
        # Parse start/finish to DateTimeOffset once, then derive BOTH durationSec
        # AND an ISO-8601 finishUtc -- the snapshot schema (see the fixture) is ISO,
        # and the render does [datetime]$finishUtc, which can't parse the raw form.
        $fmt = "yyyyMMddTHHmmsszzz"
        $sOff = if ($b.startDate)  { try { [datetimeoffset]::ParseExact(($b.startDate  -replace '(\+\d{2})(\d{2})$','$1:$2'), $fmt, $null) } catch { $null } } else { $null }
        $fOff = if ($b.finishDate) { try { [datetimeoffset]::ParseExact(($b.finishDate -replace '(\+\d{2})(\d{2})$','$1:$2'), $fmt, $null) } catch { $null } } else { $null }
        $dur = if ($sOff -and $fOff) { [math]::Round(($fOff - $sOff).TotalSeconds, 2) } else { $null }
        $finishUtc = if ($fOff) { $fOff.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $b.finishDate }
        [pscustomobject]@{
            config      = $b.buildType.name
            number      = [int]$b.number
            cl          = $cl
            status      = $b.status
            statusText  = $b.statusText
            durationSec = $dur
            finishUtc   = $finishUtc
            url         = $b.webUrl
        }
    }
}

function ConvertFrom-P4Streams {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n" | Where-Object { $_ -match '^Stream\s' })) {
        # Stream <path> <type> <parent> '<desc>'
        $parts = $line -split '\s+', 5
        [pscustomobject]@{ stream = $parts[1]; type = $parts[2]; parent = $parts[3] }
    }
}

function Get-AccelFeed {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $acc = [ordered]@{}
    foreach ($f in Get-ChildItem $Dir -Filter *.json -ErrorAction SilentlyContinue) {
        $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
        switch ($m.sample) {
            'compile'   { $r = ConvertTo-ConfigBest $m.results
                          $acc.compile = @{ serial=$r['serial (per-TU)']; mp=$r['/MP (per-TU)']; unity=$r['unity (1 file)']; pchWarm=$r['PCH warm + /MP'] } }
            'fastbuild' { $r = ConvertTo-ConfigBest $m.results
                          $acc.fastbuild = @{ miss=$r['clean (cache miss)']; hit=$r['clean (cache HIT)'] } }
            'link'      { $r = ConvertTo-ConfigBest $m.results
                          $acc.link = @{ full=$r['full /INCREMENTAL:NO']; incremental=$r['incremental (+1 edit)']; ltcg=$r['/LTCG (/GL objs)'] } }
            'bgfx'      { $r = ConvertTo-ConfigBest $m.results
                          $acc.bgfx = @{ serial=$r['serial (per-file)']; mp=$r['/MP (per-file)']; unity=$r['unity (amalgamated)']
                              trivialEditPerFile=$m.incremental.trivial; trivialEditUnity=$m.incremental.unity } }
        }
    }
    if ($acc.Count -eq 0) { return $null }
    [pscustomobject]$acc
}

function ConvertFrom-UnrealMetrics {
    # Pure transform: parsed unreal/.metrics records -> the dashboard 'unreal' section.
    # Latest-per-step (by utc) duration stages in pipeline order, plus the latest stamp's
    # CL provenance. Only emits fields present in the metrics -- nothing fabricated.
    param([object[]]$Metrics)
    if (-not $Metrics) { return $null }
    $order = 'compile','cook','package','buildgraph'
    $stages = foreach ($step in $order) {
        $candidates = $Metrics | Where-Object { $_.step -eq $step -and -not $_.listOnly }   # skip list-only buildgraph dry-runs
        # The canonical pipeline baseline is the TeamCity/wrapper path; the Horde run is a
        # separate orchestrator shown in $orchestrators, so it must not displace the baseline row.
        if ($step -eq 'buildgraph') { $candidates = $candidates | Where-Object { ([string]$_.source) -ne 'horde' } }
        $latest = $candidates | Sort-Object { [datetime]$_.utc } | Select-Object -Last 1
        if ($latest) {
            [pscustomobject]@{ step = $latest.step; target = $latest.target; durationSec = $latest.durationSec; utc = $latest.utc }
        }
    }
    $st = $Metrics | Where-Object { $_.step -eq 'stamp' } | Sort-Object { [datetime]$_.utc } | Select-Object -Last 1
    $stamp = if ($st) {
        [pscustomobject]@{ changelist = $st.changelist; changelistSource = $st.changelistSource
            p4Changelist = $st.p4Changelist; engineChangelist = $st.engineChangelist; source = $st.source; utc = $st.utc }
    } else { $null }
    # Orchestrator parity: latest non-list-only buildgraph per source -- the "same graph under
    # both runners" feed. An absent source IS the TeamCity/wrapper path (the buildgraph run and
    # the teamcity stamp share a utc). Sorted chronologically so the baseline reads first.
    $orchestrators = @(
        $Metrics |
            Where-Object { $_.step -eq 'buildgraph' -and -not $_.listOnly } |
            Group-Object { if ([string]$_.source) { [string]$_.source } else { 'teamcity' } } |
            ForEach-Object {
                $latest = $_.Group | Sort-Object { [datetime]$_.utc } | Select-Object -Last 1
                [pscustomobject]@{ source = $_.Name; target = $latest.target; durationSec = $latest.durationSec; success = [bool]$latest.success; utc = $latest.utc }
            } |
            Sort-Object { [datetime]$_.utc }
    )
    if (-not @($stages).Count -and -not $stamp) { return $null }
    [pscustomobject]@{ stale = $false; stages = @($stages); stamp = $stamp; orchestrators = $orchestrators }
}

function Get-UnrealFeed {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $metrics = foreach ($f in Get-ChildItem $Dir -Filter *.json -ErrorAction SilentlyContinue) {
        try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { }
    }
    if (-not $metrics) { return $null }
    ConvertFrom-UnrealMetrics -Metrics @($metrics)
}

function ConvertFrom-PipelineMetrics {
    # Pure transform: parsed pipeline/.metrics cook-stats records -> the 'pipeline' section.
    # Latest record by utc. 'warm' = a run that recooked nothing but reused something.
    param([object[]]$Metrics)
    if (-not $Metrics) { return $null }
    $latest = $Metrics | Sort-Object { [datetime]$_.utc } | Select-Object -Last 1
    if (-not $latest) { return $null }
    $cooked = [int]$latest.textures_cooked + [int]$latest.audio_cooked + [int]$latest.characters_cooked
    $cached = [int]$latest.textures_cached + [int]$latest.audio_cached + [int]$latest.characters_cached
    [pscustomobject]@{
        stale      = $false
        cooked     = $cooked
        cached     = $cached
        totalBytes = [int]$latest.total_bytes
        elapsedSec = [double]$latest.elapsed_sec
        warm       = ($cooked -eq 0 -and $cached -gt 0)
        utc        = $latest.utc
    }
}

function Get-PipelineFeed {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $metrics = foreach ($f in Get-ChildItem $Dir -Filter *.json -ErrorAction SilentlyContinue) {
        try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { }
    }
    if (-not $metrics) { return $null }
    ConvertFrom-PipelineMetrics -Metrics @($metrics)
}

function Merge-Feed {
    param($New, $Prior)
    if ($null -ne $New) { return $New }
    if ($null -eq $Prior) { return $null }
    # clone prior section and mark stale
    $obj = $Prior | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $obj | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
    return $obj
}

# ---- live collectors (used by Invoke-Main; not unit-tested) ----
function Get-CiFeed {
    param([string]$BaseUrl, [string]$Token, [string]$ProjectId, [int]$Count)
    $headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token")); Accept = "application/json" }
    $fields  = "build(number,status,statusText,buildTypeId,buildType(name),webUrl,startDate,finishDate,revisions(revision(version)))"
    $locator = "affectedProject:(id:$ProjectId),state:finished,count:$Count"
    $resp = Invoke-RestMethod -Method GET -Uri "$BaseUrl/app/rest/builds?locator=$locator&fields=$fields" -Headers $headers -TimeoutSec 10
    $builds = ConvertFrom-TcBuilds -Builds @($resp.build)
    $configs = @($builds | ForEach-Object { $_.config } | Sort-Object -Unique)
    [pscustomobject]@{ stale=$false; configs=$configs; builds=$builds }
}
function Get-PerforceFeed {
    $streams = ConvertFrom-P4Streams -Text (p4 streams 2>$null | Out-String)
    $depots  = @(p4 depots 2>$null | ForEach-Object { ($_ -split '\s+')[1] } | Where-Object { $_ })
    if (-not $streams) { return $null }
    [pscustomobject]@{ stale=$false; depots=$depots; streams=@($streams); triggers=@(); proxy=$null }
}

function Invoke-Main {
    param($BaseUrl, $Token, $ProjectId, $Count, $MetricsDir, $UnrealMetricsDir, $PipelineMetricsDir, $Out)
    $prior = if (Test-Path $Out) { Get-Content $Out -Raw | ConvertFrom-Json } else { $null }
    if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }

    $ci = $null
    try { if ($Token) { $ci = Get-CiFeed -BaseUrl $BaseUrl -Token $Token -ProjectId $ProjectId -Count $Count } }
    catch { Write-Warning "CI feed: $($_.Exception.Message) -- falling back to prior snapshot" }
    $accel = Get-AccelFeed -Dir $MetricsDir
    $p4 = $null
    try { $p4 = Get-PerforceFeed } catch { Write-Warning "perforce feed: $($_.Exception.Message)" }
    $unreal = Get-UnrealFeed -Dir $UnrealMetricsDir   # local files, no infra
    $pipeline = Get-PipelineFeed -Dir $PipelineMetricsDir   # local files, no infra

    $snap = [ordered]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        ci       = Merge-Feed -New $ci     -Prior $prior.ci
        accel    = Merge-Feed -New $accel  -Prior $prior.accel
        perforce = Merge-Feed -New $p4     -Prior $prior.perforce
        unreal   = Merge-Feed -New $unreal -Prior $prior.unreal
        pipeline = Merge-Feed -New $pipeline -Prior $prior.pipeline
    }
    $snap | ConvertTo-Json -Depth 8 | Set-Content -Path $Out -Encoding ascii
    Write-Host "wrote $Out (ci stale=$($snap.ci.stale) accel=$([bool]$snap.accel) perforce stale=$($snap.perforce.stale) unreal stale=$($snap.unreal.stale))"
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -BaseUrl $BaseUrl -Token $Token -ProjectId $ProjectId -Count $Count -MetricsDir $MetricsDir -UnrealMetricsDir $UnrealMetricsDir -PipelineMetricsDir $PipelineMetricsDir -Out $Out
}
