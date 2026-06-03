<#
.SYNOPSIS
  Prove the MSVC toolchain works end to end: activate it, compile a tiny
  C++ program, run the resulting exe, and assert its output.

.DESCRIPTION
  This is the runnable artifact behind "the compiler situation is fixed."
  It dot-sources activate-msvc.ps1 (so cl is on PATH in this process),
  compiles accel/samples/hello/hello.cpp, runs hello.exe, and checks the
  output. Non-zero exit on any failure, so CI can gate on it.

      pwsh -File .\accel\scripts\smoke-build.ps1
#>

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "activate-msvc.ps1")

$srcPath   = (Resolve-Path (Join-Path $here "..\samples\hello\hello.cpp")).Path
$sampleDir = Split-Path -Parent $srcPath
$outDir    = Join-Path $sampleDir "_build"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$exe = Join-Path $outDir "hello.exe"

Write-Host "`nCompiling $srcPath ..."
& cl.exe /nologo /EHsc /std:c++17 "/Fe:$exe" "/Fo:$outDir\" $srcPath
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed (exit $LASTEXITCODE)." }

Write-Host "Running $exe ..."
$out = & $exe
if ($LASTEXITCODE -ne 0) { throw "hello.exe exited non-zero ($LASTEXITCODE)." }
Write-Host "  output: $out"

if ($out -match "hello from MSVC") {
    Write-Host "`nSMOKE OK -- MSVC toolchain activates, compiles, and runs."
} else {
    throw "Smoke test ran but output was unexpected: $out"
}
