$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
. (Join-Path $here "..\scripts\collect-metrics.ps1")

# ConvertFrom-TcBuilds: a recorded REST 'build' array -> normalized CI builds
$tc = @(
  [pscustomobject]@{ number='45'; status='FAILURE'; statusText='Exit code 8'; buildTypeId='AAASandbox_SmokeTest'
    buildType=[pscustomobject]@{ name='Smoke Test' }; webUrl='http://localhost:8111/build/406'
    startDate='20260604T165846+0000'; finishDate='20260604T165847+0000'
    revisions=[pscustomobject]@{ revision=@([pscustomobject]@{ version='45' }) } }
)
$ciBuilds = ConvertFrom-TcBuilds -Builds $tc
Assert-Equal 'Smoke Test' $ciBuilds[0].config 'maps buildType name -> config'
Assert-Equal 45           $ciBuilds[0].cl     'maps revision version -> cl'
Assert-Equal 'FAILURE'    $ciBuilds[0].status 'maps status'
Assert-True  ($ciBuilds[0].durationSec -ge 1 -and $ciBuilds[0].durationSec -le 2) 'duration = finish - start (~1s)'
Assert-Equal '2026-06-04T16:58:47Z' $ciBuilds[0].finishUtc 'normalizes finishUtc to ISO-8601 (render needs [datetime]-parseable)'

# ConvertFrom-P4Streams: 'p4 streams' text -> stream objects
$p4 = @'
Stream //game/main mainline none 'Hoops Brawl mainline'
Stream //game/dev development //game/main 'Integration'
'@
$streams = ConvertFrom-P4Streams -Text $p4
Assert-Equal 2            $streams.Count                'parses two streams'
Assert-Equal '//game/main' $streams[0].stream           'parses stream path'
Assert-Equal 'mainline'   $streams[0].type              'parses stream type'

# Merge-Feed: missing section falls back to prior snapshot + marks stale
$prior = [pscustomobject]@{ ci = [pscustomobject]@{ stale=$false; builds=@(1,2,3) } }
$merged = Merge-Feed -New $null -Prior $prior.ci
Assert-True  $merged.stale            'fallback marks the section stale'
Assert-Equal 3 @($merged.builds).Count 'fallback reuses prior builds'

Assert-Summary
