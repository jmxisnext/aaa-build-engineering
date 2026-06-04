<#
.SYNOPSIS
  Shared Track-4 discovery helpers: locate the installed UE5 engine and the Lyra
  project. Dot-sourced by check-prereqs.ps1, compile-lyra.ps1, and the later
  cook/package/BuildGraph scripts so this logic lives in exactly one place
  (a fourth copy is how detection drifts - cf. perforce lessons-learned).
#>

function Find-UnrealEngine {
  [CmdletBinding()] param([string]$EnginePath)
  if ($EnginePath) { return $EnginePath }
  # canonical source: the Epic launcher manifest lists every installed engine
  $manifest = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
  if (Test-Path $manifest) {
    try {
      $items = (Get-Content $manifest -Raw | ConvertFrom-Json).InstallationList
      $eng = $items | Where-Object { $_.AppName -like 'UE_5.*' } |
             Sort-Object AppName -Descending | Select-Object -First 1
      if ($eng) { return $eng.InstallLocation }
    } catch { }
  }
  return $null
}

function Find-LyraUproject {
  [CmdletBinding()] param([string]$Uproject)
  if ($Uproject) { return $Uproject }
  # 'Create Project' sample projects are NOT in the launcher manifest - scan the
  # usual project roots. Sample folder is 'LyraStarterGame', project is 'Lyra.uproject'.
  $roots = @(
    'G:\UnrealProjects', 'G:\Unreal Projects',
    (Join-Path $env:USERPROFILE 'Documents\Unreal Projects'),
    'D:\UnrealProjects', 'G:\', 'D:\'
  ) | Where-Object { Test-Path $_ }
  foreach ($root in $roots) {
    $u = Get-ChildItem -Path $root -Filter 'Lyra*.uproject' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($u) { return $u.FullName }
  }
  return $null
}
