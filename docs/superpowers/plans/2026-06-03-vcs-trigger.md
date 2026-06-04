# VCS Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A broker-policy-gated P4 submit to `//game/main` auto-fires the TeamCity chain (Compile → SmokeTest‖CookData → Package) within seconds; a frozen-out submit fires nothing.

**Architecture:** A p4d `change-commit` trigger runs `notify-teamcity.ps1` on the p4d host, which POSTs TeamCity's `commitHookNotification` endpoint (Bearer auth via a durable minted token) → the native VCS trigger on Package resolves the changelist and fans out the chain. The broker enforces policy *upstream* of p4d, so CI can only run on submits that actually landed.

**Tech Stack:** PowerShell 7 (pwsh), TeamCity REST API, Perforce (`p4` CLI + p4broker), Docker Compose.

**Spec:** `docs/superpowers/specs/2026-06-03-vcs-trigger-design.md`

---

## Preconditions (verify before starting — see Task 1)

- The stack is **up**: p4d `:1666`, broker `:1667`, TeamCity server + 2 agents (`docker compose ps` all healthy/up).
- The shell's ambient Perforce env can reach p4d as **super** user `james` (`p4 -p localhost:1666 -u james info` works; `james` has admin rights for `triggers -i` / `user -f`).
- The broker code-freeze (Policy 2 in `perforce/broker/p4broker.conf`) is **active** — required for Case B to reject.
- `pwsh` resolves on PATH (the p4d trigger line calls `pwsh`).
- Run all scripts from the repo root `J:\jammers-lab\aaa-build-engineering` unless noted.

## File structure

| File | Responsibility |
|---|---|
| `perforce/triggers/notify-teamcity.ps1` | **NEW.** The change-commit hook. Runs on the p4d host per commit; sleeps 10s, POSTs `commitHookNotification` with the durable Bearer token, logs, always `exit 0`. |
| `perforce/triggers/README.md` | **NEW.** What the trigger is, how to (re)install, the loop-safety invariant. |
| `ci/scripts/setup-vcs-trigger.ps1` | **NEW.** Idempotent installer: mint durable token for `ci-hook`, add the VCS trigger to Package, install the p4d change-commit trigger. |
| `ci/scripts/demo-vcs-trigger.ps1` | **NEW.** Policy-gated end-to-end verification (the demo artifact + self-test). |
| `ci/lessons-learned.md` | **MODIFY.** Append lesson #7 (durable token + topology-driven endpoint choice). |
| `ci/README.md` | **MODIFY.** Document the trigger + how to run the demo. |
| `C:\PerforceSandbox\triggers\teamcity-hook.token` | Secret, **outside the repo** — written by setup, read by the hook. |
| `C:\PerforceSandbox\triggers\hook.log` | Hook activity log, **outside the repo**. |

---

## Task 1: Verify environment assumptions (read-only gate)

No code; this de-risks the spec's §9 assumptions before building. Record each result; if any probe fails, adjust the affected task before proceeding.

**Files:** none.

- [ ] **Step 1: Confirm the stack is up**

Run:
```powershell
docker compose -f ci/docker-compose.yml ps
```
Expected: `teamcity-server` healthy, `teamcity-agent` + `teamcity-agent-02` up.

- [ ] **Step 2: Confirm james is P4 super and can administer**

Run:
```powershell
p4 -p localhost:1666 -u james info
p4 -p localhost:1666 -u james protects -m
```
Expected: `info` prints server data; `protects -m` prints `super` (or higher). If it prints a lower level, `triggers -i` / `user -f` will fail — resolve P4 auth (e.g. `p4 -p localhost:1666 -u james login`) before Task 3/4.

- [ ] **Step 3: Confirm the broker freeze is active (Case B depends on it)**

Run:
```powershell
Select-String -Path perforce/broker/p4broker.conf -Pattern 'command: \^submit\$' -Context 0,4
```
Expected: two `^submit$` blocks — a `pass` allowlist and a `reject`. If the reject block is commented out, Case B cannot reject; re-enable it or note the demo will skip Case B.

- [ ] **Step 4: Confirm pwsh resolves and note its full path (fallback for the trigger line)**

