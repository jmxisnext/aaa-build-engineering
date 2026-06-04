# Tiny assertion harness (repo convention: a runnable .ps1 that throws on failure,
# so CI / a human can gate on exit code -- no Pester/framework dependency).
$script:AssertFailed = 0
function Assert-Equal { param($Expected, $Actual, [string]$Msg)
    if ("$Expected" -ne "$Actual") { Write-Host "FAIL $Msg`n  expected=[$Expected]`n  actual  =[$Actual]" -ForegroundColor Red; $script:AssertFailed++ }
    else { Write-Host "ok   $Msg" -ForegroundColor Green } }
function Assert-True { param([bool]$Cond, [string]$Msg)
    if (-not $Cond) { Write-Host "FAIL $Msg" -ForegroundColor Red; $script:AssertFailed++ } else { Write-Host "ok   $Msg" -ForegroundColor Green } }
function Assert-Match { param([string]$Pattern, [string]$Text, [string]$Msg)
    if ($Text -notmatch $Pattern) { Write-Host "FAIL $Msg (no match /$Pattern/)" -ForegroundColor Red; $script:AssertFailed++ } else { Write-Host "ok   $Msg" -ForegroundColor Green } }
function Assert-NotMatch { param([string]$Pattern, [string]$Text, [string]$Msg)
    if ($Text -match $Pattern) { Write-Host "FAIL $Msg (unexpected /$Pattern/)" -ForegroundColor Red; $script:AssertFailed++ } else { Write-Host "ok   $Msg" -ForegroundColor Green } }
function Assert-Summary { if ($script:AssertFailed -gt 0) { throw "$script:AssertFailed assertion(s) failed" } else { Write-Host "`nALL PASS" -ForegroundColor Cyan } }
