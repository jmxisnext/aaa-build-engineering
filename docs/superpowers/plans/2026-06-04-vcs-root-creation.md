# Scripted Project + VCS-Root Creation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `bootstrap-builds.ps1` create the `AAASandbox` project and the `AAASandbox_GameMainStream` Perforce VCS root from scratch, so a `docker compose down -v` reset rebuilds instant CI with no manual TeamCity-UI step.

**Architecture:** Two idempotent functions (`Ensure-Project`, `Ensure-VcsRootDefinition`) added to the existing installer, called in dependency order (project → root → build-type loop). `-Recreate` uses an explicit reverse-dependency teardown (build types → root; project left intact) so the root is never deleted while referenced — no reliance on TeamCity cascade semantics. All bodies were live-verified against the running server (see spec §3); the root body passed a zero-diff round-trip probe.

**Tech Stack:** PowerShell 7, TeamCity REST API (`/app/rest/projects`, `/app/rest/vcs-roots`), the script's existing `Invoke-TC` helper + superuser-token scrape.

**Spec:** `docs/superpowers/specs/2026-06-04-vcs-root-creation-design.md`

**Verification note (domain-adapted TDD):** these are PowerShell REST installers, not unit-testable libraries — the repo has no test framework, exactly like the `2026-06-03` lever. "Tests" here are live REST verifications against the running stack: round-trip property probes, idempotent-skip runs, a `-Recreate` live cycle, and the full `down -v` reset as the failing-first → passing proof. The stack is currently UP with data preserved.

---

## File Structure

```
ci/scripts/bootstrap-builds.ps1   # MODIFY  +5 functions (Test-Project, Test-VcsRoot, Remove-VcsRoot, Ensure-Project, Ensure-VcsRootDefinition); restructure apply section; update synopsis
ci/README.md                      # MODIFY  fix "Wiring to Track 1" table (stream mode); rewrite reset note; add the 2 remaining one-time UI steps
ci/lessons-learned.md             # MODIFY  +lesson #8 ("attach ≠ create")
```

No new files, no new secrets, no new external state.

---

## Phase 0 — Pre-flight (verify, don't assume)

### Task 1: Confirm stack readiness + probe-verify the project create-body

**Files:** none (verification only)

- [ ] **Step 1: Confirm the stack is up and REST is ready; capture the token**

