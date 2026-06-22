<#
.SYNOPSIS
  Configure the shared UE DDC so the TeamCity and Horde cooks share one warm cache on the D:\
  NVMe scratch drive (turns a ~24-min cold Lyra cook into ~1 min). Sets UE-SharedDataCachePath
  and creates the folder. Idempotent; -DryRun writes nothing.

.DESCRIPTION
  Both cooks run on this one box (WS01) through the same installed engine, so a single local
  folder on D:\ is genuinely shared between them. UE-SharedDataCachePath overrides the engine's
  Shared DDC node path. Default scope = User (no admin); -Scope Machine needs an elevated shell.

      pwsh -File unreal/scripts/set-shared-ddc.ps1                       # D:\DDC-Shared, User
      pwsh -File unreal/scripts/set-shared-ddc.ps1 -Scope Machine        # all accounts (elevated)
      pwsh -File unreal/scripts/set-shared-ddc.ps1 -DryRun

.NOTES
  Exit 0 on success. A NEW shell (and an agent restart) picks up the var. See unreal/README.md.
#>
[CmdletBinding()]
param(
  [string]$Path = 'D:\DDC-Shared',
  [ValidateSet('User','Machine')][string]$Scope = 'User',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$var = 'UE-SharedDataCachePath'

if ($Path -match '^[Cc]:') {
  throw "Refusing to put the DDC on C: ($Path) - use the D:\ NVMe scratch drive (ROADMAP_NEXT 'Hardware reality')."
}

$current = [Environment]::GetEnvironmentVariable($var, $Scope)
Write-Host "$var ($Scope scope): current=[$current]  ->  target=[$Path]"

if ($DryRun) {
  Write-Host 'DryRun - creating nothing, setting nothing.' -ForegroundColor DarkCyan
  exit 0
}

New-Item -ItemType Directory -Force -Path $Path | Out-Null
[Environment]::SetEnvironmentVariable($var, $Path, $Scope)
Write-Host "OK - $var set to $Path ($Scope). Open a NEW shell (and restart the Horde agent) to pick it up." -ForegroundColor Green
exit 0