Run:
```powershell
(Get-Command pwsh).Source
```
Expected: a path like `C:\Program Files\PowerShell\7\pwsh.exe`. If `pwsh` is not on the PATH that p4d runs under, Task 3 must use this full path in the trigger line instead of bare `pwsh`.

- [ ] **Step 5: Confirm the TeamCity superuser scrape works (REST auth for setup/demo)**

Run:
```powershell
$tok = (docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1") -replace '.*token: (\d+).*','$1'
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$tok"))
Invoke-RestMethod -Headers @{Authorization=$auth;Accept='application/json'} -Uri "http://localhost:8111/app/rest/server" | Select-Object version,buildNumber
```
Expected: prints the server version (proves the scrape + REST auth path the setup/demo scripts rely on).

No commit — this task produces findings, not files.

---

## Task 2: The change-commit hook script

**Files:**
- Create: `perforce/triggers/notify-teamcity.ps1`
- Create: `perforce/triggers/README.md`

- [ ] **Step 1: Write `notify-teamcity.ps1`**

```powershell
<#
.SYNOPSIS
  Perforce change-commit hook: ask TeamCity to check //game/main *now*.

.DESCRIPTION
  Registered in p4d as a change-commit trigger on //game/main/... (see
  ci/scripts/setup-vcs-trigger.ps1). Runs on the p4d host on every commit.
  After a 10s settle it POSTs TeamCity's commitHookNotification endpoint so
  the VCS trigger on Package fires near-instantly instead of waiting for the
  next scheduled poll.

  Auth: a DURABLE TeamCity access token (Bearer), minted by
  setup-vcs-trigger.ps1 and stored OUTSIDE the repo. The superuser token
  rotates every server restart (lessons-learned #6) and is unusable here.

  Fail-safe: ALWAYS exits 0. change-commit fires after the commit is durable,
  so a hook failure can never block a submit — worst case "instant" degrades
  to "next scheduled VCS poll".
#>
param(
    [string]$Change,
    [string]$BaseUrl   = "http://localhost:8111",
    [string]$VcsRootId = "AAASandbox_GameMainStream",
    [string]$TokenFile = "C:\PerforceSandbox\triggers\teamcity-hook.token",
    [string]$LogFile   = "C:\PerforceSandbox\triggers\hook.log"
)

$ErrorActionPreference = "Continue"   # never let an error escape and wedge p4d

function Write-HookLog([string]$Msg) {
    $line = "{0}  cl={1}  {2}" -f (Get-Date).ToString("s"), $Change, $Msg
    try { Add-Content -Path $LogFile -Value $line } catch { }
}

try {
    Start-Sleep -Seconds 10                          # let p4d finish processing the change
    if (-not (Test-Path $TokenFile)) { Write-HookLog "NO TOKEN FILE at $TokenFile"; exit 0 }
    $token = (Get-Content -Raw $TokenFile).Trim()
    $uri = "$BaseUrl/app/rest/vcs-root-instances/commitHookNotification?locator=vcsRoot:(id:$VcsRootId)"
    $resp = Invoke-WebRequest -Method POST -Uri $uri `
        -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -TimeoutSec 30
    Write-HookLog "POST commitHook -> HTTP $($resp.StatusCode)"
} catch {
    Write-HookLog "ERROR: $($_.Exception.Message)"
}
exit 0
```

- [ ] **Step 2: Verify the hook is fail-safe with no token yet**

Run (the token file does not exist yet — this proves it never throws):
```powershell
pwsh -NoProfile -File .\perforce\triggers\notify-teamcity.ps1 -Change 999 -TokenFile "C:\PerforceSandbox\triggers\does-not-exist.token"
Get-Content C:\PerforceSandbox\triggers\hook.log -Tail 1
```
Expected: exits 0 after ~10s; `hook.log` last line contains `NO TOKEN FILE`. (The dir is created by Task 3; if `Add-Content` can't write yet, the `try/catch` swallows it and it still exits 0 — that's the point.)

- [ ] **Step 3: Write `perforce/triggers/README.md`**

```markdown
# perforce/triggers