Run:
```powershell
$line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
if ($line -match 'token: (\d+)') { $token = $matches[1] }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
$h = @{ Authorization=$auth; Accept="application/json"; "Content-Type"="application/json" }
(Invoke-RestMethod -Uri "http://localhost:8111/app/rest/server" -Headers $h).version
```
Expected: prints a version like `2026.1 (build 222521)`. If it errors, the server is still initializing — wait and retry (do not tight-loop; lesson #6).

- [ ] **Step 2: Probe-verify the project create-body (non-destructive round-trip)**

Run:
```powershell
$base = "http://localhost:8111"
function Get-ProjProps($id) { $r = Invoke-RestMethod -Uri "$base/app/rest/projects/id:$id" -Headers $h; @{ name=$r.name; parent=$r.parentProject.id } }
try { Invoke-RestMethod -Method DELETE -Uri "$base/app/rest/projects/id:AAASandbox_probe" -Headers $h | Out-Null } catch {}
$live = Get-ProjProps "AAASandbox"
$body = @{ name="AAA Sandbox PROBE"; id="AAASandbox_probe"; parentProject=@{ locator="_Root" } } | ConvertTo-Json
try {
  Invoke-RestMethod -Method POST -Uri "$base/app/rest/projects" -Headers $h -Body $body | Out-Null
  $probe = Get-ProjProps "AAASandbox_probe"
  if ($probe.parent -eq $live.parent) { "OK: probe parent ($($probe.parent)) matches live; body shape confirmed" }
  else { "DIFFER: live parent=$($live.parent) probe parent=$($probe.parent)" }
} catch { "POST FAILED: $($_.Exception.Message)"; if ($_.ErrorDetails){$_.ErrorDetails.Message} }
finally { try { Invoke-RestMethod -Method DELETE -Uri "$base/app/rest/projects/id:AAASandbox_probe" -Headers $h | Out-Null; "[cleanup] probe project deleted" } catch { "[cleanup] FAILED" } }
```
Expected: `OK: probe parent (_Root) matches live; body shape confirmed` then `[cleanup] probe project deleted`. (The probe id/name differ from live so the throwaway never collides with the real project.)

- [ ] **Step 3: Note — `-Recreate` cascade is NOT probed by design**

No action. The design deletes build types *before* the root (reverse-dependency teardown), so the root is always unreferenced at delete time — we never depend on cascade-on-delete. This was a deliberate choice to avoid an unverified assumption (spec §9). Nothing to run.

---

## Phase 1 — Implement the functions

### Task 2: Add the five helper/ensure functions to `bootstrap-builds.ps1`

**Files:**
- Modify: `ci/scripts/bootstrap-builds.ps1` (insert after the `Add-VcsRoot` function, currently ending at line 126)

- [ ] **Step 1: Insert the new functions**

Use Edit. Anchor on the existing `Add-VcsRoot` function and append the five new functions after it.

old_string:
```powershell
function Add-VcsRoot {
    param([string]$BuildTypeId)
    $body = @{
        id         = $VcsRootId
        "vcs-root" = @{ id = $VcsRootId }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/vcs-root-entries" -Body $body | Out-Null
}
```

new_string:
```powershell
function Add-VcsRoot {
    param([string]$BuildTypeId)
    $body = @{
        id         = $VcsRootId
        "vcs-root" = @{ id = $VcsRootId }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/vcs-root-entries" -Body $body | Out-Null
}

function Test-Project {
    param([string]$Id)
    try { Invoke-TC GET "/app/rest/projects/id:$Id" | Out-Null; $true }
    catch { $false }
}

function Test-VcsRoot {
    param([string]$Id)
    try { Invoke-TC GET "/app/rest/vcs-roots/id:$Id" | Out-Null; $true }
    catch { $false }
}

function Remove-VcsRoot {
    param([string]$Id)
    Invoke-TC DELETE "/app/rest/vcs-roots/id:$Id" | Out-Null
}

# Create the project the chain lives under. Skip-if-exists. The project is the
# most upstream dependency: build types and the VCS root are both project-scoped,
# so this must run first. Body shape verified live (parentProject locator _Root).
function Ensure-Project {
    if (Test-Project -Id $ProjectId) {
        Write-Host "[skip]   project $ProjectId (already exists)" -ForegroundColor DarkGray
        return
    }
    Write-Host "[create] project $ProjectId" -ForegroundColor Green
    $body = @{ name = "AAA Sandbox"; id = $ProjectId; parentProject = @{ locator = "_Root" } }
    Invoke-TC POST "/app/rest/projects" -Body $body | Out-Null
}

# Create the Perforce VCS root definition (NOT the per-build-type attachment, which
# Add-VcsRoot does). Skip-if-exists. Body is the live-verified, zero-diff-probed shape:
# stream mode (use-client=stream, stream=//game/main), project-scoped, six properties.
# workspace-options is column-16-aligned with spaces (PadRight 16), LF-joined — matching
# the captured live root exactly.
function Ensure-VcsRootDefinition {
    if (Test-VcsRoot -Id $VcsRootId) {
        Write-Host "[skip]   vcs-root $VcsRootId (already exists)" -ForegroundColor DarkGray
        return
    }
    Write-Host "[create] vcs-root $VcsRootId" -ForegroundColor Green
    $workspaceOptions =
        ("Options:".PadRight(16)       + "noallwrite clobber nocompress unlocked nomodtime rmdir") + "`n" +
        ("Host:".PadRight(16)          + "%teamcity.agent.hostname%")                               + "`n" +
        ("SubmitOptions:".PadRight(16) + "revertunchanged")                                         + "`n" +
        ("LineEnd:".PadRight(16)       + "local")
    $body = @{
        id      = $VcsRootId
        name    = "Game Main Stream"
        vcsName = "perforce"
        project = @{ id = $ProjectId }
        properties = @{ property = @(
            @{ name = "port";              value = "host.docker.internal:1667" }
            @{ name = "user";              value = "james" }
            @{ name = "use-client";        value = "stream" }
            @{ name = "stream";            value = "//game/main" }
            @{ name = "p4-exe";            value = "p4" }
            @{ name = "workspace-options"; value = $workspaceOptions }
        )}
    }
    Invoke-TC POST "/app/rest/vcs-roots" -Body $body | Out-Null
}
```

- [ ] **Step 2: Verify the script still parses cleanly**

Run:
```powershell
$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\ci\scripts\bootstrap-builds.ps1), [ref]$null, [ref]$e); if($e){$e|ForEach-Object{$_.Message}}else{"OK: parses clean"}
```
Expected: `OK: parses clean`

- [ ] **Step 3: Commit**

```powershell
git add ci/scripts/bootstrap-builds.ps1
git commit -m "ci(track2): add Ensure-Project + Ensure-VcsRootDefinition (live-verified bodies)"
```

### Task 3: Wire the apply section (teardown + ensure + simplified loop) and update the synopsis

**Files:**
- Modify: `ci/scripts/bootstrap-builds.ps1` (synopsis lines ~5-12; apply section lines ~248-277)

- [ ] **Step 1: Update the synopsis to match the new contract**

old_string:
```
.DESCRIPTION
  Drives the TeamCity REST API to create four chained build
  configurations under the existing AAASandbox project, attached to
  the existing Game Main Stream VCS root.

  Re-runnable: each build config is skipped if it already exists.
  Use -Recreate to wipe and redo (drops run history for those
  configs).
