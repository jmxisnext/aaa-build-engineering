# Deploy trigger scripts to the path p4d reads from.
# In a real shop this would be a step in a CI job that owns //spec/triggers/.
#
# Deploys every trigger script in this dir (*.py policy triggers + *.ps1 hooks),
# excluding deploy.ps1 itself — it is the deployer, not a trigger.

$ErrorActionPreference = "Stop"

$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DstDir = "C:\PerforceSandbox\triggers"

if (-not (Test-Path $DstDir)) {
    New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
}

Get-ChildItem $SrcDir -File |
    Where-Object { ($_.Extension -in ".py", ".ps1") -and ($_.Name -ne "deploy.ps1") } |
    ForEach-Object {
        $dst = Join-Path $DstDir $_.Name
        Copy-Item -Path $_.FullName -Destination $dst -Force
        Write-Output "deployed: $($_.Name) -> $dst"
    }
