# Structural tests for the graph + Horde stream edits (config files -> assert shape, not run).
#  - lyra-pipeline.xml: well-formed; Source/RepoDir Options; "Stamp Lyra" node wired after
#    Package and into the aggregate; the stamp Source is THREADED ($(Source)), never hardcoded
#    'horde' (which would mislabel every TeamCity run).
#  - game-main.stream.json: the Horde template passes -set:Source=horde (keeps -NoP4).
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$xmlPath    = Join-Path $here "..\buildgraph\lyra-pipeline.xml"
$streamPath = Join-Path $here "..\horde\config\game-main.stream.json"
. (Join-Path $here "_assert.ps1")

$xml = Get-Content $xmlPath -Raw

# well-formed XML (a malformed edit fails the cast)
$parsed = $null
try { $parsed = [xml]$xml } catch { }
Assert-True ($null -ne $parsed) 'lyra-pipeline.xml is well-formed XML'

# new graph options
Assert-Match '<Option\s+Name="Source"[^>]*DefaultValue="teamcity"' $xml 'Source Option defaults to teamcity (the baseline runner of the graph)'
Assert-Match '<Option\s+Name="RepoDir"' $xml 'RepoDir Option present (resolves the stamp script path)'

# Stamp node: depends on Package, threads $(Source) (NOT hardcoded horde), feeds the aggregate
Assert-Match '<Node\s+Name="Stamp Lyra"\s+Requires="Package Lyra"' $xml 'Stamp Lyra node Requires Package Lyra'
Assert-Match 'stamp-lyra-package\.ps1' $xml 'Stamp node invokes stamp-lyra-package.ps1'
Assert-Match '-Source\s+\$\(Source\)' $xml 'stamp Source is threaded as $(Source), not hardcoded'
Assert-NotMatch 'stamp-lyra-package\.ps1[^<]*-Source\s+horde' $xml 'stamp Source is NOT hardcoded horde (would mislabel TeamCity runs)'
Assert-Match '<Aggregate\s+Name="Lyra Pipeline"\s+Requires="Stamp Lyra"' $xml 'aggregate now pulls Stamp Lyra (so the full target stamps)'

# Horde stream template: pass -set:Source=horde, keep -NoP4
$stream = Get-Content $streamPath -Raw
Assert-Match '-set:Source=horde' $stream 'Horde stream template passes -set:Source=horde'
Assert-Match '-NoP4'             $stream 'Horde stream template still passes -NoP4 (one-box local executor)'

Assert-Summary