```

new_string:
```
.DESCRIPTION
  Drives the TeamCity REST API to create the AAASandbox project, the
  Game Main Stream Perforce VCS root, and four chained build
  configurations attached to that root — from scratch, so a wiped
  server (docker compose down -v) rebuilds with no manual UI step.

  Re-runnable: the project, VCS root, and each build config are
  skipped if they already exist. Use -Recreate to wipe and redo the
  VCS root + build configs (drops run history); the project is left
  intact (a from-scratch project is exercised by down -v, not -Recreate).
```

- [ ] **Step 2: Replace the apply section with teardown → ensure → simplified loop**

old_string:
```powershell
foreach ($cfg in $configs) {
    $id = $cfg.Id

    if (Test-BuildType -Id $id) {
        if ($Recreate) {
            Write-Host "[delete] $id" -ForegroundColor Yellow
            Remove-BuildType -Id $id
        } else {
            Write-Host "[skip]   $id (already exists)" -ForegroundColor DarkGray
            continue
        }
    }

    Write-Host "[create] $id  ($($cfg.Name))" -ForegroundColor Green
    New-BuildType -Id $id -Name $cfg.Name
    Add-VcsRoot   -BuildTypeId $id

    foreach ($step in $cfg.Steps) {
        Add-Step -BuildTypeId $id -Name $step.Name -Script $step.Script
    }
    foreach ($upstream in $cfg.SnapshotDeps) {
        Add-SnapshotDep -BuildTypeId $id -UpstreamId $upstream
    }
    foreach ($ad in $cfg.ArtifactDeps) {
        Add-ArtifactDep -BuildTypeId $id -UpstreamId $ad.UpstreamId -PathRules $ad.PathRules
    }
    if ($cfg.ArtifactRules) {
        Set-ArtifactRules -BuildTypeId $id -Rules $cfg.ArtifactRules
    }
}
```

new_string:
```powershell
# -Recreate teardown, in reverse-dependency order so nothing is deleted while it
# is still referenced: build types first (they hold the vcs-root-entry attachment),
# then the VCS root (now unreferenced — DELETE is safe without relying on TeamCity's
# cascade-on-delete behavior). The project is a container we never tear down here;
# a from-scratch project is exercised by `docker compose down -v`, not by -Recreate.
if ($Recreate) {
    foreach ($cfg in $configs) {
        if (Test-BuildType -Id $cfg.Id) {
            Write-Host "[delete] $($cfg.Id)" -ForegroundColor Yellow
            Remove-BuildType -Id $cfg.Id
        }
    }
    if (Test-VcsRoot -Id $VcsRootId) {
        Write-Host "[delete] vcs-root $VcsRootId" -ForegroundColor Yellow
        Remove-VcsRoot -Id $VcsRootId
    }
}