The instant-CI hook for Track 2's VCS trigger.

`notify-teamcity.ps1` is registered in p4d as a **change-commit** trigger on
`//game/main/...` (installed idempotently by `ci/scripts/setup-vcs-trigger.ps1`).
On every commit it asks TeamCity to check the VCS root immediately, collapsing
poll latency to ~instant. TeamCity's VCS trigger on Package then fires the chain.

## Install / reinstall

```
pwsh -File ci\scripts\setup-vcs-trigger.ps1
```

This mints the durable token (written to `C:\PerforceSandbox\triggers\teamcity-hook.token`,
**outside this repo**), adds the VCS trigger to Package, and installs the p4d trigger.

## Loop-safety invariant (do not break this)

The build chain emits **TeamCity artifacts** (`build.zip`, `Cooked.pak`, the
tarball) — it never `p4 submit`s back into `//game/main`. That is what keeps
this hook from looping: commit → build → (no commit). **If you ever add a step
that submits build output into a path under `//game/main/...`, this trigger
will re-fire on it and you'll get an infinite build loop.** Submit such output
to a separate depot/path the trigger does not watch, or guard it by user.

## Auth note

The hook uses a durable minted access token, not the superuser token — the
latter rotates every server restart (see `ci/lessons-learned.md` #6, #7).
```

- [ ] **Step 4: Commit**

```powershell
git add perforce/triggers/notify-teamcity.ps1 perforce/triggers/README.md
git commit -m "ci(track2): add change-commit hook (notify-teamcity) + trigger README"
```

---

## Task 3: The idempotent installer (`setup-vcs-trigger.ps1`)

**Files:**
- Create: `ci/scripts/setup-vcs-trigger.ps1`

- [ ] **Step 1: Write `setup-vcs-trigger.ps1`**

```powershell
<#
.SYNOPSIS
  Make the stack instant-CI-ready (idempotent): durable token + VCS trigger on
  Package + p4d change-commit trigger. Re-run after `docker compose down -v`.
.EXAMPLE
  ./setup-vcs-trigger.ps1
#>
param(
    [string]$Token,
    [string]$BaseUrl      = "http://localhost:8111",
    [string]$ProjectId    = "AAASandbox",
    [string]$PackageId    = "AAASandbox_Package",
    [string]$VcsRootId    = "AAASandbox_GameMainStream",
    [string]$HookUser     = "ci-hook",
    [string]$TokenName    = "p4-commit-hook",
    [string]$P4Port       = "localhost:1666",
    [string]$P4User       = "james",
    [string]$TriggerHome  = "C:\PerforceSandbox\triggers",
    [string]$NotifyScript = "J:\jammers-lab\aaa-build-engineering\perforce\triggers\notify-teamcity.ps1"
)
$ErrorActionPreference = "Stop"

# ---------- auth (superuser scrape — same pattern as bootstrap-builds.ps1) ----------
function Get-SuperUserToken {
    $line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log. Pass -Token or set `$env:TEAMCITY_TOKEN."
}
if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))

function Invoke-TC {
    param([string]$Method, [string]$Path, $Body,
          [string]$ContentType = "application/json", [string]$Accept = "application/json")
    $h = @{ Authorization = $auth; Accept = $Accept }
    $p = @{ Method = $Method; Uri = "$BaseUrl$Path"; Headers = $h }
    if ($null -ne $Body) {
        $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $h["Content-Type"] = $ContentType
    }
    Invoke-RestMethod @p
}

# ---------- 1. durable token for a least-privilege ci-hook user ----------
function Ensure-HookUser {
    try {
        Invoke-TC GET "/app/rest/users/username:$HookUser" | Out-Null
        Write-Host "[skip]   user $HookUser exists" -ForegroundColor DarkGray
    } catch {
        Write-Host "[create] user $HookUser" -ForegroundColor Green
        Invoke-TC POST "/app/rest/users" -Body @{ username = $HookUser; name = "CI Commit Hook" } | Out-Null
    }
    # Project Developer includes the "Run build" permission the hook needs.
    # This PUT takes no body — the role + scope are in the path.
    Invoke-TC PUT "/app/rest/users/username:$HookUser/roles/PROJECT_DEVELOPER/p:$ProjectId" | Out-Null
    Write-Host "[role]   PROJECT_DEVELOPER @ p:$ProjectId" -ForegroundColor Green
}
function New-HookToken {
    # token value is returned ONCE; delete+recreate so the cred file is always valid.
    try { Invoke-TC DELETE "/app/rest/users/username:$HookUser/tokens/$TokenName" | Out-Null } catch { }
    $t = Invoke-TC POST "/app/rest/users/username:$HookUser/tokens/$TokenName"
    if (-not $t.value) { throw "token mint returned no value" }
    if (-not (Test-Path $TriggerHome)) { New-Item -ItemType Directory -Path $TriggerHome -Force | Out-Null }
    Set-Content -Path (Join-Path $TriggerHome "teamcity-hook.token") -Value $t.value -NoNewline
    Write-Host "[token]  minted -> $TriggerHome\teamcity-hook.token" -ForegroundColor Green
}

# ---------- 2. VCS trigger on Package ----------
function Ensure-VcsTrigger {
    $existing = Invoke-TC GET "/app/rest/buildTypes/id:$PackageId/triggers"
    if ($existing.trigger | Where-Object { $_.type -eq 'vcsTrigger' }) {
        Write-Host "[skip]   vcsTrigger already on $PackageId" -ForegroundColor DarkGray
        return
    }
    $body = @{ type = "vcsTrigger"; properties = @{ property = @(
        @{ name = "quietPeriodMode"; value = "DO_NOT_USE" }
    )}}
    Invoke-TC POST "/app/rest/buildTypes/id:$PackageId/triggers" -Body $body | Out-Null
    Write-Host "[create] vcsTrigger on $PackageId" -ForegroundColor Green
}

# ---------- 3. p4d change-commit trigger ----------
function Ensure-P4Trigger {
    $current = (& p4 -p $P4Port -u $P4User triggers -o) -join "`n"
    if ($current -match 'check-for-changes-teamcity') {
        Write-Host "[skip]   p4d change-commit trigger present" -ForegroundColor DarkGray
        return
    }
    $line = "`tcheck-for-changes-teamcity change-commit //game/main/... `"pwsh -NoProfile -File $NotifyScript %change%`""
    if ($current -notmatch '(?m)^Triggers:') { $current += "`nTriggers:" }
    $spec = $current + "`n" + $line + "`n"
    $spec | & p4 -p $P4Port -u $P4User triggers -i | Out-Null
    Write-Host "[create] p4d change-commit trigger" -ForegroundColor Green
}

Write-Host "VCS-trigger setup at $BaseUrl" -ForegroundColor Cyan
Ensure-HookUser
New-HookToken
Ensure-VcsTrigger
Ensure-P4Trigger
Write-Host "Done. A submit through the broker to //game/main now fires the chain." -ForegroundColor Cyan
```

- [ ] **Step 2: Run the installer**

Run:
```powershell
pwsh -File .\ci\scripts\setup-vcs-trigger.ps1
```
Expected: `[token] minted`, `[create] vcsTrigger on AAASandbox_Package`, `[create] p4d change-commit trigger`, `Done.`

- [ ] **Step 3: Verify the durable token authenticates**

Run:
```powershell
$tk = (Get-Content -Raw C:\PerforceSandbox\triggers\teamcity-hook.token).Trim()
Invoke-RestMethod -Headers @{Authorization="Bearer $tk";Accept='application/json'} -Uri "http://localhost:8111/app/rest/server" | Select-Object version
```
Expected: prints the server version — the minted Bearer token works.

- [ ] **Step 4: Verify the VCS trigger and p4d trigger exist**

Run:
```powershell
$tok = (docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1") -replace '.*token: (\d+).*','$1'
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$tok"))
(Invoke-RestMethod -Headers @{Authorization=$auth;Accept='application/json'} -Uri "http://localhost:8111/app/rest/buildTypes/id:AAASandbox_Package/triggers").trigger | Format-Table type,id
p4 -p localhost:1666 -u james triggers -o | Select-String 'check-for-changes-teamcity'
```
Expected: a `vcsTrigger` row; and the `check-for-changes-teamcity change-commit //game/main/...` line.

- [ ] **Step 5: Verify idempotency (re-run is all skips)**

Run:
```powershell
pwsh -File .\ci\scripts\setup-vcs-trigger.ps1
```
Expected: `[skip] user`, `[skip] vcsTrigger`, `[skip] p4d change-commit trigger` (the token is re-minted by design — that's fine).

- [ ] **Step 6: Commit**

```powershell
git add ci/scripts/setup-vcs-trigger.ps1
git commit -m "ci(track2): idempotent VCS-trigger installer (token + vcsTrigger + p4d trigger)"
```

---

## Task 4: The policy-gated demo / self-test (`demo-vcs-trigger.ps1`)

**Files:**
- Create: `ci/scripts/demo-vcs-trigger.ps1`

- [ ] **Step 1: Write `demo-vcs-trigger.ps1`**

```powershell
<#
.SYNOPSIS
  Policy-gated end-to-end proof of the VCS trigger. Exits non-zero if either
  case fails, so it doubles as a CI self-test.

.DESCRIPTION
  Case A (allowed): submit as allowlisted build-svc through the broker :1667
    -> broker PASS -> change-commit hook -> chain fires within -FireTimeoutSec, green.
  Case B (frozen-out): submit as non-allowlisted james through :1667
    -> broker REJECT -> no changelist lands, no build within -NoFireWindowSec.

  Admin setup (creating users/clients, seeding the heartbeat file) goes DIRECT
  to p4d :1666 as super james. Only the two TESTED submits go through the broker.
#>
param(
    [string]$Token,
    [string]$BaseUrl    = "http://localhost:8111",
    [string]$PackageId  = "AAASandbox_Package",
    [string]$P4d        = "localhost:1666",
    [string]$Broker     = "localhost:1667",
    [string]$Stream     = "//game/main",
    [string]$AllowUser  = "build-svc",
    [string]$DenyUser   = "james",
    [string]$WsRoot     = "C:\PerforceSandbox\ws",
    [int]$FireTimeoutSec  = 90,
    [int]$NoFireWindowSec = 30
)
$ErrorActionPreference = "Stop"

# ---------- TeamCity read auth (superuser scrape) ----------
function Get-SuperUserToken {
    $line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
    if ($line -match "token: (\d+)") { return $matches[1] }
    throw "No superuser token in teamcity-server.log."
}
if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }
if (-not $Token) { $Token = Get-SuperUserToken }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
$H = @{ Authorization = $auth; Accept = "application/json" }

function Get-LatestPackageId {
    $loc = "buildType:$PackageId,count:1,defaultFilter:false,running:any,canceled:any"
    $f   = "build(id,number,state,status)"
    $r = Invoke-RestMethod -Headers $H -Uri ("$BaseUrl/app/rest/builds?locator={0}&fields={1}" -f `
            [uri]::EscapeDataString($loc), [uri]::EscapeDataString($f))
    if ($r.count -lt 1) { return 0 }
    [int](@($r.build)[0].id)
}
function Wait-NewBuild([int]$Baseline, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $id = Get-LatestPackageId
        if ($id -gt $Baseline) {
            do {
                Start-Sleep -Seconds 3
                $b = Invoke-RestMethod -Headers $H -Uri "$BaseUrl/app/rest/builds/id:$id"
            } while ($b.state -ne 'finished' -and (Get-Date) -lt $deadline)
            return $b
        }
        Start-Sleep -Seconds 4
    }
    return $null
}

