$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
$script = Join-Path $here "..\scripts\set-shared-ddc.ps1"

# --- param contract ---
$cmd = Get-Command $script
Assert-True $cmd.Parameters.ContainsKey('Path')   'has -Path'
Assert-True $cmd.Parameters.ContainsKey('Scope')  'has -Scope'
Assert-True $cmd.Parameters.ContainsKey('DryRun') 'has -DryRun'
$scopeSet = ($cmd.Parameters['Scope'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
Assert-True ($scopeSet -contains 'User')    '-Scope allows User'
Assert-True ($scopeSet -contains 'Machine') '-Scope allows Machine'

# --- -DryRun writes nothing: the real env var is unchanged ---
$before = [Environment]::GetEnvironmentVariable('UE-SharedDataCachePath','User')
$out = & pwsh -NoProfile -File $script -Path 'D:\DDC-Shared' -DryRun 2>&1
Assert-Equal 0 $LASTEXITCODE 'set-shared-ddc -DryRun exits 0'
Assert-Match 'UE-SharedDataCachePath' ($out | Out-String) 'DryRun mentions the env var'
$after = [Environment]::GetEnvironmentVariable('UE-SharedDataCachePath','User')
Assert-Equal "$before" "$after" 'DryRun did NOT change the real env var'

# --- refuses a C: DDC path ---
$null = & pwsh -NoProfile -File $script -Path 'C:\DDC' -DryRun 2>&1
Assert-True ($LASTEXITCODE -ne 0) 'refuses a C: DDC path (non-zero exit)'

Assert-Summary
