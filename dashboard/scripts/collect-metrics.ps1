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
    [string]$MetricsDir = (Join-Path $PSScriptRoot "..\..\accel\.metrics"),
    [string]$Out        = (Join-Path $PSScriptRoot "..\data\snapshot.json")
)
$ErrorActionPreference = "Stop"

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
            'compile'   { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.compile = @{ serial=$r['serial (per-TU)']; mp=$r['/MP (per-TU)']; unity=$r['unity (1 file)']; pchWarm=$r['PCH warm + /MP'] } }
            'fastbuild' { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.fastbuild = @{ miss=$r['clean (cache miss)']; hit=$r['clean (cache HIT)'] } }
            'link'      { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.link = @{ full=$r['full /INCREMENTAL:NO']; incremental=$r['incremental (+1 edit)']; ltcg=$r['/LTCG (/GL objs)'] } }
            'bgfx'      { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.bgfx = @{ serial=$r['serial (per-file)']; mp=$r['/MP (per-file)']; unity=$r['unity (amalgamated)']
                              trivialEditPerFile=$m.incremental.trivial; trivialEditUnity=$m.incremental.unity } }
        }
    }
    if ($acc.Count -eq 0) { return $null }
    [pscustomobject]$acc
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
    param($BaseUrl, $Token, $ProjectId, $Count, $MetricsDir, $Out)
    $prior = if (Test-Path $Out) { Get-Content $Out -Raw | ConvertFrom-Json } else { $null }
    if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }

    $ci = $null
    try { if ($Token) { $ci = Get-CiFeed -BaseUrl $BaseUrl -Token $Token -ProjectId $ProjectId -Count $Count } }
    catch { Write-Warning "CI feed: $($_.Exception.Message) -- falling back to prior snapshot" }
    $accel = Get-AccelFeed -Dir $MetricsDir
    $p4 = $null
    try { $p4 = Get-PerforceFeed } catch { Write-Warning "perforce feed: $($_.Exception.Message)" }

    $snap = [ordered]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        ci       = Merge-Feed -New $ci    -Prior $prior.ci
        accel    = Merge-Feed -New $accel -Prior $prior.accel
        perforce = Merge-Feed -New $p4    -Prior $prior.perforce
    }
    $snap | ConvertTo-Json -Depth 8 | Set-Content -Path $Out -Encoding ascii
    Write-Host "wrote $Out (ci stale=$($snap.ci.stale) accel=$([bool]$snap.accel) perforce stale=$($snap.perforce.stale))"
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -BaseUrl $BaseUrl -Token $Token -ProjectId $ProjectId -Count $Count -MetricsDir $MetricsDir -Out $Out
}