# ---------- admin setup (direct to p4d as super james) ----------
function Ensure-Identities {
    "User: $AllowUser`nEmail: $AllowUser@example.invalid`nFullName: Build Service Account`n" |
        & p4 -p $P4d -u james user -f -i | Out-Null
    foreach ($pair in @(@($AllowUser, "$AllowUser-ws"), @($DenyUser, "$DenyUser-ws"))) {
        $owner = $pair[0]; $client = $pair[1]
        $root = Join-Path $WsRoot $owner
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        "Client: $client`nOwner: $owner`nRoot: $root`nStream: $Stream`n" |
            & p4 -p $P4d -u james client -i | Out-Null
    }
    Write-Host "[setup] identities + clients ready" -ForegroundColor DarkGray
}
function Ensure-Heartbeat {
    $env:P4PORT = $P4d; $env:P4USER = "james"; $env:P4CLIENT = "$DenyUser-ws"
    if (-not (& p4 files "$Stream/ci-demo/heartbeat.txt" 2>$null)) {
        $root = Join-Path $WsRoot $DenyUser
        & p4 sync -q "$Stream/..." 2>$null | Out-Null
        $path = Join-Path $root "ci-demo\heartbeat.txt"
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content -Path $path -Value "seed"
        & p4 add "$Stream/ci-demo/heartbeat.txt" | Out-Null
        & p4 submit -d "ci-demo: seed heartbeat" | Out-Null   # direct to p4d, bypasses freeze
        Write-Host "[setup] seeded $Stream/ci-demo/heartbeat.txt" -ForegroundColor DarkGray
    }
}

