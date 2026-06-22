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

# ConvertFrom-UnrealMetrics: latest-per-step duration stages + stamp provenance
$um = @(
  [pscustomobject]@{ track='unreal'; step='buildgraph'; target='Lyra Pipeline'; durationSec=70.0;   success=$true; utc='2026-06-05T01:00:00Z' }
  [pscustomobject]@{ track='unreal'; step='buildgraph'; target='Lyra Pipeline'; durationSec=62.2;   success=$true; utc='2026-06-05T02:32:49Z' }  # newer teamcity-path -> wins its source
  [pscustomobject]@{ track='unreal'; step='buildgraph'; target='Lyra Pipeline'; durationSec=0.5; listOnly=$true; success=$true; utc='2026-06-05T03:00:00Z' }  # list-only -> ignored
  [pscustomobject]@{ track='unreal'; step='buildgraph'; target='Lyra Pipeline'; durationSec=1711.0; source='horde'; success=$true; utc='2026-06-13T19:11:54Z' }  # ran under Horde
  [pscustomobject]@{ track='unreal'; step='compile';    target='LyraEditor';    durationSec=83.9;   success=$true; utc='2026-06-04T23:27:09Z' }
  [pscustomobject]@{ track='unreal'; step='cook';       target='Lyra';          durationSec=1432.0; success=$true; utc='2026-06-05T00:11:51Z' }
  [pscustomobject]@{ track='unreal'; step='package';    target='LyraGame';      durationSec=90.5;   success=$true; utc='2026-06-05T00:19:27Z' }
  [pscustomobject]@{ track='unreal'; step='stamp'; changelist='51'; changelistSource='p4'; p4Changelist='51'; engineChangelist='44394996'; source='teamcity'; durationSec=0.02; success=$true; utc='2026-06-05T02:32:49Z' }
)
$uf = ConvertFrom-UnrealMetrics -Metrics $um
Assert-Equal 4    @($uf.stages).Count                                'four duration stages (compile/cook/package/buildgraph)'
$bg = @($uf.stages | Where-Object { $_.step -eq 'buildgraph' })
Assert-Equal 1    $bg.Count                                          'one buildgraph stage (latest-per-step dedup)'
Assert-Equal 62.2 $bg[0].durationSec                                 'stages buildgraph = newest TeamCity-path run (Horde excluded from the canonical baseline)'
Assert-Equal '51' $uf.stamp.changelist                              'extracts the stamp changelist'
Assert-Equal 'teamcity' $uf.stamp.source                            'extracts the stamp source'
Assert-Equal '44394996' $uf.stamp.engineChangelist                 'extracts the engine changelist'

# orchestrators: latest buildgraph per source (absent source -> 'teamcity'), the Horde-vs-TeamCity parity feed
$orch = @($uf.orchestrators)
Assert-Equal 2 $orch.Count                                          'two orchestrators (teamcity + horde)'
Assert-Equal 'teamcity' $orch[0].source                            'orchestrators sorted chronologically: TeamCity (baseline) first'
Assert-Equal 62.2 $orch[0].durationSec                             'teamcity orchestrator = newest non-list-only teamcity-path buildgraph'
Assert-Equal 'horde'    $orch[1].source                            'Horde orchestrator second'
Assert-Equal 1711.0 $orch[1].durationSec                           'horde orchestrator = the Horde job end-to-end duration'
Assert-True  ([bool]$orch[1].success)                               'horde orchestrator carries success'

# Merge-Feed stale-fallback applies to the unreal section too
$priorU = [pscustomobject]@{ stale=$false; stages=@(1,2,3,4); stamp=[pscustomobject]@{ changelist='44' } }
$mU = Merge-Feed -New $null -Prior $priorU
Assert-True  $mU.stale                  'unreal fallback marks stale'
Assert-Equal '44' $mU.stamp.changelist  'unreal fallback reuses the prior stamp'

# ConvertFrom-PipelineMetrics: latest cook-stats record -> the dashboard 'pipeline' section
$pm = @(
  [pscustomobject]@{ textures_cooked=4; textures_cached=0; audio_cooked=2; audio_cached=0; characters_cooked=2; characters_cached=0; total_bytes=144428; elapsed_sec=0.05; utc='2026-06-22T10:00:00Z' }  # cold
  [pscustomobject]@{ textures_cooked=0; textures_cached=4; audio_cooked=0; audio_cached=2; characters_cooked=0; characters_cached=2; total_bytes=144428; elapsed_sec=0.006; utc='2026-06-22T10:05:00Z' } # warm (newer)
)
$pf = ConvertFrom-PipelineMetrics -Metrics $pm
Assert-Equal 0   $pf.cooked     'latest record wins: warm run cooked 0'
Assert-Equal 8   $pf.cached     'warm run cached all 8 (4+2+2)'
Assert-True  $pf.warm           'warm flag set when cooked==0 and cached>0'
Assert-Equal 144428 $pf.totalBytes 'carries total bytes'

$pfCold = ConvertFrom-PipelineMetrics -Metrics @($pm[0])
Assert-True  (-not $pfCold.warm) 'cold run (cached 0) is not warm'

Assert-True  ($null -eq (ConvertFrom-PipelineMetrics -Metrics @())) 'no metrics -> null section'

Assert-Summary