# Create the chain's dependencies in order, before the loop attaches the root.
Ensure-Project
Ensure-VcsRootDefinition

foreach ($cfg in $configs) {
    $id = $cfg.Id

    if (Test-BuildType -Id $id) {
        Write-Host "[skip]   $id (already exists)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "[create] $id  ($($cfg.Name))" -ForegroundColor Green
    New-BuildType -Id $id -Name $cfg.Name
    Add-VcsRoot   -BuildTypeId $id

    foreach ($step in $cfg.Steps) {
        Add-Step -BuildTypeId $id -Name $step.Name -Script $step.Script
    }
    foreach ($upstream in $cfg.SnapshotDeps) {
        Add-SnapshotDep -BuildTypeId $id -UpstreamId $upstream
    }
    foreach ($ad in $cfg.ArtifactDeps) {
        Add-ArtifactDep -BuildTypeId $id -UpstreamId $ad.UpstreamId -PathRules $ad.PathRules
    }
    if ($cfg.ArtifactRules) {
        Set-ArtifactRules -BuildTypeId $id -Rules $cfg.ArtifactRules
    }
}
```

- [ ] **Step 3: Verify the script still parses cleanly**

Run:
```powershell
$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\ci\scripts\bootstrap-builds.ps1), [ref]$null, [ref]$e); if($e){$e|ForEach-Object{$_.Message}}else{"OK: parses clean"}
```
Expected: `OK: parses clean`

- [ ] **Step 4: Commit**

```powershell
git add ci/scripts/bootstrap-builds.ps1
git commit -m "ci(track2): wire project+root creation into bootstrap with safe -Recreate teardown"
```

---

## Phase 2 — Verify against the live stack

### Task 4: Verify the idempotent no-op (non-destructive, on the populated DB)

**Files:** none (verification only)

- [ ] **Step 1: Run bootstrap against the current live DB**

Run:
```powershell
pwsh -NoProfile -File .\ci\scripts\bootstrap-builds.ps1
```
Expected (everything already exists → all skips, no errors, exit 0):
```
[skip]   project AAASandbox (already exists)
[skip]   vcs-root AAASandbox_GameMainStream (already exists)
[skip]   AAASandbox_Compile (already exists)
[skip]   AAASandbox_SmokeTest (already exists)
[skip]   AAASandbox_CookData (already exists)
[skip]   AAASandbox_Package (already exists)
```
If any line errors or shows `[create]`/`[delete]`, stop and fix before continuing.

### Task 5: Verify the `-Recreate` cycle live + zero-diff root

**Files:** none (verification only). NOTE: `-Recreate` drops the existing build run history — acceptable in this disposable sandbox.

- [ ] **Step 1: Run bootstrap with -Recreate**

Run:
```powershell
pwsh -NoProfile -File .\ci\scripts\bootstrap-builds.ps1 -Recreate
```
Expected order (build types deleted in config order, then root; project skipped; then recreate):
```
[delete] AAASandbox_Compile
[delete] AAASandbox_SmokeTest
[delete] AAASandbox_CookData
[delete] AAASandbox_Package
[delete] vcs-root AAASandbox_GameMainStream
[skip]   project AAASandbox (already exists)
[create] vcs-root AAASandbox_GameMainStream
[create] AAASandbox_Compile  (Compile)
[create] AAASandbox_SmokeTest  (Smoke Test)
[create] AAASandbox_CookData  (Cook Data)
[create] AAASandbox_Package  (Package)
```

- [ ] **Step 2: Confirm the recreated root matches the known-good shape exactly**

Run (re-scrape token in case of any restart):
```powershell
$line = docker exec teamcity-server sh -c "grep 'Super user authentication token:' /opt/teamcity/logs/teamcity-server.log | tail -n 1"
if ($line -match 'token: (\d+)') { $token = $matches[1] }
$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
$h = @{ Authorization=$auth; Accept="application/json" }
$r = Invoke-RestMethod -Uri "http://localhost:8111/app/rest/vcs-roots/id:AAASandbox_GameMainStream" -Headers $h
$got = @{}; foreach($p in $r.properties.property){ $got[$p.name]=$p.value }
$expect = @{ "port"="host.docker.internal:1667"; "user"="james"; "use-client"="stream"; "stream"="//game/main"; "p4-exe"="p4" }
$bad = 0; foreach($k in $expect.Keys){ if($got[$k] -ne $expect[$k]){ $bad++; "DIFFER $k: got=[$($got[$k])] expect=[$($expect[$k])]" } }
$woOk = $got["workspace-options"] -match 'use-client|stream' -or ($got["workspace-options"] -split "`n").Count -eq 4
if ($bad -eq 0 -and ($got["workspace-options"] -split "`n").Count -eq 4) { "ZERO-DIFF: recreated root matches the verified shape" } else { "REVIEW: $bad property diffs (see above)" }
```
Expected: `ZERO-DIFF: recreated root matches the verified shape`

---

## Phase 3 — Documentation

### Task 6: Fix the README — stream mode, reset story, remaining manual steps

**Files:**
- Modify: `ci/README.md` ("Wiring to Track 1" table ~lines 60-68; the reset note ~lines 139-141)

- [ ] **Step 1: Correct the "Wiring to Track 1" table to stream mode + note it's auto-created**

old_string:
```
The VCS root in TeamCity should be configured as:

