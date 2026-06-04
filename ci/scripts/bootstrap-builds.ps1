<#
.SYNOPSIS
  Bootstrap the AAA Sandbox build chain in TeamCity (idempotent).

.DESCRIPTION
  Drives the TeamCity REST API to create the AAASandbox project, the
  Game Main Stream Perforce VCS root, and four chained build
  configurations attached to that root — from scratch, so a wiped
  server (docker compose down -v) rebuilds with no manual UI step.

  Re-runnable: the project, VCS root, and each build config are
  skipped if they already exist. Use -Recreate to wipe and redo the
  VCS root + build configs (drops run history); the project is left
  intact (a from-scratch project is exercised by down -v, not -Recreate).

  Chain shape (a DAG, not a strict line — Smoke Test and Cook Data
  parallelize once Compile is done):

      Compile ──┬─> Smoke Test ─┐
                └─> Cook Data ──┴─> Package

  Auth: pass -Token, or set $env:TEAMCITY_TOKEN, or let the script
  scrape the current superuser token out of teamcity-server.log.
  The superuser token rotates every server restart, which is why
  log-scrape is the default — it just works as long as the server
  is up.

.EXAMPLE
  ./bootstrap-builds.ps1
  ./bootstrap-builds.ps1 -Recreate
#>

param(
    [string]$Token,
    [string]$BaseUrl   = "http://localhost:8111",
    [string]$ProjectId = "AAASandbox",
    [string]$VcsRootId = "AAASandbox_GameMainStream",
    [switch]$Recreate
)

$ErrorActionPreference = "Stop"

# ---------- auth ----------

function Get-SuperUserToken {
    $log = docker exec teamcity-server cat /opt/teamcity/logs/teamcity-server.log
    $line = $log | Select-String "Super user authentication token: " | Select-Object -Last 1
    if ($line -match "token: (\d+)") {
        return $matches[1]
    }
    throw "Could not find a superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}

if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }

$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))

