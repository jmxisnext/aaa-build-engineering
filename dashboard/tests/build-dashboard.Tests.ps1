$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
. (Join-Path $here "..\scripts\build-dashboard.ps1")   # dot-source: defines funcs, guarded main skipped

$builds = @(
    [pscustomobject]@{ number=10; cl=46; status='SUCCESS' },
    [pscustomobject]@{ number=9;  cl=45; status='FAILURE' }
)
$tl = New-SvgTimeline -Builds $builds
Assert-Match '^<svg'            $tl 'timeline is an svg'
Assert-Match '#3fb950'          $tl 'timeline has a green (success) square'
Assert-Match '#f85149'          $tl 'timeline has a red (failure) square'
Assert-Match 'CL46'             $tl 'timeline square has a CL tooltip'

$bars = New-SvgBars -Items @(
    [pscustomobject]@{ label='/MP'; value=4.0; text='4.0x' },
    [pscustomobject]@{ label='unity'; value=28.0; text='28x' }
)
Assert-Match '^<svg'            $bars 'bars is an svg'
Assert-Match '4\.0x'            $bars 'bars renders the /MP label text'
Assert-Match '28x'             $bars 'bars renders the unity label text'

Assert-Summary