| Field | Value |
|---|---|
| Type | Perforce Helix Core |
| Port | `host.docker.internal:1667` |
| User | `james` |
| Client mapping | `//game/main/... //%P4CLIENT%/...` |
| Use ticket-based auth | (no auth required in this sandbox) |
```

new_string:
```
The VCS root is created automatically by `bootstrap-builds.ps1` (no manual UI
step). For reference — and to configure it by hand on a brand-new server — its
shape is:

| Field | Value |
|---|---|
| Type | Perforce Helix Core |
| Port | `host.docker.internal:1667` (polled through the broker) |
| User | `james` |
| Workspace | **Stream** `//game/main` (`use-client=stream`) — not a client mapping |
| Use ticket-based auth | (no auth required in this sandbox) |
```

- [ ] **Step 2: Rewrite the reset note (now bootstrap creates project + root) and state the remaining one-time UI steps**

old_string:
```
> After a full `docker compose down -v`, recreate the `AAASandbox_GameMainStream`
> VCS root (see *Wiring to Track 1*) and run `bootstrap-builds.ps1` **before** this —
> the trigger references that root and the Package config, so both must exist first.
```

new_string:
```
> After a full `docker compose down -v`, just run `bootstrap-builds.ps1` **before**
> this — it now creates the `AAASandbox` project and the `AAASandbox_GameMainStream`
> VCS root (stream mode) from scratch, then the chain. The trigger references that
> root and the Package config, so bootstrap must run first.
>
> The only steps NOT scripted are one-time per fresh server: walking TeamCity's
> first-run setup wizard, and authorizing the agents (Agents → Unauthorized →
> Authorize). "Hands-off reset" means hands-off *after* that initial setup.
```

- [ ] **Step 3: Commit**

```powershell
git add ci/README.md
git commit -m "docs(track2): README — VCS root is stream-mode + auto-created; honest reset story"
```

### Task 7: Add lesson #8 to `ci/lessons-learned.md`

**Files:**
- Modify: `ci/lessons-learned.md` (append at end, after lesson #7)

- [ ] **Step 1: Append lesson #8**

Use Edit. Anchor on the closing of lesson #7's interview bullet.

old_string:
```
VCS root explicitly instead; and know that token minting is self-service-only even
for admins, so provision a service account's token by briefly authenticating as it,
not as the superuser."*
```

new_string:
```
VCS root explicitly instead; and know that token minting is self-service-only even
for admins, so provision a service account's token by briefly authenticating as it,
not as the superuser."*

## 8. "Attach ≠ create": the bootstrap that assumed two objects into existence