# ---------- the two cases ----------
function Invoke-CaseA {
    Write-Host "`n== Case A: allowlisted submit fires the chain ==" -ForegroundColor Cyan
    $baseline = Get-LatestPackageId
    $env:P4PORT = $Broker; $env:P4USER = $AllowUser; $env:P4CLIENT = "$AllowUser-ws"
    & p4 sync -q "$Stream/ci-demo/heartbeat.txt" | Out-Null
    & p4 edit "$Stream/ci-demo/heartbeat.txt" | Out-Null
    Add-Content (Join-Path (Join-Path $WsRoot $AllowUser) "ci-demo\heartbeat.txt") ("ping {0}" -f (Get-Date).ToString("s"))
    $out = & p4 submit -d "ci-demo: case A allowed submit" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: allowlisted submit was blocked:`n$out" -ForegroundColor Red; return $false }
    Write-Host "  submit OK through broker; waiting up to ${FireTimeoutSec}s for the chain..."
    $b = Wait-NewBuild $baseline $FireTimeoutSec
    if (-not $b)                  { Write-Host "  FAIL: no new Package build fired" -ForegroundColor Red; return $false }
    if ($b.status -ne 'SUCCESS')  { Write-Host "  FAIL: chain fired but status=$($b.status)" -ForegroundColor Red; return $false }
    Write-Host "  PASS: build #$($b.number) fired and succeeded" -ForegroundColor Green
    return $true
}
function Invoke-CaseB {
    Write-Host "`n== Case B: frozen-out submit fires nothing ==" -ForegroundColor Cyan
    $baseline = Get-LatestPackageId
    $before = (& p4 -p $P4d -u james changes -m1 "$Stream/ci-demo/heartbeat.txt") -join ""
    $env:P4PORT = $Broker; $env:P4USER = $DenyUser; $env:P4CLIENT = "$DenyUser-ws"
    & p4 sync -q "$Stream/ci-demo/heartbeat.txt" | Out-Null
    & p4 edit "$Stream/ci-demo/heartbeat.txt" | Out-Null
    Add-Content (Join-Path (Join-Path $WsRoot $DenyUser) "ci-demo\heartbeat.txt") ("frozen {0}" -f (Get-Date).ToString("s"))
    $out = (& p4 submit -d "ci-demo: case B frozen submit" 2>&1) -join "`n"
    $rejected = $LASTEXITCODE -ne 0
    & p4 revert "$Stream/ci-demo/heartbeat.txt" | Out-Null    # clean the workspace either way
    if (-not $rejected) { Write-Host "  FAIL: frozen-out submit SUCCEEDED (broker did not block)" -ForegroundColor Red; return $false }
    if ($out -notmatch 'freeze|broker|reject') { Write-Host "  WARN: submit failed but message wasn't clearly a broker reject:`n$out" -ForegroundColor Yellow }
    $after = (& p4 -p $P4d -u james changes -m1 "$Stream/ci-demo/heartbeat.txt") -join ""
    if ($after -ne $before) { Write-Host "  FAIL: a changelist landed despite the freeze" -ForegroundColor Red; return $false }
    Write-Host "  rejected as expected; watching ${NoFireWindowSec}s to confirm no build..."
    $b = Wait-NewBuild $baseline $NoFireWindowSec
    if ($b) { Write-Host "  FAIL: a build fired (#$($b.number)) with no committed change" -ForegroundColor Red; return $false }
    Write-Host "  PASS: broker rejected, no changelist, no build" -ForegroundColor Green
    return $true
}

