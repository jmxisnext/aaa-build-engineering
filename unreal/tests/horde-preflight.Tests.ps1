$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
. (Join-Path $here "..\scripts\_unreal-common.ps1")
$script = Join-Path $here "..\scripts\horde-preflight.ps1"

# --- pure verdict logic ---
$allPass = @(
  [pscustomobject]@{ Check='a'; Status='PASS'; Detail='' }
  [pscustomobject]@{ Check='b'; Status='WARN'; Detail='' }
)
$v1 = Get-PreflightVerdict -Checks $allPass
Assert-True  $v1.Ready      'no FAIL -> Ready'
Assert-Equal 0 $v1.ExitCode 'no FAIL -> exit 0'
Assert-Equal 1 $v1.Warned   'counts WARN'

$withFail = $allPass + [pscustomobject]@{ Check='c'; Status='FAIL'; Detail='' }
$v2 = Get-PreflightVerdict -Checks $withFail
Assert-True  (-not $v2.Ready) 'a FAIL -> not Ready'
Assert-Equal 1 $v2.ExitCode   'a FAIL -> exit 1'
Assert-Equal 1 $v2.Failed     'counts FAIL'

# --- param contract ---
$cmd = Get-Command $script
foreach ($pn in 'Server','P4Port','AgentRoot','Start','DryRun') {
  Assert-True $cmd.Parameters.ContainsKey($pn) "has -$pn"
}

# --- integration smoke: runs read-only without crashing, prints a check table ---
$out = & pwsh -NoProfile -File $script -DryRun 2>&1
Assert-True ($LASTEXITCODE -in 0,1) 'preflight -DryRun exits 0 or 1 (no crash)'
Assert-Match 'Check' ($out | Out-String) 'prints a check table'

Assert-Summary