# TeamCity 2026.x rejects session-authenticated *writes* (POST/PUT/DELETE) that
# carry no CSRF token — HTTP 403 "failed CSRF check". (Latent before: a re-run
# against an already-built server only does GETs, which are exempt; it only bites
# the from-scratch create path.) Fix: open one web session, fetch the CSRF token
# once from /authenticationTest.html?csrf, and send it as X-TC-CSRF-Token on every
# mutating request. GETs don't need it but ride the same session. (lesson #10)
$csrfToken = Invoke-RestMethod -Uri "$BaseUrl/authenticationTest.html?csrf" `
    -Headers @{ Authorization = $authHeader } -SessionVariable tcSession

# ---------- REST helpers ----------

function Invoke-TC {
    param(
        [string]$Method,
        [string]$Path,
        $Body,
        [string]$ContentType = "application/json",
        [string]$Accept      = "application/json"
    )
    # Put every header on the same hashtable. PowerShell's
    # -ContentType param sometimes overrides Accept when both are
    # specified separately, which the TeamCity API rejects as 406.
    #
    # Accept must match the endpoint's response content-type — most
    # endpoints return JSON, but PUT /settings/artifactRules returns
    # text/plain and rejects Accept: application/json with 406.
    $reqHeaders = @{
        Authorization = $authHeader
        Accept        = $Accept
    }
    # CSRF token required on writes (see note above); harmless on GETs.
    if ($Method -in @("POST", "PUT", "DELETE")) {
        $reqHeaders["X-TC-CSRF-Token"] = $csrfToken
    }
    $reqParams = @{
        Method     = $Method
        Uri        = "$BaseUrl$Path"
        Headers    = $reqHeaders
        WebSession = $tcSession
    }
    if ($null -ne $Body) {
        $reqParams.Body = if ($Body -is [string]) {
            $Body
        } else {
            $Body | ConvertTo-Json -Depth 10 -Compress
        }
        $reqHeaders["Content-Type"] = $ContentType
    }
    Invoke-RestMethod @reqParams
}

function Test-BuildType {
    param([string]$Id)
    try { Invoke-TC GET "/app/rest/buildTypes/id:$Id" | Out-Null; $true }
    catch { $false }
}

function Remove-BuildType {
    param([string]$Id)
    Invoke-TC DELETE "/app/rest/buildTypes/id:$Id" | Out-Null
}

function New-BuildType {
    param([string]$Id, [string]$Name)
    $body = @{
        id      = $Id
        name    = $Name
        project = @{ id = $ProjectId }
    }
    Invoke-TC POST "/app/rest/buildTypes" -Body $body | Out-Null
}

function Add-VcsRoot {
    param([string]$BuildTypeId)
    $body = @{
        id         = $VcsRootId
        "vcs-root" = @{ id = $VcsRootId }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/vcs-root-entries" -Body $body | Out-Null
}

function Test-Project {
    param([string]$Id)
    try { Invoke-TC GET "/app/rest/projects/id:$Id" | Out-Null; $true }
    catch { $false }
}

function Test-VcsRoot {
    param([string]$Id)
    try { Invoke-TC GET "/app/rest/vcs-roots/id:$Id" | Out-Null; $true }
    catch { $false }
}

function Remove-VcsRoot {
    param([string]$Id)
    Invoke-TC DELETE "/app/rest/vcs-roots/id:$Id" | Out-Null
}

# Create the project the chain lives under. Skip-if-exists. The project is the
# most upstream dependency: build types and the VCS root are both project-scoped,
# so this must run first. Body shape verified live (parentProject locator _Root).
function Ensure-Project {
    if (Test-Project -Id $ProjectId) {
        Write-Host "[skip]   project $ProjectId (already exists)" -ForegroundColor DarkGray
        return
    }
    Write-Host "[create] project $ProjectId" -ForegroundColor Green
    $body = @{ name = "AAA Sandbox"; id = $ProjectId; parentProject = @{ locator = "_Root" } }
    Invoke-TC POST "/app/rest/projects" -Body $body | Out-Null
}

# Create the Perforce VCS root definition (NOT the per-build-type attachment, which
# Add-VcsRoot does). Skip-if-exists. Body is the live-verified, zero-diff-probed shape:
# stream mode (use-client=stream, stream=//game/main), project-scoped, six properties.
# workspace-options is column-16-aligned with spaces (PadRight 16), LF-joined — matching
# the captured live root exactly.
function Ensure-VcsRootDefinition {
    if (Test-VcsRoot -Id $VcsRootId) {
        Write-Host "[skip]   vcs-root $VcsRootId (already exists)" -ForegroundColor DarkGray
        return
    }
    Write-Host "[create] vcs-root $VcsRootId" -ForegroundColor Green
    $workspaceOptions =
        ("Options:".PadRight(16)       + "noallwrite clobber nocompress unlocked nomodtime rmdir") + "`n" +
        ("Host:".PadRight(16)          + "%teamcity.agent.hostname%")                               + "`n" +
        ("SubmitOptions:".PadRight(16) + "revertunchanged")                                         + "`n" +
        ("LineEnd:".PadRight(16)       + "local")
    $body = @{
        id      = $VcsRootId
        name    = "Game Main Stream"
        vcsName = "perforce"
        project = @{ id = $ProjectId }
        properties = @{ property = @(
            @{ name = "port";              value = "host.docker.internal:1667" }
            @{ name = "user";              value = "james" }
            @{ name = "use-client";        value = "stream" }
            @{ name = "stream";            value = "//game/main" }
            @{ name = "p4-exe";            value = "p4" }
            @{ name = "workspace-options"; value = $workspaceOptions }
        )}
    }
    Invoke-TC POST "/app/rest/vcs-roots" -Body $body | Out-Null
}

