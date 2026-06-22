$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\..\dashboard\tests\_assert.ps1")   # shared assert harness
. (Join-Path $here "..\scripts\build-configs.ps1")          # defines Get-SandboxBuildConfigs

$configs = Get-SandboxBuildConfigs -VersionStampScript "echo stamp"
$byId = @{}; foreach ($c in $configs) { $byId[$c.Id] = $c }

Assert-True ($byId.ContainsKey('AAASandbox_Compile'))    'has Compile'
Assert-True ($byId.ContainsKey('AAASandbox_SmokeTest'))  'has Smoke Test'
Assert-True ($byId.ContainsKey('AAASandbox_CookData'))   'has Cook Data (toy cooker, unchanged)'
Assert-True ($byId.ContainsKey('AAASandbox_Package'))    'has Package'
Assert-Equal 'hoops_cooker Data Cooked.pak' `
    (($byId['AAASandbox_CookData'].Steps[0].Script) -replace '.*Cooker/','') `
    'Cook Data still runs the toy cooker'

# --- Cook Assets (real cooker, warm-cacheable) ---
$ca = $byId['AAASandbox_CookAssets']
Assert-True  ($null -ne $ca)                         'has Cook Assets'
Assert-Equal 'Cook Assets' $ca.Name                  'Cook Assets display name'
Assert-Equal 0 @($ca.SnapshotDeps).Count             'Cook Assets is standalone (no snapshot deps on the C++ chain)'
Assert-Match 'make-samples\.py'  $ca.Steps[0].Script 'step regenerates synthetic assets'
Assert-Match 'cook\.py --pack'   $ca.Steps[0].Script 'step runs the real cooker with --pack'
Assert-Match 'cached'            $ca.Steps[0].Script 'step carries the warm-cache guard'
Assert-Match 'pipeline/cooked => cooked\.zip' $ca.ArtifactRules 'publishes the CAS dir-form (dotfiles included)'
Assert-Match 'Cooked-assets\.pak'             $ca.ArtifactRules 'publishes the real .pak'
Assert-Equal 'cooked.zip!** => pipeline/cooked' $ca.WarmCacheArtifact.PathRules 'self artifact-dep restores the CAS'
Assert-True $ca.CleanCheckout 'Cook Assets uses clean checkout so the CAS is artifact-driven, not checkout-residue'

Assert-Summary
