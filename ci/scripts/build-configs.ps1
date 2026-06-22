<#
.SYNOPSIS
  The declarative AAA Sandbox build-chain config (no REST, no side effects).
  Dot-sourced by bootstrap-builds.ps1 and unit-tested by ci/tests/build-configs.Tests.ps1.
#>
function Get-SandboxBuildConfigs {
    param([string]$VersionStampScript)
    @(
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
                @{ Name = "version stamp"; Script = $VersionStampScript }
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
        @{
            Id            = "AAASandbox_CookAssets"
            Name          = "Cook Assets"
            # Standalone: the real cooker is pure Python+Pillow (in the agent image),
            # so it needs no C++ Compile. The self artifact-dep (WarmCacheArtifact)
            # restores the prior build's CAS into pipeline/cooked before this runs.
            Steps         = @(
                @{ Name = "cook (warm-cacheable)"; Script = @'
set -e
# WARM=1 iff a prior CAS was restored by the artifact dependency (index present + non-empty).
WARM=0; [ -s pipeline/cooked/.cookindex.json ] && WARM=1
python3 pipeline/scripts/make-samples.py
python3 pipeline/cook.py --pack Cooked-assets.pak --stats-json pipeline/.metrics/cook-%build.number%.json
if [ "$WARM" = "1" ]; then
  CACHED=$(python3 -c "import json;d=json.load(open('pipeline/.metrics/cook-%build.number%.json'));print(d['textures_cached']+d['audio_cached']+d['characters_cached'])")
  echo "warm build: cached=$CACHED"
  [ "$CACHED" -gt 0 ] || { echo 'FAIL: warm build recooked everything - the cache index did not survive the artifact round-trip'; exit 1; }
else
  echo "cold build (no prior CAS restored) - warm-cache guard skipped"
fi
'@ }
            )
            SnapshotDeps  = @()
            ArtifactDeps  = @()
            # Self artifact-dependency: restore THIS config's last successful CAS.
            WarmCacheArtifact = @{ PathRules = "cooked.zip!** => pipeline/cooked" }
            # Clean checkout: wipe the agent checkout dir before each build so pipeline/cooked/
            # comes ONLY from the self artifact-dependency (not stale same-agent residue). TeamCity
            # resolves artifact deps AFTER checkout, so the restored CAS survives. (final-review IMPORTANT)
            CleanCheckout = $true
            # Directory-form publish so the .cookindex.json DOTFILE is archived (spec §6).
            ArtifactRules = "+:pipeline/cooked => cooked.zip`n+:Cooked-assets.pak`n+:pipeline/.metrics/cook-*.json => cook-stats"
        }
    )
}
