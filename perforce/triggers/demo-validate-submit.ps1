<#
.SYNOPSIS
  End-to-end demo of the validate-submit (depot-hygiene) change-content trigger.

.DESCRIPTION
  Exercises every behavior of triggers/validate-submit.py against the live
  sandbox p4d and asserts each outcome. Self-contained and idempotent:

    * restarts p4d with a low size threshold (P4_MAX_FILE_MB) so the size
      cases use small files instead of churning 50 MB through the depot;
    * creates its OWN throwaway clients (a stream client for //game/dev, a
      classic client for //thirdparty) so it never depends on a machine-named
      personal workspace;
    * cleans up everything it created — pending changelists, committed demo
      revisions (via obliterate), and both clients — in a finally block;
    * restores p4d to its default threshold on exit.

  Cases:
    A  build-artifact (.obj) in //game/dev          -> REJECT (rule 1)
    B  clean .cpp in //game/dev                      -> ACCEPT
    C  oversized file, no override, in //game/dev    -> REJECT (rule 2, @=change)
    D  same oversized file WITH [large-ok]           -> ACCEPT (override)
    E  build-artifact (.dll) under //thirdparty/     -> ACCEPT (exemption)

  Run from anywhere; requires p4d reachable on localhost:1666 and the trigger
  already registered (see triggers/README.md).
#>
param(
    [string]$P4          = "C:\Program Files\Perforce\p4.exe",
    [int]   $ThresholdMB = 5,
    [int]   $TestFileMB  = 6,
    [string]$ScriptsDir  = "J:\jammers-lab\aaa-build-engineering\perforce\scripts"
)

$ErrorActionPreference = "Stop"
$env:P4PORT = "localhost:1666"
$env:P4USER = "james"

$DEV_CLIENT = "validate-demo-dev"
$TP_CLIENT  = "validate-demo-tp"
$DEV_ROOT   = "C:\PerforceSandbox\workspaces\$DEV_CLIENT"
$TP_ROOT    = "C:\PerforceSandbox\workspaces\$TP_CLIENT"
$pass = 0; $fail = 0

function Restart-P4D([string]$MaxMB) {
    & "$ScriptsDir\stop-p4d.ps1" | Out-Null
    if ($MaxMB) { $env:P4_MAX_FILE_MB = $MaxMB } else { Remove-Item Env:\P4_MAX_FILE_MB -ErrorAction SilentlyContinue }
    & "$ScriptsDir\start-p4d.ps1" | Out-Null
}

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  FAIL  $name -- $detail" -ForegroundColor Red; $script:fail++ }
}

# Submit helper: returns @{ Code; Out }. Never throws on a policy reject.
function Try-Submit([string]$client, [string]$desc, [string]$changeArg) {
    $cmdArgs = @("-c", $client, "submit")
    if ($changeArg) { $cmdArgs += @("-c", $changeArg) } else { $cmdArgs += @("-d", $desc) }
    $out = (& $P4 @cmdArgs 2>&1 | Out-String)
    return @{ Code = $LASTEXITCODE; Out = $out }
}

