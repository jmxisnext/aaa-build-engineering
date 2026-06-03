# Deploy trigger scripts to the path p4d reads from.
# In a real shop this would be a step in a CI job that owns //spec/triggers/.

$ErrorActionPreference = "Stop"

$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DstDir = "C:\PerforceSandbox\triggers"

if (-not (Test-Path $DstDir)) {
    New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
}

Get-ChildItem $SrcDir -File -Filter "*.py" | ForEach-Object {
    $dst = Join-Path $DstDir $_.Name
    Copy-Item -Path $_.FullName -Destination $dst -Force
    Write-Output "deployed: $($_.Name) -> $dst"
}
