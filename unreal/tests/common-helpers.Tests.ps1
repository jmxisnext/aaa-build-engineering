# Unit tests for the pure helpers added to _unreal-common.ps1 in the "de-risk Session 4"
# work: orchestrator-name derivation, BuildGraph arg assembly (incl. the new -set:Source),
# and the post-run buildgraph metric builder New-RunMetric (formalizes the 2026-06-13
# hand-assembled Horde metric so the next live run regenerates it reproducibly).
# Engine-independent: no UE install, no services, no RunUAT.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
. (Join-Path $here "..\scripts\_unreal-common.ps1")

# ---- Get-OrchestratorName: source token -> display orchestrator name ----
Assert-Equal 'Horde'      (Get-OrchestratorName -Source 'horde')      'horde -> Horde'
Assert-Equal 'TeamCity'   (Get-OrchestratorName -Source 'teamcity')   'teamcity -> TeamCity'
Assert-Equal 'standalone' (Get-OrchestratorName -Source 'standalone') 'standalone -> standalone'

# ---- Build-BuildGraphArgs: reproduces the existing UAT BuildGraph args + threads -set:Source ----
$argsTC = Build-BuildGraphArgs -Script 'x.xml' -Target 'Lyra Pipeline' -ProjectPath 'p.uproject' -ArchiveDir 'D:\out' -Source 'teamcity'
Assert-True ($argsTC[0] -eq 'BuildGraph')                      'arg[0] is BuildGraph'
Assert-True ($argsTC -contains '-Script=x.xml')               'carries -Script'
Assert-True ($argsTC -contains '-Target=Lyra Pipeline')       'carries -Target'
Assert-True ($argsTC -contains '-set:ProjectPath=p.uproject') 'carries -set:ProjectPath'
Assert-True ($argsTC -contains '-set:ArchiveDir=D:\out')      'carries -set:ArchiveDir'
Assert-True ($argsTC -contains '-set:Source=teamcity')        'threads -set:Source when Source set'

# backward-compat: NO -set:Source emitted when Source is absent (collector defaults absent buildgraph source -> teamcity)
$argsBare = Build-BuildGraphArgs -Script 'x.xml' -Target 'Lyra Pipeline' -ProjectPath 'p.uproject' -ArchiveDir 'D:\out'
Assert-True (-not ($argsBare -match '-set:Source')) 'omits -set:Source when Source not supplied (zero regression to the TeamCity baseline)'
Assert-True (-not ($argsBare -contains '-ListOnly')) 'no -ListOnly by default'

# -ListOnly appends the validate-only flag (cheap parse, no build)
$argsLO = Build-BuildGraphArgs -Script 'x.xml' -Target 'Lyra Pipeline' -ProjectPath 'p.uproject' -ArchiveDir 'D:\out' -ListOnly
Assert-True ($argsLO -contains '-ListOnly') '-ListOnly appended when requested'

# ---- New-RunMetric: post-run buildgraph metric carrying source/orchestrator + Horde job facts ----
$m = New-RunMetric -Source 'horde' -Target 'Lyra Pipeline' -DurationSec 1711.0 -ExitCode 0 `
        -JobId '6a2da13d2729362a627914ca' -Server 'http://localhost:13340' -Changelist '51' `
        -Script 'C:\repo\lyra-pipeline.xml' -Engine 'G:\UE_5.6' -Uproject 'G:\Lyra.uproject' `
        -Utc '2026-06-13T19:11:54Z'
# the fields collect-metrics.ps1 actually reads for the orchestrator-parity row:
Assert-Equal 'unreal'        $m.track        'metric track = unreal'
Assert-Equal 'buildgraph'    $m.step         'metric step = buildgraph (groups into orchestrators)'
Assert-Equal 'horde'         $m.source       'source = horde (the parity discriminator)'
Assert-Equal 'Lyra Pipeline' $m.target       'carries target'
Assert-Equal 1711            $m.durationSec  'carries durationSec'
Assert-True  ([bool]$m.success)              'exitCode 0 -> success true'
Assert-True  (-not [bool]$m.listOnly)        'listOnly false (must not be skipped by the collector)'
Assert-Equal '2026-06-13T19:11:54Z' $m.utc   'carries the supplied utc (datetime-parseable)'
# extra provenance fields (display / traceability), matching the 2026-06-13 shape:
Assert-Equal 'Horde'  $m.orchestrator                       'orchestrator derived from source'
Assert-Equal '6a2da13d2729362a627914ca' $m.hordeJobId       'carries hordeJobId'
Assert-Equal 'http://localhost:13340'    $m.hordeServer      'carries hordeServer'
Assert-Equal '51'     $m.changelist                         'carries changelist'

# failure path: non-zero exit -> success false
$mf = New-RunMetric -Source 'horde' -Target 'Lyra Pipeline' -DurationSec 5.0 -ExitCode 1 -Utc '2026-06-13T19:11:54Z'
Assert-True (-not [bool]$mf.success) 'exitCode 1 -> success false'

Assert-Summary
