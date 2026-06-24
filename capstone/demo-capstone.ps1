<#
.SYNOPSIS
  The Capstone end-to-end demo runbook: drives the whole AAA-shaped pipeline on the
  live sandbox stack and asserts each stage. Exits non-zero if any stage fails, so it
  doubles as an integration self-test (same contract as ci/scripts/demo-vcs-trigger.ps1).

.DESCRIPTION
  Two coherent halves of one repo (see capstone/README.md for the full narrative):

    (A) Pipeline mechanics - a tracked change is submitted to //game/main THROUGH the
        policy broker (:1667) -> TeamCity auto-fires the hoops chain (Compile ->
        SmokeTest||CookData -> Package) -> a CL-version-stamped artifact is produced ->
        we fetch + print its build-info.json (the provenance: CL -> build -> artifact).

    (B) The real cook - the standalone `Cook Assets` config runs the content-addressed
        cooker (warm-cache hit/miss) -> we pull its cook-stats artifact down to the host
        `pipeline/.metrics/` (the dashboard's Cook panel reads local files, not TeamCity)
        and regenerate the dashboard so both the chain run AND the Cook panel reflect it.

  Point at four things: provenance, observability (dashboard), content-addressed cook,
  and - as the Slice 2 stretch - ephemeral CI (see README; this run uses the standing agent).

.NOTES
  Reuses, does not rebuild: the broker freeze + change-commit trigger + VCS trigger (Track 1),
  the hoops chain + version stamp (Track 2), the content-addressed cooker (Track 5), and the
  dashboard collectors (observability). The canonical policy-gating proof (allow AND deny) is
  ci/scripts/demo-vcs-trigger.ps1; this runbook drives only the happy path end-to-end.
#>
param(
    [string]$Token,
    [string]$BaseUrl          = "http://localhost:8111",
    [string]$P4d              = "localhost:1666",
    [string]$Broker           = "localhost:1667",
    [string]$Stream           = "//game/main",
    [string]$BuildUser        = "build-svc",
    [string]$WsRoot           = "C:\PerforceSandbox\ws",
    [string]$PackageBuildType = "AAASandbox_Package",
    [string]$CookBuildType    = "AAASandbox_CookAssets",
    [int]   $ChainTimeoutSec  = 360,
    [int]   $FinishTimeoutSec = 240,
    [int]   $CookTimeoutSec   = 240,
    [switch]$SkipDashboard
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $Repo 'ci\scripts\_ci-common.ps1')   # Resolve-TeamCityToken, Connect-TeamCity, Invoke-TC

# ---------- console narration ----------
function Step([string]$n, [string]$msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Ok  ([string]$msg) { Write-Host "  OK: $msg"   -ForegroundColor Green }
function Info([string]$msg) { Write-Host "  $msg"       -ForegroundColor Gray }
function Die ([string]$msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red; exit 1 }

# ---------- TeamCity REST helpers (read $tc via _ci-common Invoke-TC) ----------
function Get-LatestBuildId([string]$bt) {
    $loc = "buildType:$bt,count:1,running:any,canceled:any,defaultFilter:false"
    # request the top-level `count` so the empty-result guard is real (a build(id)-only
    # field spec omits count, and $r.count then falls back to PSObject.Count = 1 always).
    $r = Invoke-TC GET ("/app/rest/builds?locator={0}&fields=count,build(id)" -f [uri]::EscapeDataString($loc))
    if ([int]$r.count -lt 1) { return 0 }
    [int](@($r.build)[0].id)
}
function Wait-BuildFinished([int]$id, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds([math]::Max($timeoutSec, 5))
    # FLAT fields - the single-build endpoint (/builds/id:N) rejects the list-style
    # `build(...)` wrapper by silently returning empty state/status (no error), which
    # would make the finished-check never match and time out to $null. Use flat fields.
    $f = "id,number,state,status,revisions(revision(version))"
    while ((Get-Date) -lt $deadline) {
        $b = Invoke-TC GET ("/app/rest/builds/id:{0}?fields={1}" -f $id, [uri]::EscapeDataString($f))
        if ($b.state -eq 'finished') { return $b }
        Start-Sleep -Seconds 3
    }
    return $null
}
# Returns the id of the first build of $bt newer than $baseline, or 0 if none appears
# in time. Detection only - the caller waits for FINISH on its own clock, so a slow
# chain isn't misreported as "never fired" (the Package node is the LAST in the chain,
# so it only becomes detectable late; sharing one budget would starve the finish-wait).
function Wait-NewBuildId([string]$bt, [int]$baseline, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $id = Get-LatestBuildId $bt
        if ($id -gt $baseline) { return $id }
        Start-Sleep -Seconds 4
    }
    return 0
}
function Save-Artifact([int]$buildId, [string]$artifactPath, [string]$outFile) {
    $uri = "$BaseUrl/app/rest/builds/id:$buildId/artifacts/content/$artifactPath"
    Invoke-WebRequest -Uri $uri -Headers @{ Authorization = $tc.Auth } -OutFile $outFile | Out-Null
}

# ---------- Perforce demo identity (mirrors demo-vcs-trigger's proven setup; build-svc only) ----------
function Ensure-DemoIdentity {
    "User: $BuildUser`nEmail: $BuildUser@example.invalid`nFullName: Build Service Account`n" |
        & p4 -p $P4d -u devuser user -f -i | Out-Null
    $client = "$BuildUser-ws"; $root = Join-Path $WsRoot $BuildUser
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (& p4 -p $P4d -u devuser clients -e $client 2>$null) {
        & p4 -p $P4d -u devuser client -d -f $client 2>$null | Out-Null   # drop a stale non-stream client
    }
    "Client: $client`nOwner: $BuildUser`nRoot: $root`nStream: $Stream`n" |
        & p4 -p $P4d -u devuser client -i | Out-Null
    # heartbeat seed only if missing - direct to p4d, bypassing the broker freeze
    if (-not (& p4 -p $P4d -u $BuildUser -c $client files "$Stream/ci-demo/heartbeat.txt" 2>$null)) {
        & p4 -p $P4d -u $BuildUser -c $client sync -q "$Stream/..." 2>$null | Out-Null
        $hb = Join-Path $root "ci-demo\heartbeat.txt"
        New-Item -ItemType Directory -Path (Split-Path $hb) -Force | Out-Null
        Set-Content -Path $hb -Value "seed"
        & p4 -p $P4d -u $BuildUser -c $client add $hb | Out-Null
        & p4 -p $P4d -u $BuildUser -c $client submit -d "capstone: seed heartbeat" | Out-Null
    }
}

Write-Host "================ CAPSTONE END-TO-END DEMO ================" -ForegroundColor Cyan

# ===== [1/6] Preflight - ensure the stack is up =====
Step "1/6" "Preflight - ensure the stack is up (p4d + broker + TeamCity + agent)"
if (-not (Get-Process p4d -ErrorAction SilentlyContinue)) {
    Info "p4d down - starting (idempotent)..."; & (Join-Path $Repo 'perforce\scripts\start-p4d.ps1') | Out-Null
}
if (-not (Get-Process p4broker -ErrorAction SilentlyContinue)) {
    Info "broker down - starting (idempotent)..."; & (Join-Path $Repo 'perforce\broker\start-broker.ps1') | Out-Null
}
& p4 -p $P4d info *> $null;    if ($LASTEXITCODE -ne 0) { Die "p4d not answering on $P4d" }
& p4 -p $Broker info *> $null; if ($LASTEXITCODE -ne 0) { Die "broker not answering on $Broker" }
Ok "p4d $P4d + broker $Broker up"

try {
    $Token = Resolve-TeamCityToken -Token $Token          # explicit -Token | $env:TEAMCITY_TOKEN | scrape server log
    $tc = Connect-TeamCity -BaseUrl $BaseUrl -Token $Token # opens session + CSRF token (needed for the buildQueue POST)
    $srv = Invoke-TC GET "/app/rest/server"
} catch {
    Die "TeamCity REST not reachable at $BaseUrl - bring it up:`n        docker compose -f ci/docker-compose.yml up -d`n      ($($_.Exception.Message))"
}
$agents = Invoke-TC GET "/app/rest/agents?locator=connected:true,authorized:true&fields=count,agent(name)"
$conn   = @($agents.agent | Where-Object { $_.name -like 'agent-linux-*' })
if ($conn.Count -lt 1) { Die "no connected+authorized linux build agent - check: docker compose -f ci/docker-compose.yml ps" }
Ok "TeamCity $($srv.version) up; $($conn.Count) build agent(s) connected ($([string]::Join(', ', @($conn.name))))"

# ===== [2/6] Track 1 - policy-gated submit =====
Step "2/6" "Track 1 - submit a tracked change to $Stream THROUGH the freeze broker $Broker"
Ensure-DemoIdentity
$baseline = Get-LatestBuildId $PackageBuildType
$env:P4PORT = $Broker; $env:P4USER = $BuildUser; $env:P4CLIENT = "$BuildUser-ws"
& p4 sync -q "$Stream/ci-demo/heartbeat.txt" | Out-Null
& p4 edit    "$Stream/ci-demo/heartbeat.txt" | Out-Null
$wsFile = Join-Path (Join-Path $WsRoot $BuildUser) "ci-demo\heartbeat.txt"
Add-Content $wsFile ("capstone demo {0}" -f (Get-Date).ToString('s'))
$out = & p4 submit -d "capstone: end-to-end demo submit" 2>&1
$submitOk = $LASTEXITCODE -eq 0
& p4 revert "$Stream/ci-demo/heartbeat.txt" 2>$null | Out-Null
# reset p4 env so later bare p4 reads (dashboard perforce feed) hit p4d directly
$env:P4PORT = $P4d; $env:P4USER = 'devuser'; Remove-Item Env:\P4CLIENT -ErrorAction SilentlyContinue
if (-not $submitOk) { Die "allowlisted submit through the broker was blocked:`n$(($out | Out-String))" }
$submitOut   = ($out | Out-String)
$submittedCl = if ($submitOut -match 'Change (\d+) submitted') { $matches[1] } else { '?' }
Ok "submitted CL $submittedCl to $Stream through the freeze broker (allowlisted $BuildUser)"

# ===== [3/6] Track 2 - CI chain auto-fires =====
Step "3/6" "Track 2 - TeamCity auto-fires the hoops chain (Compile -> SmokeTest||CookData -> Package)"
Info "waiting up to ${ChainTimeoutSec}s for a new $PackageBuildType build to fire, then up to ${FinishTimeoutSec}s for it to finish..."
$pkgId = Wait-NewBuildId $PackageBuildType $baseline $ChainTimeoutSec
if ($pkgId -le 0) { Die "no new Package build fired within ${ChainTimeoutSec}s (VCS trigger / chain?)" }
$pkg = Wait-BuildFinished $pkgId $FinishTimeoutSec
if (-not $pkg)                 { Die "Package build (id $pkgId) fired but did not finish within ${FinishTimeoutSec}s (bump -FinishTimeoutSec)" }
if ($pkg.status -ne 'SUCCESS') { Die "chain fired but Package #$($pkg.number) finished $($pkg.status)" }
$pkgCl = if ($pkg.revisions.revision) { [int](@($pkg.revisions.revision)[0].version) } else { $null }
# the build that fired must include the change we just submitted - guards against latching a stale build
if ($submittedCl -ne '?' -and $pkgCl -and $pkgCl -lt [int]$submittedCl) {
    Die "latched stale build: Package #$($pkg.number) is at CL $pkgCl, older than our submit CL $submittedCl"
}
Ok "chain green: Package #$($pkg.number) at CL $pkgCl"

# ===== [4/6] Provenance - CL-stamped artifact + build-info.json =====
Step "4/6" "Provenance - fetch the CL-version-stamped artifact and print build-info.json"
$pkgArtifacts = Invoke-TC GET "/app/rest/builds/id:$($pkg.id)/artifacts/children/"
$tar = @($pkgArtifacts.file) | Where-Object { $_.name -like 'hoops-brawl-cl*.tar.gz' } | Select-Object -First 1
if (-not $tar) { Die "Package build #$($pkg.number) has no hoops-brawl-cl*.tar.gz artifact" }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "capstone-demo-$($pkg.id)"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$tgz = Join-Path $tmp $tar.name
Save-Artifact $pkg.id $tar.name $tgz
& tar -xzf $tgz -C $tmp   # native cmd: $ErrorActionPreference does not catch its exit code
if ($LASTEXITCODE -ne 0) { Die "failed to extract $($tar.name) (corrupt download or tar missing)" }
$biFile = Get-ChildItem $tmp -Recurse -Filter build-info.json | Select-Object -First 1
if (-not $biFile) { Die "no build-info.json inside $($tar.name)" }
$info = Get-Content $biFile.FullName -Raw | ConvertFrom-Json
Info "artifact: $($tar.name)  ($([math]::Round($tar.size/1KB,1)) KB)"
Write-Host ($info | ConvertTo-Json) -ForegroundColor White
# Provenance is headline #1, so a stamp/artifact mismatch must FAIL the self-test (not just warn).
# Guarded on $pkgCl so a missing REST revision degrades to a skip, not a false failure.
if ($pkgCl -and [string]$info.p4_changelist -ne [string]$pkgCl) {
    Die "provenance broken: build-info CL ($($info.p4_changelist)) != build VCS revision ($pkgCl) - stale/mis-stamped artifact"
}
Ok "provenance: CL $($info.p4_changelist) -> build #$($info.teamcity_build_number) -> $($tar.name)"

# ===== [5/6] Track 5 - the real content-addressed cook =====
Step "5/6" "Track 5 - run the real content-addressed cook (Cook Assets, warm-cache)"
$q = Invoke-TC POST "/app/rest/buildQueue" -Body @{ buildType = @{ id = $CookBuildType }; comment = @{ text = "capstone: real cook demo" } }
$cookId = [int]$q.id
Info "queued Cook Assets (build id $cookId); waiting up to ${CookTimeoutSec}s..."
$cook = Wait-BuildFinished $cookId $CookTimeoutSec
if (-not $cook)                 { Die "Cook Assets did not finish within ${CookTimeoutSec}s" }
if ($cook.status -ne 'SUCCESS') { Die "Cook Assets #$($cook.number) finished $($cook.status)" }
# pull the cook-stats artifact down to the host pipeline/.metrics so the dashboard Cook panel sees it
$metricsDir = Join-Path $Repo 'pipeline\.metrics'
New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null
$statName = "cook-$($cook.number).json"
# the cook-stats subdir only exists if the build published it - 404 otherwise. Catch -> clean Die.
try { $kids = Invoke-TC GET "/app/rest/builds/id:$cookId/artifacts/children/cook-stats" }
catch { Die "Cook Assets #$($cook.number) SUCCESS but published no cook-stats artifact (404)" }
if (-not @($kids.file)) { Die "Cook Assets #$($cook.number) cook-stats artifact is empty" }
$picked = (@($kids.file) | Where-Object { $_.name -eq $statName } | Select-Object -First 1)
if (-not $picked) { $picked = @($kids.file) | Select-Object -First 1; $statName = $picked.name }
Save-Artifact $cookId "cook-stats/$statName" (Join-Path $metricsDir $statName)
$stats  = Get-Content (Join-Path $metricsDir $statName) -Raw | ConvertFrom-Json
$cooked = [int]$stats.textures_cooked + [int]$stats.audio_cooked + [int]$stats.characters_cooked
$cached = [int]$stats.textures_cached + [int]$stats.audio_cached + [int]$stats.characters_cached
$warm   = ($cooked -eq 0 -and $cached -gt 0)
if ($warm) {
    Ok ("Cook Assets #$($cook.number) SUCCESS - WARM cache hit: cooked {0}, cached {1}, {2:N0} B ({3})" -f `
        $cooked, $cached, [int]$stats.total_bytes, $statName)
} else {
    # green but cold - the warm-cache headline (#3) is NOT demonstrated this run
    Ok ("Cook Assets #$($cook.number) SUCCESS - cold cook: cooked {0}, cached {1}, {2:N0} B ({3})" -f `
        $cooked, $cached, [int]$stats.total_bytes, $statName)
    Write-Host "  WARN: COLD cache - warm reuse NOT shown this run (needs a prior Cook Assets build); re-run to demonstrate cache hits" -ForegroundColor Yellow
}

# ===== [6/6] Observability - regenerate the dashboard from live feeds =====
Step "6/6" "Observability - regenerate the dashboard so both panels reflect this run"
if ($SkipDashboard) {
    Info "skipped (-SkipDashboard)"
} else {
    & (Join-Path $Repo 'dashboard\scripts\collect-metrics.ps1') -BaseUrl $BaseUrl -Token $Token | Out-Host
    & (Join-Path $Repo 'dashboard\scripts\build-dashboard.ps1') | Out-Host
    $dash = Join-Path $Repo 'dashboard\dashboard.html'
    Ok "dashboard regenerated: $dash"
    Info "CI Builds (Track 2): Package #$($pkg.number) at CL $pkgCl"
    Info "Cook (Track 5): $(if ($warm) { 'warm' } else { 'cold' }), cooked=$cooked cached=$cached"
}

# ===== summary =====
Write-Host "`n================ CAPSTONE DEMO: GREEN ================" -ForegroundColor Green
Write-Host "Point at:" -ForegroundColor Green
Write-Host ("  1. Provenance      CL $($info.p4_changelist) -> build #$($info.teamcity_build_number) -> $($tar.name)")
Write-Host ("  2. Observability   dashboard.html - CI + Cook panels reflect this exact run")
Write-Host ("  3. Content cook    Cook Assets #$($cook.number): {0} (content-addressed CAS)" -f `
    $(if ($warm) { "WARM, cached=$cached" } else { "COLD this run (cooked=$cooked) - re-run to show warm cache hits" }))
Write-Host ("  4. Ephemeral CI    scripted-disposable agent = Slice 2 (stretch); this run used the standing agent")
Write-Host "`nNarrative + per-stage detail: capstone/README.md" -ForegroundColor Gray