Ensure-Identities
Ensure-Heartbeat
$a = Invoke-CaseA
$b = Invoke-CaseB
Write-Host "`n================ RESULT ================" -ForegroundColor Cyan
Write-Host ("Case A (allowed fires):   {0}" -f $(if ($a) {'PASS'} else {'FAIL'}))
Write-Host ("Case B (frozen no-fire):  {0}" -f $(if ($b) {'PASS'} else {'FAIL'}))
if (-not ($a -and $b)) { exit 1 }
Write-Host "`nVCS trigger verified end-to-end, policy-gated." -ForegroundColor Green
```

- [ ] **Step 2: Run the demo (this is the failing-first check — it exercises everything)**

Run:
```powershell
pwsh -File .\ci\scripts\demo-vcs-trigger.ps1
```
Expected: `Case A (allowed fires): PASS` and `Case B (frozen no-fire): PASS`, exit 0.

Triage if a case fails:
- **Case A: submit blocked** → `build-svc` doesn't match the broker allowlist, or lacks write perm. Check `broker.log` for the reject; confirm `^(buildagent|build-svc|infra-svc)$` in `p4broker.conf` and `p4 protects`.
- **Case A: no build fired** → check `C:\PerforceSandbox\triggers\hook.log` for the POST result; confirm the p4d trigger line (`p4 triggers -o`) and that `pwsh` resolves under p4d (Task 1 Step 4).
- **Case B: submit succeeded** → the broker freeze is not active (Task 1 Step 3).
- **p4 client/stream errors** → if the sandbox p4d requires login, `p4 -p localhost:1666 -u <user> login` first; if a stream client needs a different spec field, adjust the `client -i` form in `Ensure-Identities`.

- [ ] **Step 3: Confirm idempotent re-run still passes**

Run:
```powershell
pwsh -File .\ci\scripts\demo-vcs-trigger.ps1
```
Expected: both cases PASS again (identities/heartbeat already exist → setup is skipped; the heartbeat file is edited, not re-added).

- [ ] **Step 4: Commit**

```powershell
git add ci/scripts/demo-vcs-trigger.ps1
git commit -m "ci(track2): policy-gated end-to-end VCS-trigger demo + self-test"
```

---

## Task 5: Documentation (lesson #7 + README)

**Files:**
- Modify: `ci/lessons-learned.md` (append section #7)
- Modify: `ci/README.md` (document trigger + demo)

- [ ] **Step 1: Append lesson #7 to `ci/lessons-learned.md`**

Append after section #6 (after the final `---`/blank lines), matching the existing format:

```markdown
## 7. Instant CI from Perforce needs a *durable* token — and the vendor auto-detect endpoint assumes a flat network

