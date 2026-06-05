<#
.SYNOPSIS
  Track 4, rung #5 (CI half): provision the TeamCity build config that runs the Lyra
  BuildGraph and emits a CL-stamped package -- the track's HEADLINE demoable artifact:
  "BuildGraph executed from CI, emitting a Perforce-changelist-stamped Lyra build."

.DESCRIPTION
  Idempotent. Drives the TeamCity REST API to create (under the existing AAASandbox
  project) one build config, AAASandbox_LyraPipeline, that on a WINDOWS agent:
      1. runs unreal/scripts/buildgraph-lyra.ps1   (Compile -> Cook -> Package, the rung #4 graph)
      2. runs unreal/scripts/stamp-lyra-package.ps1 -Changelist %build.vcs.number%  (rung #5 stamp)
  and publishes the package's build-info.json + CL-named sidecar as artifacts.

  WHY A SEPARATE SCRIPT (not folded into bootstrap-builds.ps1): the Lyra pipeline is a
  different animal from the C++ sample chain -- it is one BuildGraph, not a 4-config DAG,
  and it MUST run on a Windows agent with UE 5.6 + VS2022 (the engine lives on G:\). The
  Linux Docker agents physically cannot build it. So this config carries an OS agent
  requirement that pins it to a Windows agent and keeps the two tracks' configs isolated.
  The CSRF-safe Invoke-TC auth pattern is the proven one from bootstrap-builds.ps1 (lesson #10).

  THE WINDOWS AGENT (the partly-manual infra piece): a native TeamCity agent installed on
  this host, which already has UE 5.6 (G:\UnrealEngine\UE_5.6), VS2022, and these repo
  scripts on disk. The Linux compose agents stay for the C++ chain. See ci/README.md
  "Lyra pipeline (Windows agent)".

  VCS root: attaches the existing Perforce stream root (so %build.vcs.number% is a real CL
  from the live broker, same as the C++ chain) but sets checkout mode = MANUAL -- the agent
  does NOT sync the sample stream (it builds Lyra from G:\); it only needs the CL to stamp.
  (In a real Lyra farm the VCS root would be Lyra's own content depot; here the sample
  stream stands in -- the stamp records it as p4_changelist, clearly labeled.)

  Auth: pass -Token, or set $env:TEAMCITY_TOKEN, or let the script scrape the rotating
  superuser token out of teamcity-server.log (same as bootstrap-builds.ps1).

.EXAMPLE
  ./bootstrap-lyra.ps1                # provision against http://localhost:8111
  ./bootstrap-lyra.ps1 -DryRun        # print the planned REST calls, send nothing (no server needed)
  ./bootstrap-lyra.ps1 -Recreate      # drop + recreate the Lyra build config
#>

param(
    [string]$Token,
    [string]$BaseUrl    = "http://localhost:8111",
    [string]$ProjectId  = "AAASandbox",
    [string]$VcsRootId  = "AAASandbox_GameMainStream",   # reuse the C++ chain's stream root for %build.vcs.number%
    [string]$BuildTypeId= "AAASandbox_LyraPipeline",
    # Where the repo (and thus the rung scripts) live on the Windows agent. Default = this
    # repo's root, computed from the script location -- correct for the single-box sandbox
    # where the agent IS this host. A real farm would check the repo out via a git VCS root.
    [string]$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [switch]$Recreate,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------- auth (CSRF-safe; mirrors bootstrap-builds.ps1, lesson #10) ----------

function Get-SuperUserToken {
    $log = docker exec teamcity-server cat /opt/teamcity/logs/teamcity-server.log
    $line = $log | Select-String "Super user authentication token: " | Select-Object -Last 1
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "Could not find a superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}

if (-not $DryRun) {
    if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
    if (-not $Token) { $Token = Get-SuperUserToken }
    $authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
    # One web session; fetch the CSRF token once and send it on every mutating request.
    $csrfToken = Invoke-RestMethod -Uri "$BaseUrl/authenticationTest.html?csrf" `
        -Headers @{ Authorization = $authHeader } -SessionVariable tcSession
}

function Invoke-TC {
    param([string]$Method, [string]$Path, $Body,
          [string]$ContentType = "application/json", [string]$Accept = "application/json")
    if ($DryRun) {
        $shown = if ($null -ne $Body -and $Body -isnot [string]) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $Body }
        Write-Host "  [DRY] $Method $Path" -ForegroundColor DarkCyan
        if ($shown) { Write-Host "        $shown" -ForegroundColor DarkGray }
        return $null
    }
    $reqHeaders = @{ Authorization = $authHeader; Accept = $Accept }
    if ($Method -in @("POST","PUT","DELETE")) { $reqHeaders["X-TC-CSRF-Token"] = $csrfToken }
    $reqParams = @{ Method = $Method; Uri = "$BaseUrl$Path"; Headers = $reqHeaders; WebSession = $tcSession }
    if ($null -ne $Body) {
        $reqParams.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        $reqHeaders["Content-Type"] = $ContentType
    }
    Invoke-RestMethod @reqParams
}

# ---------- REST helpers ----------

function Test-BuildType { param([string]$Id)
    if ($DryRun) { return $false }
    try { Invoke-TC GET "/app/rest/buildTypes/id:$Id" | Out-Null; $true } catch { $false }
}
function Remove-BuildType { param([string]$Id) Invoke-TC DELETE "/app/rest/buildTypes/id:$Id" | Out-Null }
function New-BuildType { param([string]$Id, [string]$Name)
    Invoke-TC POST "/app/rest/buildTypes" -Body @{ id = $Id; name = $Name; project = @{ id = $ProjectId } } | Out-Null
}
function Add-VcsRoot { param([string]$Id)
    Invoke-TC POST "/app/rest/buildTypes/id:$Id/vcs-root-entries" `
        -Body @{ id = $VcsRootId; "vcs-root" = @{ id = $VcsRootId } } | Out-Null
}
# Checkout mode MANUAL = agent does NOT auto-sync the VCS root; %build.vcs.number% still
# populates server-side. Keeps the Windows agent free of a p4 sync it does not need.
function Set-CheckoutMode { param([string]$Id, [string]$Mode = "MANUAL")
    Invoke-TC PUT "/app/rest/buildTypes/id:$Id/settings/checkoutMode" -Body $Mode -ContentType "text/plain" -Accept "text/plain" | Out-Null
}
function Add-Parameter { param([string]$Id, [string]$Name, [string]$Value)
    Invoke-TC POST "/app/rest/buildTypes/id:$Id/parameters" -Body @{ name = $Name; value = $Value } | Out-Null
}
# PowerShell (Core / pwsh) runner, inline CODE mode -- no dependency on an agent checkout of
# the repo; the script cd's to %repo.root% (the scripts already on the Windows host).
function Add-PowerShellStep { param([string]$Id, [string]$Name, [string]$Code)
    $body = @{
        type = "jetbrains_powershell"
        name = $Name
        properties = @{ property = @(
            @{ name = "jetbrains_powershell_edition";     value = "Core" }      # pwsh 7, not Windows PowerShell
            @{ name = "jetbrains_powershell_bitness";     value = "x64" }
            @{ name = "jetbrains_powershell_script_mode"; value = "CODE" }
            @{ name = "jetbrains_powershell_script_code"; value = $Code }
            @{ name = "jetbrains_powershell_noprofile";   value = "true" }
            @{ name = "teamcity.step.mode";               value = "default" }
        )}
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$Id/steps" -Body $body | Out-Null
}
# Pin to a Windows agent. The Linux compose agents report os.name "Linux ..." and are
# excluded; the native Windows agent reports "Windows 11"/"Windows Server ...".
function Add-AgentRequirement { param([string]$Id, [string]$PropName, [string]$Value, [string]$Condition = "contains")
    $body = @{
        type = $Condition
        properties = @{ property = @(
            @{ name = "property-name";  value = $PropName }
            @{ name = "property-value"; value = $Value }
        )}
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$Id/agent-requirements" -Body $body | Out-Null
}
function Set-ArtifactRules { param([string]$Id, [string]$Rules)
    Invoke-TC PUT "/app/rest/buildTypes/id:$Id/settings/artifactRules" -Body $Rules -ContentType "text/plain" -Accept "text/plain" | Out-Null
}

# ---------- the build step ----------
#
# Run as child pwsh processes (-File) so each wrapper's own `exit` reports a clean
# step exit code instead of terminating this outer runner mid-way. %build.vcs.number%
# is the live P4 CL; if it is empty (no VCS changes yet) the stamp falls back to the
# engine CL -- the script handles the empty string. Win64 stages to <Archive>\Windows.
$stepCode = @'
$ErrorActionPreference = 'Stop'
Set-Location '%repo.root%'
Write-Host "== BuildGraph (compile -> cook -> package) =="
pwsh -File unreal/scripts/buildgraph-lyra.ps1
if ($LASTEXITCODE -ne 0) { Write-Host "BuildGraph failed ($LASTEXITCODE)"; exit $LASTEXITCODE }
Write-Host "== Version-stamp the package with the P4 changelist =="
# One line, no backtick continuation: in TeamCity's PowerShell step the multi-line
# backtick-continued invocation silently did not execute (the step exited 0 right after
# the header above, stamp never ran). The single-line BuildGraph call worked. Keep CI
# inline-step commands on one line. See ci/lessons-learned.md #13.
pwsh -File unreal/scripts/stamp-lyra-package.ps1 -Changelist '%build.vcs.number%' -BuildNumber '%build.number%' -BuildId '%teamcity.build.id%' -Source teamcity
exit $LASTEXITCODE
'@

# ---------- apply ----------

Write-Host "TeamCity Lyra bootstrap at $BaseUrl$(if($DryRun){'  (DRY RUN - sending nothing)'})" -ForegroundColor Cyan
Write-Host "Project: $ProjectId | Build: $BuildTypeId | RepoRoot (agent): $RepoRoot" -ForegroundColor Cyan
Write-Host ""

if ($Recreate -and (Test-BuildType -Id $BuildTypeId)) {
    Write-Host "[delete] $BuildTypeId" -ForegroundColor Yellow
    Remove-BuildType -Id $BuildTypeId
}

if (Test-BuildType -Id $BuildTypeId) {
    Write-Host "[skip]   $BuildTypeId (already exists -- use -Recreate to redo)" -ForegroundColor DarkGray
    return
}

Write-Host "[create] $BuildTypeId (Lyra Pipeline)" -ForegroundColor Green
New-BuildType -Id $BuildTypeId -Name "Lyra Pipeline"
Add-VcsRoot          -Id $BuildTypeId
Set-CheckoutMode     -Id $BuildTypeId -Mode "MANUAL"
Add-Parameter        -Id $BuildTypeId -Name "repo.root" -Value $RepoRoot
Add-PowerShellStep   -Id $BuildTypeId -Name "BuildGraph + CL stamp" -Code $stepCode
Add-AgentRequirement -Id $BuildTypeId -PropName "teamcity.agent.jvm.os.name" -Value "Windows" -Condition "contains"
# Publish the provenance: the in-package stamp + the CL-named sidecar.
Set-ArtifactRules    -Id $BuildTypeId -Rules "+:D:/LyraPackaged/Windows/build-info.json`n+:D:/LyraPackaged/Lyra-*CL*.buildinfo.json"

Write-Host ""
Write-Host "Done. View the config at:" -ForegroundColor Cyan
Write-Host "  $BaseUrl/buildConfiguration/$BuildTypeId"
if ($DryRun) { Write-Host ""; Write-Host "DRY RUN complete - no REST calls were sent." -ForegroundColor Yellow }
