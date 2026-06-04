# Deploy trigger scripts to the path p4d reads from.
# In a real shop this would be a step in a CI job that owns //spec/triggers/.
#
# Deploys the policy triggers (*.py) and the instant-CI hook
# (notify-teamcity.ps1). deploy.ps1 itself is not a trigger, so it is excluded.

$ErrorActionPreference = "Stop"

$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DstDir = "C:\PerforceSandbox\triggers"

if (-not (Test-Path $DstDir)) {
    New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
}

Get-ChildItem $SrcDir -File |
    Where-Object { ($_.Extension -eq ".py") -or ($_.Name -eq "notify-teamcity.ps1") } |
    ForEach-Object {
        $dst = Join-Path $DstDir $_.Name
        Copy-Item -Path $_.FullName -Destination $dst -Force
        Write-Output "deployed: $($_.Name) -> $dst"
    }