**What happened:** Wired the VCS trigger so a P4 submit fires the chain
instantly. JetBrains documents a dedicated Perforce post-commit script that
POSTs `/app/perforce/commitHook` with the server's `p4port` and lets TeamCity
**auto-detect** which VCS roots match. Two things bit:

1. The first hook script authenticated with the **superuser token** scraped
   from the log — which rotates every server restart (see #6). The hook worked
   once, then every commit after the next restart silently failed auth.
2. The auto-detect endpoint matches on `p4port`. The hook runs on the p4d host
   where the port reads `localhost:1666`, but TeamCity knows the VCS root as
   `host.docker.internal:1667` (it polls through the broker, from inside a
   container). The strings never match, so auto-detect found **zero** roots and
   notified nothing.

**Root cause:** (1) is a credential-lifetime mismatch — a per-process secret
used for a persistent trigger. (2) is a topology mismatch — the vendor's
convenience endpoint assumes the hook and the server agree on the Perforce
port string, which is false the moment a broker and a container boundary sit
between them.

**Fix:** (1) Mint a **durable access token** for a dedicated least-privilege
`ci-hook` user (Project Developer / *Run build*) and store it outside the repo;
the hook reads that, not the superuser token. (2) Drop the auto-detect endpoint
and POST the **generic** `commitHookNotification?locator=vcsRoot:(id:AAASandbox_GameMainStream)`
instead — naming the root explicitly sidesteps the port-string match entirely.

**Why a build engineer cares:** both are classic "works once, fails on the
automated path" CI bugs. A trigger is long-lived infrastructure; authenticating
it with a secret that rotates guarantees a future silent outage. And vendor
"it just auto-detects" conveniences encode assumptions about your network — the
moment you add a broker, a proxy, or a container boundary (i.e. any real studio
topology), the auto-detect's matching key stops matching and it fails *quietly*,
notifying nothing rather than erroring.

**Interview-ready bullet:** *"For instant CI from Perforce I used a p4d
change-commit trigger that pings TeamCity's commit-hook endpoint. Two gotchas:
authenticate it with a durable minted token, not the superuser token that
rotates each restart; and skip the vendor's auto-detect endpoint that matches
on p4port — once a broker and a container sit between p4d and TeamCity, the port
strings differ and it silently matches nothing. Naming the VCS root explicitly
in the generic commit-hook locator is robust across that topology."*
```

- [ ] **Step 2: Verify the lesson renders and is numbered correctly**

Run:
```powershell
Select-String -Path ci/lessons-learned.md -Pattern '^## \d'
```
Expected: sections `## 1.` through `## 7.` in order, no duplicate numbers.

- [ ] **Step 3: Document the trigger + demo in `ci/README.md`**

Add a section (place it after the build-chain / agents content, matching the file's existing heading style):

```markdown
## Instant CI: VCS trigger (P4 submit → auto-build)

A submit to `//game/main` that passes broker policy auto-fires the whole chain.

**Install (idempotent; re-run after `docker compose down -v`):**

    pwsh -File ci\scripts\setup-vcs-trigger.ps1

This mints a durable TeamCity token for the `ci-hook` user (stored at
`C:\PerforceSandbox\triggers\teamcity-hook.token`, outside the repo), adds a
VCS trigger to Package, and installs a p4d `change-commit` trigger that runs
`perforce/triggers/notify-teamcity.ps1`.

**Demo / self-test (proves both policy halves; exits non-zero on failure):**

    pwsh -File ci\scripts\demo-vcs-trigger.ps1

- Case A: an allowlisted `build-svc` submit through the broker `:1667` fires the
  chain within ~90s, green.
- Case B: a frozen-out `james` submit through `:1667` is rejected by the broker —
  no changelist lands, no build fires.

See `ci/lessons-learned.md` #7 for the durable-token and endpoint-topology gotchas,
and `perforce/triggers/README.md` for the loop-safety invariant.
```

- [ ] **Step 4: Commit**

```powershell
git add ci/lessons-learned.md ci/README.md
git commit -m "docs(track2): lesson #7 (durable token + commit-hook topology) + README"
```

---

## Final verification

- [ ] Run the demo once more from a clean prompt and confirm both cases PASS:

```powershell
pwsh -File .\ci\scripts\demo-vcs-trigger.ps1
```
Expected: `Case A … PASS`, `Case B … PASS`, exit 0.

- [ ] (Optional, proves the reset story) Tear down and rebuild from scratch:

```powershell
docker compose -f ci/docker-compose.yml down -v
pwsh -File .\perforce\scripts\start-p4d.ps1; pwsh -File .\perforce\broker\start-broker.ps1
docker compose -f ci/docker-compose.yml up -d   # wait for healthy + agents
pwsh -File .\ci\scripts\bootstrap-builds.ps1
pwsh -File .\ci\scripts\setup-vcs-trigger.ps1
pwsh -File .\ci\scripts\demo-vcs-trigger.ps1
```
Expected: green chain + both demo cases PASS — instant CI restored in a few commands.

`git push` is human-run (the agent is push-blocked in this repo) — leave the commits local for the human to push.
```
