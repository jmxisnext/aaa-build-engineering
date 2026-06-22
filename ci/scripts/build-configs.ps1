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
                @{ Name = "tarball";       Script = "rm -f hoops-brawl-cl*.tar.gz; tar czf hoops-brawl-cl%build.vcs.number%.tar.gz dist" }
            )
            SnapshotDeps  = @("AAASandbox_SmokeTest", "AAASandbox_CookData")
            ArtifactDeps  = @(
                @{ UpstreamId = "AAASandbox_Compile";  PathRules = "build.zip!** => build" }
                @{ UpstreamId = "AAASandbox_CookData"; PathRules = "Cooked.pak" }
            )
            ArtifactRules = "+:hoops-brawl-cl*.tar.gz"
        }
    )
}