try {
    Write-Host "== validate-submit trigger demo ==" -ForegroundColor Cyan
    Write-Host "Restarting p4d with P4_MAX_FILE_MB=$ThresholdMB ..."
    Restart-P4D $ThresholdMB

    # --- throwaway clients ----------------------------------------------------
    New-Item -ItemType Directory -Path $DEV_ROOT, $TP_ROOT -Force | Out-Null

    @"
Client: $DEV_CLIENT
Owner: james
Root: $DEV_ROOT
Options: noallwrite noclobber nocompress unlocked nomodtime normdir
SubmitOptions: submitunchanged
LineEnd: local
Stream: //game/dev
"@ | & $P4 client -i | Out-Null
    & $P4 -c $DEV_CLIENT sync -q | Out-Null

    @"
Client: $TP_CLIENT
Owner: james
Root: $TP_ROOT
Options: noallwrite noclobber nocompress unlocked nomodtime normdir
SubmitOptions: submitunchanged
LineEnd: local
View:
`t//thirdparty/... //$TP_CLIENT/...
"@ | & $P4 client -i | Out-Null

    # --- Case A: build artifact in code path -> REJECT ------------------------
    Set-Content "$DEV_ROOT\Code\Demo.obj" "fake compiled output"
    & $P4 -c $DEV_CLIENT add "$DEV_ROOT\Code\Demo.obj" | Out-Null
    $r = Try-Submit $DEV_CLIENT "demoA: build artifact"
    Check "A  .obj in //game/dev rejected" ($r.Code -ne 0 -and $r.Out -match "build-artifact") $r.Out
    & $P4 -c $DEV_CLIENT revert "$DEV_ROOT\Code\Demo.obj" | Out-Null
    Remove-Item "$DEV_ROOT\Code\Demo.obj" -Force

    # --- Case B: clean file -> ACCEPT -----------------------------------------
    Set-Content "$DEV_ROOT\Code\DemoClean.cpp" "int demo(){return 0;}"
    & $P4 -c $DEV_CLIENT add "$DEV_ROOT\Code\DemoClean.cpp" | Out-Null
    $r = Try-Submit $DEV_CLIENT "demoB: clean source"
    Check "B  clean .cpp accepted" ($r.Code -eq 0) $r.Out
    & $P4 obliterate -y //game/dev/Code/DemoClean.cpp | Out-Null   # B committed; keep depot clean

    # --- Case C: oversized, no override -> REJECT -----------------------------
    $bytes = New-Object byte[] ($TestFileMB * 1MB); (New-Object Random).NextBytes($bytes)
    [IO.File]::WriteAllBytes("$DEV_ROOT\Code\demoblob.bin", $bytes)
    & $P4 -c $DEV_CLIENT add "$DEV_ROOT\Code\demoblob.bin" | Out-Null
    $r = Try-Submit $DEV_CLIENT "demoC: oversized no override"
    Check "C  oversized rejected (via @=change)" ($r.Code -ne 0 -and $r.Out -match "oversized") $r.Out
    # capture the pending changelist number for the override case
    $opened = (& $P4 -c $DEV_CLIENT opened 2>&1 | Out-String)
    $cl = ([regex]::Match($opened, "change (\d+)")).Groups[1].Value

    # --- Case D: same file WITH [large-ok] -> ACCEPT --------------------------
    $spec = ((& $P4 -c $DEV_CLIENT change -o $cl) -join "`n") -replace "demoC: oversized no override", "demoD: oversized [large-ok]"
    $spec | & $P4 -c $DEV_CLIENT change -i | Out-Null
    $r = Try-Submit $DEV_CLIENT $null $cl
    Check "D  oversized + [large-ok] accepted" ($r.Code -eq 0) $r.Out
    & $P4 obliterate -y //game/dev/Code/demoblob.bin | Out-Null   # keep the depot clean

    # --- Case E: build artifact under //thirdparty/ -> ACCEPT (exemption) -----
    New-Item -ItemType Directory -Path "$TP_ROOT\demo\lib" -Force | Out-Null
    Set-Content "$TP_ROOT\demo\lib\vendor.dll" "MZ fake prebuilt vendor binary"
    & $P4 -c $TP_CLIENT add "$TP_ROOT\demo\lib\vendor.dll" | Out-Null
    $r = Try-Submit $TP_CLIENT "demoE: vendor prebuilt .dll (exempt)"
    Check "E  .dll under //thirdparty/ accepted" ($r.Code -eq 0) $r.Out
    & $P4 obliterate -y //thirdparty/demo/lib/vendor.dll | Out-Null

    Write-Host ""
    Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor ($(if ($fail) {"Red"} else {"Green"}))
}
finally {
    # --- cleanup: revert anything pending, delete throwaway demo files + clients
    foreach ($cli in @($DEV_CLIENT, $TP_CLIENT)) {
        & $P4 -c $cli revert //... 2>&1 | Out-Null
        # delete any empty pending changelists owned by the demo client
        foreach ($n in ([regex]::Matches((& $P4 changes -s pending -c $cli 2>&1 | Out-String), "Change (\d+)") | ForEach-Object { $_.Groups[1].Value })) {
            & $P4 -c $cli change -d $n 2>&1 | Out-Null
        }
        & $P4 client -d $cli 2>&1 | Out-Null
    }
    Remove-Item $DEV_ROOT, $TP_ROOT -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Restoring p4d to default threshold ..."
    Restart-P4D $null
}
