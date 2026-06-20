# Integration smoke test for the emit-run-metric.ps1 wrapper: invoke it (child process,
# -DryRun so nothing is written) and assert it emits a collector-shaped buildgraph metric.
# The metric-building logic itself is unit-tested RED->GREEN in common-helpers.Tests.ps1
# (New-RunMetric); this proves the param wiring + JSON serialization + DryRun exit path.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
$emit = Join-Path $here "..\scripts\emit-run-metric.ps1"

$out = & pwsh -NoProfile -File $emit -Source horde -DurationSec 1711 `
  -JobId 6a2da13d2729362a627914ca -Server 'http://localhost:13340' -Changelist 51 -DryRun 2>&1
Assert-Equal 0 $LASTEXITCODE 'emit -DryRun exits 0'

$text = ($out | Out-String)
# pull the JSON object out of the previewed output (first '{' .. last '}')
$i = $text.IndexOf('{'); $j = $text.LastIndexOf('}')
Assert-True ($i -ge 0 -and $j -gt $i) 'preview contains a JSON object'
$obj = $text.Substring($i, $j - $i + 1) | ConvertFrom-Json

Assert-Equal 'buildgraph' $obj.step       'emitted step = buildgraph'
Assert-Equal 'horde'      $obj.source      'emitted source = horde'
Assert-Equal 'Horde'      $obj.orchestrator 'emitted orchestrator derived'
Assert-Equal 1711         $obj.durationSec 'emitted durationSec'
Assert-True  ([bool]$obj.success)          'exit 0 -> success true'
Assert-True  (-not [bool]$obj.listOnly)    'listOnly false (collector must not skip it)'
Assert-Equal '51'         $obj.changelist  'emitted changelist'
Assert-True  ([datetime]$obj.utc -is [datetime]) 'utc is datetime-parseable (render contract)'

Assert-Summary
