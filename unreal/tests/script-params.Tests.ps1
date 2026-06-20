# Param-contract tests: assert the new -Source / -Orchestrator surface on the three scripts
# WITHOUT executing their bodies (Get-Command parses the param block only). Engine-independent.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
$scripts = Join-Path $here "..\scripts"

function Get-ValidSet { param($Cmd, $Param)
  $attr = $Cmd.Parameters[$Param].Attributes |
          Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
          Select-Object -First 1
  if ($attr) { return @($attr.ValidValues) } else { return @() }
}

# ---- stamp-lyra-package.ps1: -Source ValidateSet widened to include horde, + -Orchestrator ----
$stamp = Get-Command (Join-Path $scripts 'stamp-lyra-package.ps1')
$stampSet = Get-ValidSet $stamp 'Source'
Assert-True ($stampSet -contains 'standalone') 'stamp -Source set keeps standalone'
Assert-True ($stampSet -contains 'teamcity')   'stamp -Source set keeps teamcity'
Assert-True ($stampSet -contains 'horde')      'stamp -Source set WIDENED to horde'
Assert-True ($stamp.Parameters.ContainsKey('Orchestrator')) 'stamp has -Orchestrator param'

# ---- buildgraph-lyra.ps1: new -Source (validated, incl horde) + -Orchestrator ----
$bg = Get-Command (Join-Path $scripts 'buildgraph-lyra.ps1')
Assert-True ($bg.Parameters.ContainsKey('Source'))       'buildgraph has -Source param'
Assert-True ($bg.Parameters.ContainsKey('Orchestrator')) 'buildgraph has -Orchestrator param'
$bgSet = Get-ValidSet $bg 'Source'
Assert-True ($bgSet -contains 'horde')      'buildgraph -Source set includes horde'
Assert-True ($bgSet -contains 'teamcity')   'buildgraph -Source set includes teamcity'
Assert-True ($bgSet -contains 'standalone') 'buildgraph -Source set includes standalone'

# ---- emit-run-metric.ps1 (NEW): the post-run Horde metric emitter ----
$emit = Get-Command (Join-Path $scripts 'emit-run-metric.ps1')
$emitSet = Get-ValidSet $emit 'Source'
Assert-True ($emitSet -contains 'horde')                  'emit -Source set includes horde'
Assert-True ($emit.Parameters.ContainsKey('DurationSec')) 'emit has -DurationSec param'
Assert-True ($emit.Parameters.ContainsKey('JobId'))       'emit has -JobId param'
Assert-True ($emit.Parameters.ContainsKey('Server'))      'emit has -Server param'
Assert-True ($emit.Parameters.ContainsKey('Changelist'))  'emit has -Changelist param'
Assert-True ($emit.Parameters.ContainsKey('DryRun'))      'emit has -DryRun param'

Assert-Summary