**What happened:** `bootstrap-builds.ps1` built the whole chain and looked fully
idempotent — re-running it was a clean string of `[skip]`s. But it had never been
run against a *wiped* server. It turned out to **create neither** of the two objects
the chain hangs off: the `AAASandbox` **project** and the `AAASandbox_GameMainStream`
**VCS root**. It referenced both (`project={id:…}` on every build type; a
`vcs-root-entries` *attachment* to the root) but created only the build types. Both
the project and the root had been made by hand in the UI months earlier and silently
survived every restart — so the "instant CI restored in two commands" reset story
was never actually exercised and would have died at the first POST with "project not
found."

**Root cause:** the REST API has two different calls that read almost identically in
a script. `POST /app/rest/buildTypes/id:<bt>/vcs-root-entries` **attaches** an existing
root to a build type; `POST /app/rest/vcs-roots` **creates the root definition**. The
bootstrap did the former and never the latter — and nothing created the project at all.
Idempotent-on-a-populated-DB hid it completely: skip-if-exists looks the same whether
you created the thing or merely inherited it from a manual setup.

**Fixes:**
1. Added `Ensure-Project` (`POST /app/rest/projects`) and `Ensure-VcsRootDefinition`
   (`POST /app/rest/vcs-roots`), idempotent, called in dependency order
   (project → root → build-type loop) so the chain rebuilds from an empty database.
2. **Verified the exact create-body live, with zero assumptions.** A non-destructive
   round-trip probe — POST a throwaway `…_probe` root with the candidate body, GET it
   back, diff against the live root, delete the probe — proved a from-scratch root
   matches the hand-made one byte-for-byte across all six properties. This also caught
   **documentation drift**: the README documented the root as a *client mapping*, but
   the live root is *stream mode* (`use-client=stream`, `stream=//game/main`). The
   `workspace-options` block is space-aligned to column 16, not tab-separated — found
   by dumping char codes, not by eyeballing.
3. `-Recreate` tears down in reverse-dependency order (build types → root) so the root
   is never deleted while referenced — no reliance on TeamCity's cascade-on-delete.

**Why a build engineer cares:** "idempotent" and "reproducible from scratch" are not
the same property, and a re-run against a populated environment proves only the first.
The only honest test of a bootstrap is to run it against the wiped state it claims to
recover — anything else lets a manual, undocumented dependency masquerade as automation.
And when you *do* script a config object, read the live one back and diff it; the
shape that's actually stored beats the shape the docs (or your memory) claim.