function Add-Step {
    param([string]$BuildTypeId, [string]$Name, [string]$Script)
    $body = @{
        type       = "simpleRunner"
        name       = $Name
        properties = @{
            property = @(
                @{ name = "script.content";     value = $Script },
                @{ name = "teamcity.step.mode"; value = "default" },
                @{ name = "use.custom.script";  value = "true" }
            )
        }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/steps" -Body $body | Out-Null
}

function Add-SnapshotDep {
    param([string]$BuildTypeId, [string]$UpstreamId)
    $body = @{
        type               = "snapshot_dependency"
        "source-buildType" = @{ id = $UpstreamId }
        properties         = @{
            property = @(
                @{ name = "run-build-if-dependency-failed";   value = "MAKE_FAILED_TO_START" },
                @{ name = "run-build-on-the-same-agent";       value = "false" },
                @{ name = "take-started-build-with-same-revisions"; value = "true" },
                @{ name = "take-successful-builds-only";       value = "true" }
            )
        }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/snapshot-dependencies" -Body $body | Out-Null
}

function Add-ArtifactDep {
    param([string]$BuildTypeId, [string]$UpstreamId, [string]$PathRules)
    $body = @{
        type               = "artifact_dependency"
        "source-buildType" = @{ id = $UpstreamId }
        properties         = @{
            property = @(
                @{ name = "pathRules";                value = $PathRules },
                @{ name = "revisionName";             value = "sameChainOrLastFinished" },
                @{ name = "revisionValue";            value = "latest.sameChainOrLastFinished" },
                @{ name = "cleanDestinationDirectory"; value = "false" }
            )
        }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/artifact-dependencies" -Body $body | Out-Null
}

function Set-ArtifactRules {
    param([string]$BuildTypeId, [string]$Rules)
    Invoke-TC PUT "/app/rest/buildTypes/id:$BuildTypeId/settings/artifactRules" `
        -Body $Rules -ContentType "text/plain" -Accept "text/plain" | Out-Null
}

# ---------- declarative config ----------
#
# Order matters: configs are created top-to-bottom and each may
# reference upstream IDs declared above it.

# Version-stamp step for Package: write the build's provenance into the staged
# tree so the shipped artifact self-reports which P4 changelist it was built from.
# TeamCity substitutes %build.vcs.number% (= the Perforce changelist for the
# stream VCS root), %build.number%, and %teamcity.build.id% before the agent runs
# this. NOTE the doubled %% in the date format: TeamCity treats a single % as the
# start of a parameter reference, so a bare `date +%Y...` would be mangled into a
# bogus %Y...% lookup — `%%` is the documented escape for a literal % (lesson #11).
$versionStampScript = @'
mkdir -p dist
cat > dist/build-info.json <<EOF
{
  "project": "hoops-brawl",
  "p4_changelist": "%build.vcs.number%",
  "teamcity_build_number": "%build.number%",
  "teamcity_build_id": "%teamcity.build.id%",
  "built_at_utc": "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)",
  "chain": "Compile -> SmokeTest||CookData -> Package"
}
EOF
echo "---- build-info.json (P4 changelist stamp) ----"
cat dist/build-info.json
'@

$configs = @(
    @{
        Id            = "AAASandbox_Compile"
        Name          = "Compile"
        Steps         = @(
            @{ Name = "cmake configure"; Script = "cmake -B build -S . -DCMAKE_BUILD_TYPE=Release" }
            @{ Name = "cmake build";     Script = "cmake --build build --parallel" }
        )
        SnapshotDeps  = @()
        ArtifactDeps  = @()
        ArtifactRules = "+:build => build.zip"
    }
    @{
        Id            = "AAASandbox_SmokeTest"
        Name          = "Smoke Test"
        Steps         = @(
            @{ Name = "ctest"; Script = "ctest --test-dir build --output-on-failure" }
        )
        SnapshotDeps  = @("AAASandbox_Compile")
        ArtifactDeps  = @(
            @{ UpstreamId = "AAASandbox_Compile"; PathRules = "build.zip!** => build" }
        )
        ArtifactRules = ""
    }
    @{
        Id            = "AAASandbox_CookData"
        Name          = "Cook Data"
        Steps         = @(
            @{ Name = "cook"; Script = "build/Tools/Cooker/hoops_cooker Data Cooked.pak" }
        )
        SnapshotDeps  = @("AAASandbox_Compile")
        ArtifactDeps  = @(
            @{ UpstreamId = "AAASandbox_Compile"; PathRules = "build.zip!** => build" }
        )
        ArtifactRules = "+:Cooked.pak"
    }
    @{
        Id            = "AAASandbox_Package"
        Name          = "Package"
        Steps         = @(
            @{ Name = "stage";         Script = "cmake --install build --prefix dist" }
            @{ Name = "bundle pak";    Script = "cp Cooked.pak dist/Cooked.pak" }
            @{ Name = "version stamp"; Script = $versionStampScript }
            # rm stale tarballs first: the agent reuses its checkout dir across builds,
            # so a previous build's hoops-brawl-cl<N>.tar.gz would otherwise linger and
            # get swept up by the glob artifact rule (published two tarballs once). (lesson #12)
            @{ Name = "tarball";       Script = "rm -f hoops-brawl-cl*.tar.gz; tar czf hoops-brawl-cl%build.vcs.number%.tar.gz dist" }
        )
        SnapshotDeps  = @("AAASandbox_SmokeTest", "AAASandbox_CookData")
        ArtifactDeps  = @(
            @{ UpstreamId = "AAASandbox_Compile";  PathRules = "build.zip!** => build" }
            @{ UpstreamId = "AAASandbox_CookData"; PathRules = "Cooked.pak" }
        )
        # glob so the changelist-stamped tarball name (hoops-brawl-cl<N>.tar.gz) is captured
        ArtifactRules = "+:hoops-brawl-cl*.tar.gz"
    }
)

# ---------- apply ----------

Write-Host "TeamCity bootstrap at $BaseUrl" -ForegroundColor Cyan
Write-Host "Project: $ProjectId | VCS root: $VcsRootId" -ForegroundColor Cyan
Write-Host ""

# -Recreate teardown, in reverse-dependency order so nothing is deleted while it
# is still referenced: build types first (they hold the vcs-root-entry attachment),
# then the VCS root (now unreferenced — DELETE is safe without relying on TeamCity's
# cascade-on-delete behavior). The project is a container we never tear down here;
# a from-scratch project is exercised by `docker compose down -v`, not by -Recreate.
if ($Recreate) {
    foreach ($cfg in $configs) {
        if (Test-BuildType -Id $cfg.Id) {
            Write-Host "[delete] $($cfg.Id)" -ForegroundColor Yellow
            Remove-BuildType -Id $cfg.Id
        }
    }
    if (Test-VcsRoot -Id $VcsRootId) {
        Write-Host "[delete] vcs-root $VcsRootId" -ForegroundColor Yellow
        Remove-VcsRoot -Id $VcsRootId
    }
}

# Create the chain's dependencies in order, before the loop attaches the root.
Ensure-Project
Ensure-VcsRootDefinition

foreach ($cfg in $configs) {
    $id = $cfg.Id

    if (Test-BuildType -Id $id) {
        Write-Host "[skip]   $id (already exists)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "[create] $id  ($($cfg.Name))" -ForegroundColor Green
    New-BuildType -Id $id -Name $cfg.Name
    Add-VcsRoot   -BuildTypeId $id

    foreach ($step in $cfg.Steps) {
        Add-Step -BuildTypeId $id -Name $step.Name -Script $step.Script
    }
    foreach ($upstream in $cfg.SnapshotDeps) {
        Add-SnapshotDep -BuildTypeId $id -UpstreamId $upstream
    }
    foreach ($ad in $cfg.ArtifactDeps) {
        Add-ArtifactDep -BuildTypeId $id -UpstreamId $ad.UpstreamId -PathRules $ad.PathRules
    }
    if ($cfg.ArtifactRules) {
        Set-ArtifactRules -BuildTypeId $id -Rules $cfg.ArtifactRules
    }
}

Write-Host ""
Write-Host "Done. View the chain at:" -ForegroundColor Cyan
Write-Host "  $BaseUrl/project.html?projectId=$ProjectId"
