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

Assert-Summary