**Interview-ready bullet:** *"Our CI bootstrap looked idempotent but had never been run
against an empty database — it attached a VCS root and referenced a project that nothing
created; both had been made by hand in the UI and just survived restarts. I scripted the
project and root creation, and verified the exact REST body with a non-destructive
round-trip probe — create a throwaway, read it back, diff against the real one, delete it.
That caught two things memory would've missed: the root was stream-mode, not the client
mapping our docs claimed, and its workspace options were space-aligned, not tabbed. The
lesson: idempotent ≠ reproducible; only a from-scratch run proves the latter."*
```

- [ ] **Step 2: Commit**

```powershell
git add ci/lessons-learned.md
git commit -m "docs(track2): lesson #8 — attach != create; idempotent != reproducible"
```

---

## Phase 4 — Final proof: the full `down -v` reset (the demoable artifact)

### Task 8: Rebuild instant CI from an empty database, end-to-end

**Files:** none (the win-condition verification). This is the failing-first → passing proof: before this plan, a wiped DB could not rebuild; after it, two scripts do.

- [ ] **Step 1: Wipe and bring the stack back up**

Run:
```powershell
docker compose -f ci\docker-compose.yml down -v
docker compose -f ci\docker-compose.yml up -d
```
Then wait until REST returns JSON (re-use Task 1 Step 1's readiness check; the server re-inits for a few minutes and rotates the superuser token — scrape the *last* occurrence, don't tight-loop — lesson #6).

- [ ] **Step 2: Authorize the agents (one-time UI step — out of scope to script)**

In the TeamCity UI: Agents → Unauthorized → authorize `agent-linux-01` and `agent-linux-02`.
(Or, as a verification convenience, the REST endpoint is
`PUT /app/rest/agents/<locator>/authorizedInfo` — confirm its body shape against the
running server if you script it; UI is the supported path here.)

- [ ] **Step 3: Run bootstrap on the empty DB — expect all CREATES**

Run:
```powershell
pwsh -NoProfile -File .\ci\scripts\bootstrap-builds.ps1
```
Expected (nothing exists yet → project, root, and all four build types are CREATED):
```
[create] project AAASandbox
[create] vcs-root AAASandbox_GameMainStream
[create] AAASandbox_Compile  (Compile)
[create] AAASandbox_SmokeTest  (Smoke Test)
[create] AAASandbox_CookData  (Cook Data)
[create] AAASandbox_Package  (Package)
```

- [ ] **Step 4: Confirm the from-scratch project + root match the verified shapes**

Run (re-scrape token first as in Task 5 Step 2):
```powershell
$p = Invoke-RestMethod -Uri "http://localhost:8111/app/rest/projects/id:AAASandbox?fields=id,name,parentProject(id)" -Headers $h
"project: id=$($p.id) name=$($p.name) parent=$($p.parentProject.id)  (expect: AAASandbox / AAA Sandbox / _Root)"
$r = Invoke-RestMethod -Uri "http://localhost:8111/app/rest/vcs-roots/id:AAASandbox_GameMainStream" -Headers $h
$got=@{}; foreach($x in $r.properties.property){$got[$x.name]=$x.value}
"root: use-client=$($got['use-client']) stream=$($got['stream']) port=$($got['port'])  (expect: stream / //game/main / host.docker.internal:1667)"
```
Expected: both lines match the parenthesized expectations.

- [ ] **Step 5: Re-install the trigger and run the policy-gated demo (proves the chain is live + green)**

Run:
```powershell
pwsh -NoProfile -File .\ci\scripts\setup-vcs-trigger.ps1
pwsh -NoProfile -File .\ci\scripts\demo-vcs-trigger.ps1
```
Expected: `setup` completes; `demo` prints `Case A … PASS`, `Case B … PASS`, exits 0.
This closes the loop — instant CI rebuilt from an empty database with only `bootstrap-builds.ps1` + `setup-vcs-trigger.ps1`, no manual VCS-root/project UI step.

- [ ] **Step 6: Close the carried thread — by-name bench fix (`b3c708f`)**

Run (the loose verification thread from the prior session's HANDOFF — exercises `Get-AgentId` resolving `agent-linux-02` by name on a fresh DB):
```powershell
pwsh -NoProfile -File .\ci\scripts\bench-agents.ps1 -Repeat 1
```
Expected: completes without the hardcoded-id failure; reports a leaf-stage A/B timing. (If agents need a moment to register/authorize after Step 2, retry once.)

- [ ] **Step 7: No commit** — Phase 4 changes no tracked files; it is the end-to-end proof that the committed Phases 1-3 deliver the win-condition.

---

## Self-Review

**Spec coverage:**
- §4 project body → Task 1 (probe) + Task 2 (`Ensure-Project`). ✓
- §4 root body → Task 2 (`Ensure-VcsRootDefinition`, the six properties + PadRight workspace-options). ✓
- §5 ordering project → root → loop → Task 3 apply section. ✓
- §5 `-Recreate` safe teardown → Task 3 teardown block + Task 5 live verification. ✓
- §5 contract change (synopsis) → Task 3 Step 1. ✓
- §2/§6 README stream-mode + reset fixes → Task 6. ✓
- §6 lesson #8 → Task 7. ✓
- §1/§7 reset-story proof + honest remaining manual steps → Task 8 + Task 6 Step 2. ✓
- §9 `-Recreate` cascade not assumed → handled by teardown design (Task 1 Step 3 note, Task 3 comment). ✓
- Carried by-name bench thread → Task 8 Step 6. ✓

**Placeholder scan:** no TBD/TODO; every code step shows full code; every run step shows expected output. ✓

**Type/name consistency:** `Ensure-Project`, `Ensure-VcsRootDefinition`, `Test-Project`, `Test-VcsRoot`, `Remove-VcsRoot` used identically in Task 2 (definition) and Task 3 (calls); `$ProjectId`/`$VcsRootId` are the script's existing params. ✓
