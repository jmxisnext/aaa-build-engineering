<#
.SYNOPSIS
  Vendor the bgfx / bx / bimg source trees so Track 3 can benchmark a *real,
  recognizable* C++ codebase (bgfx's examples/common) instead of the synthetic
  32-TU regex fixture. The "workload tier injection #1" from ROADMAP_NEXT.md.

.DESCRIPTION
  Shallow-clones the three sibling repos bgfx expects -- bx (base library),
  bimg (image library), bgfx (renderer) -- into accel/extern/ (gitignored, same
  treatment as the vendored FBuild.exe: re-downloadable, not committed). Records
  the resolved commit SHAs + clone date into a committable lockfile so the
  before/after numbers are reproducible against a known revision.

  Why three repos: examples/common/*.cpp #include <bx/...>, <bimg/...> and pull
  bgfx/3rdparty (dear imgui, nanovg, stb). bgfx's own build expects ../bx and
  ../bimg as siblings; we replicate that layout under extern/.

  Idempotent: an already-cloned repo is left as-is (and its SHA reported) unless
  -Force re-clones it. Network + git required.

  WHY THESE PINS (not master): on 2025-05-26 (bx commit 5a20afe) bx raised its
  minimum toolchain to MSVC 19.35 / Visual Studio 2022 17.5 and C++20. This build
  agent has VS2019 Build Tools (MSVC 19.29) -- the same cl the rest of Track 3
  uses. Rather than install VS2022 (a machine-altering detour) or switch the
  workload to clang-cl (which would break the /MP + unity story this track is
  about), the triple is pinned to the last revision before that bump:

      bx   d4096a8 (2025-04-26)  requires MSVC >= 19.27 (VS2019 16.7) + C++17
      bgfx 0e73452 (2025-04-12)
      bimg 446b9eb (2025-03-07)

  This keeps the ENTIRE track on one toolchain (MSVC cl /std:c++17), so the real
  bgfx numbers are apples-to-apples with the synthetic-fixture numbers -- and
  pinning the workload to match the installed toolchain is the reproducibility
  discipline the track preaches. Pass -BgfxRef/-BxRef/-BimgRef master (or any
  sha) to override; building master needs VS2022 17.5+.

  Usage:
    pwsh -File .\accel\scripts\setup-bgfx.ps1            # pinned VS2019-buildable triple
    pwsh -File .\accel\scripts\setup-bgfx.ps1 -Force     # wipe + re-clone the pins
    pwsh -File .\accel\scripts\setup-bgfx.ps1 -BgfxRef master -BxRef master -BimgRef master
#>
param(
    [string]$BgfxRef = "0e734522cd8fafa29c8035cbde671ecec62668a3",
    [string]$BxRef   = "d4096a84464605e8fb11e5ffa2d851e42eecffb3",
    [string]$BimgRef = "446b9eb11130821fd11607c2fc94aee80976e56a",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$accel    = (Resolve-Path (Join-Path $here "..")).Path
$extern   = Join-Path $accel "extern"
$lockFile = Join-Path $accel "samples\bgfx\vendored.lock.json"
New-Item -ItemType Directory -Force -Path $extern | Out-Null

# bx / bimg are listed BEFORE bgfx so the sibling deps exist first.
$repos = @(
    @{ Name = "bx";   Url = "https://github.com/bkaradzic/bx.git";   Ref = $BxRef },
    @{ Name = "bimg"; Url = "https://github.com/bkaradzic/bimg.git"; Ref = $BimgRef },
    @{ Name = "bgfx"; Url = "https://github.com/bkaradzic/bgfx.git"; Ref = $BgfxRef }
)

function Clone-Repo($repo) {
    $dest = Join-Path $extern $repo.Name
    if ((Test-Path $dest) -and -not $Force) {
        $sha = (& git -C $dest rev-parse HEAD).Trim()
        Write-Host ("  {0,-5} already present @ {1} (use -Force to re-clone)" -f $repo.Name, $sha.Substring(0,12))
        return $sha
    }
    if (Test-Path $dest) {
        Write-Host ("  {0,-5} -Force: removing existing clone" -f $repo.Name)
        Remove-Item -Recurse -Force $dest
    }
    Write-Host ("  {0,-5} cloning {1} @ {2} ..." -f $repo.Name, $repo.Url, $repo.Ref)
    # Shallow, single-branch: we only need a working tree at one revision, not
    # history. --depth 1 keeps the (large, 3rdparty-heavy) trees download small.
    & git clone --depth 1 --branch $repo.Ref --single-branch $repo.Url $dest 2>&1 |
        Where-Object { $_ -match 'Receiving|Resolving|done\.|Cloning' } | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        # --branch fails when Ref is a raw SHA; fall back to init+fetch-by-sha.
        Write-Host "    (branch clone failed -- retrying as fetch-by-revision)"
        Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        & git -C $dest init -q
        & git -C $dest remote add origin $repo.Url
        & git -C $dest fetch -q --depth 1 origin $repo.Ref
        if ($LASTEXITCODE -ne 0) { throw "fetch $($repo.Name)@$($repo.Ref) failed" }
        & git -C $dest checkout -q FETCH_HEAD
        if ($LASTEXITCODE -ne 0) { throw "checkout $($repo.Name)@$($repo.Ref) failed" }
    }
    $sha = (& git -C $dest rev-parse HEAD).Trim()
    Write-Host ("  {0,-5} OK @ {1}" -f $repo.Name, $sha.Substring(0,12))
    return $sha
}

Write-Host "`nVendoring bgfx workload tier into $extern`n"
$resolved = [ordered]@{}
foreach ($r in $repos) { $resolved[$r.Name] = @{ url = $r.Url; ref = $r.Ref; sha = (Clone-Repo $r) } }

# Lockfile: small, committable, makes the benchmark reproducible to known SHAs.
$lock = [ordered]@{
    note    = "Vendored bgfx workload for accel Track 3. Re-create with setup-bgfx.ps1. Sources gitignored."
    clonedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    repos   = $resolved
}
New-Item -ItemType Directory -Force -Path (Split-Path $lockFile) | Out-Null
$lock | ConvertTo-Json -Depth 5 | Set-Content -Path $lockFile -Encoding ascii
Write-Host "`nWrote lockfile: $lockFile"

# Quick layout sanity -- the dirs bench-bgfx.ps1 will reference.
$common = Join-Path $extern "bgfx\examples\common"
$nTU = if (Test-Path $common) { (Get-ChildItem $common -Recurse -Filter *.cpp).Count } else { 0 }
Write-Host ("examples/common present: {0} ({1} .cpp under it)" -f (Test-Path $common), $nTU)
Write-Host "Done. Next: pwsh -File .\accel\scripts\bench-bgfx.ps1`n"
