# Build Pipeline Observability Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggregate the three finished tracks (CI, accel, perforce) into one self-contained `dashboard.html`, generated from a committed real snapshot, that opens offline and demos any time.

**Architecture:** `collect-metrics.ps1` gathers three feeds (TeamCity REST, bench `-Json` emits, live `p4` queries) into a normalized `data/snapshot.json`; `build-dashboard.ps1` renders that snapshot into a self-contained `dashboard.html` (inline CSS + inline SVG, no JS framework, no CDN). Both the snapshot and the HTML are committed as the demo state.

**Tech Stack:** PowerShell 7 (matches the repo convention), inline SVG, MSVC bench scripts (existing), TeamCity REST + Perforce CLI (existing sandbox infra). Tests are plain `.ps1` assertion scripts (repo convention; no Pester/framework — honors the "no new frameworks" build constraint).

**Spec:** `docs/superpowers/specs/2026-06-04-dashboard-design.md`.

**Conventions for every script in this plan:**
- Scripts that hold testable functions end with a **dot-source guard** so tests can load their functions without running `main`:
  ```powershell
  # at the very bottom of the script
  if ($MyInvocation.InvocationName -ne '.') { Invoke-Main @PSBoundParameters }
  ```
  When dot-sourced (`. ./script.ps1`), `$MyInvocation.InvocationName` is `'.'`, so `main` is skipped. When run (`pwsh -File script.ps1`), it runs.
- All committed JSON is ASCII, `ConvertTo-Json -Depth 8`.
- Run all tests from the repo root: `J:\jammers-lab\aaa-build-engineering`.

---

## File structure

```
dashboard/
  scripts/
    build-dashboard.ps1     # render funcs (Get-DashboardHtml, New-Svg*) + guarded main
    collect-metrics.ps1     # feed funcs (Get-*Feed, Merge-Feed) + guarded main
    seed-build-history.ps1  # operational: drive a real CI build history via ci/ scripts
  tests/
    _assert.ps1             # tiny assertion harness (Assert-Equal/True/Match/Summary)
    build-dashboard.Tests.ps1
    collect-metrics.Tests.ps1
  data/
    snapshot.fixture.json   # committed: small deterministic fixture for tests
    snapshot.json           # committed: the REAL captured demo state (Task 9)
  dashboard.html            # committed: the built artifact
  README.md
accel/scripts/bench.ps1, demo-fbuild.ps1, bench-link.ps1, bench-bgfx.ps1  # +(-Json)
.gitignore                  # + accel/.metrics/
```

---

## Task 1: Scaffold + assertion harness + test fixture

**Files:**
- Create: `dashboard/tests/_assert.ps1`
- Create: `dashboard/data/snapshot.fixture.json`
- Create: `dashboard/scripts/.gitkeep` (placeholder so the dir exists)

- [ ] **Step 1: Create the assertion harness** `dashboard/tests/_assert.ps1`

```powershell
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
```

- [ ] **Step 2: Create the test fixture** `dashboard/data/snapshot.fixture.json`

A small, deterministic snapshot exercising every render path: green + red CI builds across changelists, all accel sub-sections, a perforce panel.

```json
{
  "generatedUtc": "2026-06-04T17:00:00Z",
  "ci": {
    "stale": false,
    "configs": ["Compile", "Smoke Test", "Cook Data", "Package"],
    "builds": [
      {"config":"Compile","number":48,"cl":46,"status":"SUCCESS","statusText":"Success","durationSec":2.4,"finishUtc":"2026-06-04T16:59:48Z","url":"http://localhost:8111/build/420"},
      {"config":"Smoke Test","number":47,"cl":46,"status":"SUCCESS","statusText":"Tests passed: 5","durationSec":1.2,"finishUtc":"2026-06-04T16:59:20Z","url":"http://localhost:8111/build/419"},
      {"config":"Smoke Test","number":45,"cl":45,"status":"FAILURE","statusText":"Exit code 8 (Step: ctest)","durationSec":1.1,"finishUtc":"2026-06-04T16:58:47Z","url":"http://localhost:8111/build/406"},
      {"config":"Package","number":44,"cl":44,"status":"SUCCESS","statusText":"Artifact hoops-brawl-cl44.tar.gz","durationSec":3.1,"finishUtc":"2026-06-04T16:40:00Z","url":"http://localhost:8111/build/402"},
      {"config":"Compile","number":42,"cl":31,"status":"SUCCESS","statusText":"Success","durationSec":2.6,"finishUtc":"2026-06-04T16:20:00Z","url":"http://localhost:8111/build/390"}
    ]
  },
  "accel": {
    "compile":   {"serial":20.27,"mp":5.10,"unity":0.72,"pchWarm":4.37},
    "fastbuild": {"miss":5.33,"hit":0.37},
    "link":      {"full":0.081,"incremental":0.033,"ltcg":21.8},
    "bgfx":      {"serial":7.57,"mp":1.63,"unity":1.96,"trivialEditPerFile":0.13,"trivialEditUnity":1.96}
  },
  "perforce": {
    "stale": false,
    "depots": ["//engine","//game","//tools","//thirdparty","//build","//spec"],
    "streams": [
      {"stream":"//game/main","type":"mainline","parent":"none"},
      {"stream":"//game/dev","type":"development","parent":"//game/main"},
      {"stream":"//game/feature-shotmeter","type":"development","parent":"//game/dev"},
      {"stream":"//game/release-1-0","type":"release","parent":"//game/main"}
    ],
    "triggers": [
      {"name":"require-engine-tag","type":"change-submit","desc":"form-policy: reject submit without an engine tag"},
      {"name":"validate-submit","type":"change-content","desc":"depot-hygiene content validation"}
    ],
    "proxy": {"cachedMB":50,"upstreamFetchesClientB":0}
  }
}
```

- [ ] **Step 3: Create the scripts dir placeholder**

Run: `New-Item -ItemType File -Force dashboard/scripts/.gitkeep`

- [ ] **Step 4: Verify the fixture parses**

Run: `pwsh -NoProfile -Command "Get-Content dashboard/data/snapshot.fixture.json -Raw | ConvertFrom-Json | Select-Object -Expand ci | Select-Object -Expand builds | Measure-Object | Select-Object -Expand Count"`
Expected: `5`

- [ ] **Step 5: Commit**

```bash
git add dashboard/tests/_assert.ps1 dashboard/data/snapshot.fixture.json dashboard/scripts/.gitkeep
git commit -m "feat(track4): dashboard scaffold - assert harness + test fixture"
```

---

## Task 2: SVG chart helpers (TDD)

**Files:**
- Create: `dashboard/scripts/build-dashboard.ps1`
- Create/Test: `dashboard/tests/build-dashboard.Tests.ps1`

- [ ] **Step 1: Write the failing test** `dashboard/tests/build-dashboard.Tests.ps1`

```powershell
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "_assert.ps1")
. (Join-Path $here "..\scripts\build-dashboard.ps1")   # dot-source: defines funcs, guarded main skipped

$builds = @(
    [pscustomobject]@{ number=10; cl=46; status='SUCCESS' },
    [pscustomobject]@{ number=9;  cl=45; status='FAILURE' }
)
$tl = New-SvgTimeline -Builds $builds
Assert-Match '^<svg'            $tl 'timeline is an svg'
Assert-Match '#3fb950'          $tl 'timeline has a green (success) square'
Assert-Match '#f85149'          $tl 'timeline has a red (failure) square'
Assert-Match 'CL46'             $tl 'timeline square has a CL tooltip'

$bars = New-SvgBars -Items @(
    [pscustomobject]@{ label='/MP'; value=4.0; text='4.0x' },
    [pscustomobject]@{ label='unity'; value=28.0; text='28x' }
)
Assert-Match '^<svg'            $bars 'bars is an svg'
Assert-Match '4\.0x'            $bars 'bars renders the /MP label text'
Assert-Match '28x'             $bars 'bars renders the unity label text'

Assert-Summary
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1`
Expected: FAIL — `build-dashboard.ps1` does not exist / `New-SvgTimeline` not defined.

- [ ] **Step 3: Write the minimal implementation** `dashboard/scripts/build-dashboard.ps1`

```powershell
<#
.SYNOPSIS
  Render a committed dashboard snapshot into a single self-contained dashboard.html
  (inline CSS + inline SVG, no JS framework, no CDN). Deterministic: same snapshot ->
  byte-identical HTML (the "generated" timestamp is read from the snapshot, not the clock).
.EXAMPLE
  pwsh -File .\dashboard\scripts\build-dashboard.ps1
  pwsh -File .\dashboard\scripts\build-dashboard.ps1 -Snapshot dashboard\data\snapshot.fixture.json -Out out.html
#>
param(
    [string]$Snapshot = (Join-Path $PSScriptRoot "..\data\snapshot.json"),
    [string]$Out      = (Join-Path $PSScriptRoot "..\dashboard.html")
)
$ErrorActionPreference = "Stop"

function ConvertTo-HtmlText { param([string]$s) [System.Security.SecurityElement]::Escape([string]$s) }

function New-SvgTimeline {
    param([object[]]$Builds, [int]$Size = 16, [int]$Gap = 5)
    $x = 0
    $rects = foreach ($b in $Builds) {
        $fill = if ($b.status -eq 'SUCCESS') { '#3fb950' } else { '#f85149' }
        $tip  = ConvertTo-HtmlText "#$($b.number) CL$($b.cl) $($b.status)"
        $r = "<rect x='$x' y='0' width='$Size' height='$Size' rx='2' fill='$fill'><title>$tip</title></rect>"
        $x += $Size + $Gap
        $r
    }
    $w = [math]::Max($x - $Gap, $Size)
    "<svg width='$w' height='$Size' viewBox='0 0 $w $Size' xmlns='http://www.w3.org/2000/svg'>" + ($rects -join '') + "</svg>"
}

function New-SvgBars {
    param([object[]]$Items, [int]$Width = 240, [int]$RowH = 24)
    $max = ($Items | Measure-Object -Property value -Maximum).Maximum
    if (-not $max -or $max -le 0) { $max = 1 }
    $y = 0
    $rows = foreach ($it in $Items) {
        $bw   = [int][math]::Round($Width * ([double]$it.value / $max))
        if ($bw -lt 1) { $bw = 1 }
        $lbl  = ConvertTo-HtmlText $it.label
        $txt  = ConvertTo-HtmlText $it.text
        "<g transform='translate(0,$y)'>" +
          "<rect x='0' y='4' width='$bw' height='14' rx='2' fill='#388bfd'/>" +
          "<text x='6' y='15' fill='#0d1117' font-size='11' font-family='monospace'>$lbl</text>" +
          "<text x='$($bw + 8)' y='15' fill='#c9d1d9' font-size='11' font-family='monospace'>$txt</text>" +
        "</g>"
        $y += $RowH
    }
    $h = [math]::Max($y, $RowH)
    "<svg width='$($Width + 110)' height='$h' viewBox='0 0 $($Width + 110) $h' xmlns='http://www.w3.org/2000/svg'>" + ($rows -join '') + "</svg>"
}

function New-DurationBars {
    param([object[]]$Builds, [int]$Width = 520, [int]$BarW = 14, [int]$Gap = 6, [int]$Height = 80)
    $max = ($Builds | Measure-Object -Property durationSec -Maximum).Maximum
    if (-not $max -or $max -le 0) { $max = 1 }
    $x = 0
    $bars = foreach ($b in ($Builds | Sort-Object number)) {
        $h    = [int][math]::Round(($Height - 16) * ([double]$b.durationSec / $max))
        if ($h -lt 1) { $h = 1 }
        $fill = if ($b.status -eq 'SUCCESS') { '#2ea043' } else { '#da3633' }
        $tip  = ConvertTo-HtmlText "#$($b.number) $([math]::Round($b.durationSec,2))s"
        $r = "<rect x='$x' y='$($Height - $h)' width='$BarW' height='$h' fill='$fill'><title>$tip</title></rect>"
        $x += $BarW + $Gap
        $r
    }
    $w = [math]::Max($x - $Gap, $BarW)
    "<svg width='$w' height='$Height' viewBox='0 0 $w $Height' xmlns='http://www.w3.org/2000/svg'>" + ($bars -join '') + "</svg>"
}

function Invoke-Main {
    param([string]$Snapshot, [string]$Out)
    $snap = Get-Content $Snapshot -Raw | ConvertFrom-Json
    $html = Get-DashboardHtml -Snapshot $snap
    Set-Content -Path $Out -Value $html -Encoding ascii -NoNewline
    Write-Host "Wrote $Out ($([math]::Round((Get-Item $Out).Length/1KB,1)) KB) from $Snapshot"
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main -Snapshot $Snapshot -Out $Out }
```

> Note: `Get-DashboardHtml` is referenced by `Invoke-Main` but defined in Task 3. Until Task 3, running `main` would error — but the Task-2 test only dot-sources (main skipped) and calls the SVG helpers, so it passes.

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1`
Expected: PASS — `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add dashboard/scripts/build-dashboard.ps1 dashboard/tests/build-dashboard.Tests.ps1
git commit -m "feat(track4): inline-SVG chart helpers (timeline, bars, duration)"
```

---

## Task 3: Full HTML render (TDD)

**Files:**
- Modify: `dashboard/scripts/build-dashboard.ps1` (add `Get-DashboardHtml`)
- Modify: `dashboard/tests/build-dashboard.Tests.ps1` (append render assertions)

- [ ] **Step 1: Append the failing render test** to `dashboard/tests/build-dashboard.Tests.ps1` (before `Assert-Summary`)

```powershell
# ---- full render on the committed fixture ----
$snap = Get-Content (Join-Path $here "..\data\snapshot.fixture.json") -Raw | ConvertFrom-Json
$html = Get-DashboardHtml -Snapshot $snap

Assert-Match '<!doctype html>'                 $html 'is an html document'
Assert-Match 'AAA Build Pipeline'              $html 'has the title'
Assert-Match 'CI BUILDS'                        $html 'has the CI panel'
Assert-Match 'ACCEL'                            $html 'has the accel panel'
Assert-Match 'PERFORCE'                         $html 'has the perforce panel'
Assert-Match 'CL\s*45|>45<'                     $html 'renders a changelist number'
Assert-Match 'hoops-brawl-cl44'                 $html 'renders a build statusText'
Assert-Match 'row-fail|class=.fail'             $html 'failure build gets a fail style hook'
Assert-Match '//game/main'                      $html 'renders the perforce stream graph'
Assert-Match 'validate-submit'                  $html 'renders a perforce trigger'
# self-contained: no external script/style/CDN (xmlns + localhost build links are OK)
Assert-NotMatch '<script'                       $html 'no <script> tags'
Assert-NotMatch '<link\s'                       $html 'no <link> stylesheet refs'
Assert-NotMatch 'https://'                      $html 'no https CDN refs'
Assert-NotMatch 'cdn|googleapis|unpkg|jsdelivr' $html 'no known CDN hosts'
# determinism: two renders of the same snapshot are byte-identical
$html2 = Get-DashboardHtml -Snapshot $snap
Assert-Equal $html.Length $html2.Length 'render is deterministic (same length)'
Assert-True  ($html -ceq $html2)        'render is deterministic (byte-identical)'
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1`
Expected: FAIL — `Get-DashboardHtml` not defined.

- [ ] **Step 3: Implement `Get-DashboardHtml`** — insert into `dashboard/scripts/build-dashboard.ps1` above `Invoke-Main`

```powershell
function Get-DashboardHtml {
    param($Snapshot)

    $ci = $Snapshot.ci
    $builds = @($ci.builds)
    $green  = @($builds | Where-Object { $_.status -eq 'SUCCESS' }).Count
    $pct    = if ($builds.Count) { [int][math]::Round(100.0 * $green / $builds.Count) } else { 0 }
    $cls    = @($builds | ForEach-Object { $_.cl } | Where-Object { $_ -as [int] })
    $clRange = if ($cls.Count) { "CL $([int]($cls | Measure-Object -Minimum).Minimum)-$([int]($cls | Measure-Object -Maximum).Maximum)" } else { "no CL" }
    $ciStale = if ($ci.stale) { " <span class='stale'>(stale)</span>" } else { "" }

    $timeline = New-SvgTimeline -Builds $builds
    $durBars  = New-DurationBars -Builds $builds

    $rows = foreach ($b in $builds) {
        $cssRow = if ($b.status -eq 'SUCCESS') { 'row-ok' } else { 'row-fail' }
        $icon   = if ($b.status -eq 'SUCCESS') { 'OK' } else { 'X' }
        $when   = ([datetime]$b.finishUtc).ToString('MM-dd HH:mm')
        "<tr class='$cssRow'><td>$(ConvertTo-HtmlText $b.config)</td><td class='num'>$($b.number)</td>" +
        "<td class='num'>$($b.cl)</td><td>$icon</td><td>$(ConvertTo-HtmlText $b.statusText)</td>" +
        "<td class='num'>$([math]::Round($b.durationSec,2))s</td><td>$when</td>" +
        "<td><a href='$(ConvertTo-HtmlText $b.url)'>build</a></td></tr>"
    }

    # accel scorecard bars (speedups vs each lever's baseline)
    $a = $Snapshot.accel
    $accelItems = @()
    if ($a.compile)   { $accelItems += [pscustomobject]@{ label='/MP';       value=($a.compile.serial / $a.compile.mp);    text=("{0:N1}x" -f ($a.compile.serial / $a.compile.mp)) }
                        $accelItems += [pscustomobject]@{ label='unity';     value=($a.compile.serial / $a.compile.unity); text=("{0:N1}x" -f ($a.compile.serial / $a.compile.unity)) }
                        $accelItems += [pscustomobject]@{ label='PCH';       value=($a.compile.serial / $a.compile.pchWarm); text=("{0:N1}x" -f ($a.compile.serial / $a.compile.pchWarm)) } }
    if ($a.fastbuild) { $accelItems += [pscustomobject]@{ label='FASTBuild'; value=($a.fastbuild.miss / $a.fastbuild.hit); text=("{0:N1}x" -f ($a.fastbuild.miss / $a.fastbuild.hit)) } }
    if ($a.bgfx)      { $accelItems += [pscustomobject]@{ label='bgfx /MP';  value=($a.bgfx.serial / $a.bgfx.mp);  text=("{0:N1}x (real)" -f ($a.bgfx.serial / $a.bgfx.mp)) }
                        $accelItems += [pscustomobject]@{ label='bgfx unity'; value=($a.bgfx.serial / $a.bgfx.unity); text=("{0:N1}x (real)" -f ($a.bgfx.serial / $a.bgfx.unity)) } }
    $accelBars = if ($accelItems.Count) { New-SvgBars -Items $accelItems } else { "<em>no accel metrics captured</em>" }
    $bgfxIncr = if ($a.bgfx) { "<p class='note'>bgfx single-file edit: per-file $($a.bgfx.trivialEditPerFile)s vs amalgamation $($a.bgfx.trivialEditUnity)s ({0:N0}x)</p>" -f ($a.bgfx.trivialEditUnity / $a.bgfx.trivialEditPerFile) } else { "" }

    # perforce panel
    $p = $Snapshot.perforce
    $pStale = if ($p.stale) { " <span class='stale'>(stale)</span>" } else { "" }
    $streamRows = foreach ($s in @($p.streams)) {
        "<li><code>$(ConvertTo-HtmlText $s.stream)</code> <span class='dim'>$(ConvertTo-HtmlText $s.type)</span></li>"
    }
    $trigRows = foreach ($t in @($p.triggers)) {
        "<li><code>$(ConvertTo-HtmlText $t.name)</code> <span class='dim'>$(ConvertTo-HtmlText $t.type)</span> — $(ConvertTo-HtmlText $t.desc)</li>"
    }
    $proxyLine = if ($p.proxy) { "<p class='note'>p4p proxy: $($p.proxy.cachedMB) MB cached, client B upstream fetches = $($p.proxy.upstreamFetchesClientB)</p>" } else { "" }

    $gen = ConvertTo-HtmlText $Snapshot.generatedUtc

@"
<!doctype html>
<html lang='en'><head><meta charset='utf-8'>
<title>AAA Build Pipeline — Observability</title>
<style>
:root{color-scheme:dark}
body{margin:0;background:#0d1117;color:#c9d1d9;font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
h1{font-size:20px;margin:0 0 4px} h2{font-size:13px;letter-spacing:.08em;color:#8b949e;margin:0 0 12px;text-transform:uppercase}
.chips{margin:8px 0 20px;color:#8b949e;font-size:13px} .chips b{color:#c9d1d9}
.panel{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 18px;margin-bottom:16px}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:16px}
table{width:100%;border-collapse:collapse;font-size:13px} th{text-align:left;color:#8b949e;font-weight:600;border-bottom:1px solid #30363d;padding:6px 8px}
td{padding:6px 8px;border-bottom:1px solid #21262d} .num{font-family:monospace;text-align:right}
.row-fail{background:rgba(248,81,73,.08)} .row-fail td:nth-child(4){color:#f85149;font-weight:700}
.row-ok td:nth-child(4){color:#3fb950;font-weight:700}
a{color:#58a6ff;text-decoration:none} a:hover{text-decoration:underline}
code{font-family:monospace;color:#c9d1d9} .dim{color:#8b949e;font-size:12px} ul{margin:6px 0;padding-left:18px}
.note{color:#8b949e;font-size:12px;margin:8px 0 0} .stale{color:#d29922;font-size:12px}
.svgbox{margin:10px 0;overflow-x:auto} footer{color:#6e7681;font-size:12px;margin-top:18px;border-top:1px solid #21262d;padding-top:12px}
</style></head>
<body><div class='wrap'>
<h1>AAA Build Pipeline — Observability</h1>
<div class='chips'><b>$($builds.Count)</b> builds · <b>$pct%</b> green · <b>$clRange</b> · accel <b>$([bool]$a.compile)</b> · perforce$pStale</div>

<div class='panel'>
<h2>CI Builds (Track 2)$ciStale</h2>
<div class='svgbox'>$timeline</div>
<div class='svgbox'>$durBars</div>
<table><thead><tr><th>config</th><th>#</th><th>CL</th><th>st</th><th>status</th><th>dur</th><th>when</th><th>url</th></tr></thead>
<tbody>$($rows -join "`n")</tbody></table>
</div>

<div class='cols'>
<div class='panel'>
<h2>Accel (Track 3)</h2>
<div class='svgbox'>$accelBars</div>
$bgfxIncr
<p class='note'>speedups vs each lever's baseline; overhead-bound on 8 physical cores.</p>
</div>
<div class='panel'>
<h2>Perforce (Track 1)$pStale</h2>
<div class='dim'>depots: $([string]::Join(' ', @($p.depots)))</div>
<ul>$($streamRows -join '')</ul>
<div class='dim'>triggers</div><ul>$($trigRows -join '')</ul>
$proxyLine
</div>
</div>

<footer>generated $gen · CI → TeamCity REST · accel → bench -Json · perforce → p4 streams/triggers · self-contained, no external requests</footer>
</div></body></html>
"@
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1`
Expected: PASS — `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add dashboard/scripts/build-dashboard.ps1 dashboard/tests/build-dashboard.Tests.ps1
git commit -m "feat(track4): full dashboard HTML render (3 panels, deterministic, self-contained)"
```

---

## Task 4: build-dashboard CLI on the fixture (smoke)

**Files:**
- Use: `dashboard/scripts/build-dashboard.ps1` (no change)

- [ ] **Step 1: Render the fixture to a temp file**

Run: `pwsh -NoProfile -File dashboard/scripts/build-dashboard.ps1 -Snapshot dashboard/data/snapshot.fixture.json -Out dashboard/_preview.html`
Expected: `Wrote ...\_preview.html (N KB) from ...snapshot.fixture.json`

- [ ] **Step 2: Confirm it opens and looks right**

Run: `Start-Process dashboard/_preview.html`
Expected: browser shows the CI panel (timeline + duration bars + history table with one red row), accel speedup bars, perforce panel.

- [ ] **Step 3: Clean up the preview (not committed)**

Run: `Remove-Item dashboard/_preview.html`

> No commit — this task is a manual smoke check. `_preview.html` is throwaway.

---

## Task 5: Add `-Json` emit to the bench scripts

**Files:**
- Modify: `accel/scripts/bench.ps1`
- Modify: `accel/scripts/demo-fbuild.ps1`
- Modify: `accel/scripts/bench-link.ps1`
- Modify: `accel/scripts/bench-bgfx.ps1`
- Modify: `.gitignore`

Each bench already builds a `$results` array of `[pscustomobject]@{ Config; Best }`. Add an opt-in `-Json <path>` that serializes the final results so the collector can read them.

- [ ] **Step 1: Add the param + emit to `bench.ps1`**

Change the param line:
```powershell
param([int]$TU = 32, [int]$Reps = 3, [int]$Chunks = 0, [string]$Json)
```
At the very end of the script (after the print loop), append:
```powershell
if ($Json) {
    $payload = [ordered]@{ sample='compile'; tu=$TU; cores=$cores; generatedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        results=@($results | ForEach-Object { @{ config=$_.Config; best=$_.Best } }) }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $Json -Encoding ascii
    Write-Host "wrote metrics: $Json"
}
```

- [ ] **Step 2: Add the same pattern to `demo-fbuild.ps1`, `bench-link.ps1`, `bench-bgfx.ps1`**

For each: add `[string]$Json` to its `param(...)`, and at the end serialize that script's `$results` with a distinct `sample` tag (`fastbuild`, `link`, `bgfx` respectively). For `bench-bgfx.ps1`, also include the incremental + profile facts it already computes:
```powershell
if ($Json) {
    $payload = [ordered]@{ sample='bgfx'; cores=$cores; generatedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        results=@($results | ForEach-Object { @{ config=$_.Config; best=$_.Best } })
        incremental=@{ heavy=$tHeavy; trivial=$tTriv; unity=$tUnity }
        profile=@{ frontendSec=$fe; backendSec=$be; cgFunctions=$cgFuncs } }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $Json -Encoding ascii
    Write-Host "wrote metrics: $Json"
}
```
(Place it after section C so `$tHeavy/$tTriv/$tUnity/$fe/$be/$cgFuncs` are in scope.)

- [ ] **Step 3: Ignore the collector's metrics drop-dir** — append to `.gitignore`

```
# Track 4 dashboard: bench -Json emits the collector reads (re-generatable)
accel/.metrics/
```

- [ ] **Step 4: Verify the emit produces valid JSON (fast run)**

Run: `pwsh -File accel/scripts/bench.ps1 -TU 4 -Reps 1 -Json $env:TEMP\m.json; pwsh -NoProfile -Command "(Get-Content $env:TEMP\m.json -Raw | ConvertFrom-Json).sample"`
Expected: prints the table, then `compile`.

- [ ] **Step 5: Commit**

```bash
git add accel/scripts/bench.ps1 accel/scripts/demo-fbuild.ps1 accel/scripts/bench-link.ps1 accel/scripts/bench-bgfx.ps1 .gitignore
git commit -m "feat(track4): -Json metrics emit on the bench scripts (dashboard accel feed)"
```

---

## Task 6: Collector feed functions (TDD)

**Files:**
- Create: `dashboard/scripts/collect-metrics.ps1`
- Create/Test: `dashboard/tests/collect-metrics.Tests.ps1`

The collector has pure, testable transform functions (parse a TeamCity REST object → CI feed; fold accel JSON; map `p4 streams` text → streams) plus a `Merge-Feed` that applies the stale-fallback. Live querying lives in `Invoke-Main` (Task 7), untested here.

- [ ] **Step 1: Write the failing test** `dashboard/tests/collect-metrics.Tests.ps1`

```powershell
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

Assert-Summary
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File dashboard/tests/collect-metrics.Tests.ps1`
Expected: FAIL — `collect-metrics.ps1` not found / functions undefined.

- [ ] **Step 3: Implement `dashboard/scripts/collect-metrics.ps1`**

```powershell
<#
.SYNOPSIS
  Gather the three track feeds (CI: TeamCity REST; accel: bench -Json emits; perforce:
  live p4) into dashboard/data/snapshot.json. Each feed independently falls back to the
  prior snapshot's section (marked stale) when its source is unreachable, so a partial
  infra state still produces a complete, committable snapshot.
.EXAMPLE
  pwsh -File .\dashboard\scripts\collect-metrics.ps1
#>
param(
    [string]$BaseUrl   = "http://localhost:8111",
    [string]$Token,
    [string]$ProjectId = "AAASandbox",
    [int]   $Count     = 50,
    [string]$MetricsDir = (Join-Path $PSScriptRoot "..\..\accel\.metrics"),
    [string]$Out        = (Join-Path $PSScriptRoot "..\data\snapshot.json")
)
$ErrorActionPreference = "Stop"

function ConvertFrom-TcBuilds {
    param([object[]]$Builds)
    foreach ($b in $Builds) {
        $cl = if ($b.revisions.revision) { [int](@($b.revisions.revision)[0].version) } else { $null }
        $dur = $null
        if ($b.startDate -and $b.finishDate) {
            $fmt = "yyyyMMddTHHmmsszzz"
            try {
                $s = [datetimeoffset]::ParseExact(($b.startDate  -replace '(\+\d{2})(\d{2})$','$1:$2'), $fmt, $null)
                $f = [datetimeoffset]::ParseExact(($b.finishDate -replace '(\+\d{2})(\d{2})$','$1:$2'), $fmt, $null)
                $dur = [math]::Round(($f - $s).TotalSeconds, 2)
            } catch { $dur = $null }
        }
        [pscustomobject]@{
            config      = $b.buildType.name
            number      = [int]$b.number
            cl          = $cl
            status      = $b.status
            statusText  = $b.statusText
            durationSec = $dur
            finishUtc   = $b.finishDate
            url         = $b.webUrl
        }
    }
}

function ConvertFrom-P4Streams {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n" | Where-Object { $_ -match '^Stream\s' })) {
        # Stream <path> <type> <parent> '<desc>'
        $parts = $line -split '\s+', 5
        [pscustomobject]@{ stream = $parts[1]; type = $parts[2]; parent = $parts[3] }
    }
}

function Get-AccelFeed {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $acc = [ordered]@{}
    foreach ($f in Get-ChildItem $Dir -Filter *.json -ErrorAction SilentlyContinue) {
        $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
        switch ($m.sample) {
            'compile'   { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.compile = @{ serial=$r['serial (per-TU)']; mp=$r['/MP (per-TU)']; unity=$r['unity (1 file)']; pchWarm=$r['PCH warm + /MP'] } }
            'fastbuild' { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.fastbuild = @{ miss=$r['clean (cache miss)']; hit=$r['clean (cache HIT)'] } }
            'link'      { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.link = @{ full=$r['full /INCREMENTAL:NO']; incremental=$r['incremental']; ltcg=$r['/LTCG (/GL objs)'] } }
            'bgfx'      { $r=@{}; $m.results | ForEach-Object { $r[$_.config]=$_.best }
                          $acc.bgfx = @{ serial=$r['serial (per-file)']; mp=$r['/MP (per-file)']; unity=$r['unity (amalgamated)']
                              trivialEditPerFile=$m.incremental.trivial; trivialEditUnity=$m.incremental.unity } }
        }
    }
    if ($acc.Count -eq 0) { return $null }
    [pscustomobject]$acc
}

function Merge-Feed {
    param($New, $Prior)
    if ($null -ne $New) { return $New }
    if ($null -eq $Prior) { return $null }
    # clone prior section and mark stale
    $obj = $Prior | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $obj | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
    return $obj
}

# ---- live collectors (used by Invoke-Main; not unit-tested) ----
function Get-CiFeed {
    param([string]$BaseUrl, [string]$Token, [string]$ProjectId, [int]$Count)
    $headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token")); Accept = "application/json" }
    $fields  = "build(number,status,statusText,buildTypeId,buildType(name),webUrl,startDate,finishDate,revisions(revision(version)))"
    $locator = "affectedProject:(id:$ProjectId),state:finished,count:$Count"
    $resp = Invoke-RestMethod -Method GET -Uri "$BaseUrl/app/rest/builds?locator=$locator&fields=$fields" -Headers $headers -TimeoutSec 10
    $builds = ConvertFrom-TcBuilds -Builds @($resp.build)
    $configs = @($builds | ForEach-Object { $_.config } | Sort-Object -Unique)
    [pscustomobject]@{ stale=$false; configs=$configs; builds=$builds }
}
function Get-PerforceFeed {
    $streams = ConvertFrom-P4Streams -Text (p4 streams 2>$null | Out-String)
    $depots  = @(p4 depots 2>$null | ForEach-Object { ($_ -split '\s+')[1] } | Where-Object { $_ })
    if (-not $streams) { return $null }
    [pscustomobject]@{ stale=$false; depots=$depots; streams=@($streams); triggers=@(); proxy=$null }
}

function Invoke-Main {
    param($BaseUrl, $Token, $ProjectId, $Count, $MetricsDir, $Out)
    $prior = if (Test-Path $Out) { Get-Content $Out -Raw | ConvertFrom-Json } else { $null }
    if (-not $Token) { $Token = $env:TEAMCITY_TOKEN }

    $ci = $null
    try { if ($Token) { $ci = Get-CiFeed -BaseUrl $BaseUrl -Token $Token -ProjectId $ProjectId -Count $Count } }
    catch { Write-Warning "CI feed: $($_.Exception.Message) -- falling back to prior snapshot" }
    $accel = Get-AccelFeed -Dir $MetricsDir
    $p4 = $null
    try { $p4 = Get-PerforceFeed } catch { Write-Warning "perforce feed: $($_.Exception.Message)" }

    $snap = [ordered]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        ci       = Merge-Feed -New $ci    -Prior $prior.ci
        accel    = Merge-Feed -New $accel -Prior $prior.accel
        perforce = Merge-Feed -New $p4    -Prior $prior.perforce
    }
    $snap | ConvertTo-Json -Depth 8 | Set-Content -Path $Out -Encoding ascii
    Write-Host "wrote $Out (ci stale=$($snap.ci.stale) accel=$([bool]$snap.accel) perforce stale=$($snap.perforce.stale))"
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -BaseUrl $BaseUrl -Token $Token -ProjectId $ProjectId -Count $Count -MetricsDir $MetricsDir -Out $Out
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File dashboard/tests/collect-metrics.Tests.ps1`
Expected: PASS — `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add dashboard/scripts/collect-metrics.ps1 dashboard/tests/collect-metrics.Tests.ps1
git commit -m "feat(track4): collector feed transforms (CI/accel/perforce) + stale fallback"
```

---

## Task 7: seed-build-history (operational wrapper)

**Files:**
- Create: `dashboard/scripts/seed-build-history.ps1`

This brings TeamCity up and drives a real build history by re-using the existing `ci/scripts`. It is operational (needs Docker + infra), so it is verified by the end-to-end run in Task 9, not a unit test. It must be safe to read (param-validated, `-WhatIf`-style dry run).

- [ ] **Step 1: Implement `dashboard/scripts/seed-build-history.ps1`**

```powershell
<#
.SYNOPSIS
  Drive a real CI build history for the dashboard demo: bring TeamCity up, ensure the
  AAASandbox chain exists, and trigger a series of builds across changelists (mix of
  pass/fail) so the CI panel has a real trend to show. Re-uses ci/scripts wholesale.
.EXAMPLE
  pwsh -File .\dashboard\scripts\seed-build-history.ps1 -DryRun
  pwsh -File .\dashboard\scripts\seed-build-history.ps1 -Builds 12
#>
param([int]$Builds = 12, [switch]$DryRun)
$ErrorActionPreference = "Stop"
$ci = (Resolve-Path (Join-Path $PSScriptRoot "..\..\ci")).Path

$plan = @(
    "docker compose -f $ci\docker-compose.yml up -d        # TeamCity server + 2 agents"
    "pwsh -File $ci\scripts\bootstrap-builds.ps1            # ensure AAASandbox chain exists"
    "pwsh -File $ci\scripts\demo-vcs-trigger.ps1            # drive builds across CLs (some red)"
    "pwsh -File $ci\scripts\notify-build-failure.ps1        # capture failures (sanity)"
)
Write-Host "seed-build-history plan ($Builds builds target):`n"
$plan | ForEach-Object { Write-Host "  $_" }
if ($DryRun) { Write-Host "`n-DryRun: nothing executed."; return }

Write-Host "`nBringing infra up + driving builds (this takes several minutes)..."
& docker compose -f "$ci\docker-compose.yml" up -d
pwsh -File "$ci\scripts\bootstrap-builds.ps1"
pwsh -File "$ci\scripts\demo-vcs-trigger.ps1"
Write-Host "Done. Now run collect-metrics.ps1 to capture the history."
```

> If `demo-vcs-trigger.ps1`'s parameters differ, adjust the call — the intent is "trigger a spread of builds." Inspect `ci/scripts/demo-vcs-trigger.ps1 -?` first.

- [ ] **Step 2: Verify the dry run lists the plan**

Run: `pwsh -NoProfile -File dashboard/scripts/seed-build-history.ps1 -DryRun`
Expected: prints the 4-step plan, executes nothing.

- [ ] **Step 3: Commit**

```bash
git add dashboard/scripts/seed-build-history.ps1
git commit -m "feat(track4): seed-build-history operational wrapper (real CI history)"
```

---

## Task 8: README

**Files:**
- Create: `dashboard/README.md`

- [ ] **Step 1: Write `dashboard/README.md`**

Cover: what it is (one-glance pipeline observability across the 3 tracks); the pipeline (`collect-metrics` → `snapshot.json` → `build-dashboard` → `dashboard.html`); how to refresh (run the seed + collector when infra is up; re-run any bench with `-Json accel/.metrics/<x>.json` to refresh accel); the determinism + provenance guarantees; that `snapshot.json` and `dashboard.html` are committed as the demo state and open offline. Include the reproduce commands and a one-line note that numbers trace to their source.

- [ ] **Step 2: Commit**

```bash
git add dashboard/README.md
git commit -m "docs(track4): dashboard README"
```

---

## Task 9: End-to-end real capture + commit the demo state

**Files:**
- Create (committed): `dashboard/data/snapshot.json`, `dashboard/dashboard.html`

This is the demoable milestone: real CI history + real accel numbers captured and committed.

- [ ] **Step 1: Refresh accel metrics** (re-uses the Track-3 benches; needs MSVC)

```powershell
. .\accel\scripts\activate-msvc.ps1
New-Item -ItemType Directory -Force accel\.metrics | Out-Null
pwsh -File .\accel\scripts\bench.ps1        -Json accel\.metrics\compile.json
pwsh -File .\accel\scripts\demo-fbuild.ps1  -Json accel\.metrics\fastbuild.json
pwsh -File .\accel\scripts\bench-link.ps1   -Json accel\.metrics\link.json
pwsh -File .\accel\scripts\bench-bgfx.ps1   -Json accel\.metrics\bgfx.json
```
Expected: four JSON files under `accel/.metrics/` (gitignored).

- [ ] **Step 2: Drive a real CI history + capture it**

```powershell
pwsh -File .\dashboard\scripts\seed-build-history.ps1 -Builds 12
pwsh -File .\dashboard\scripts\collect-metrics.ps1
```
Expected: `dashboard/data/snapshot.json` written; `ci stale=False`, accel present, `perforce stale=False`. If TeamCity didn't come up, the CI section falls back stale — fix infra and re-run before committing (the demo state must be real).

- [ ] **Step 3: Verify the captured snapshot is real**

Run: `pwsh -NoProfile -Command "$s=gc dashboard/data/snapshot.json -Raw|ConvertFrom-Json; '{0} builds, ci.stale={1}, accel.bgfx.mp={2}' -f @($s.ci.builds).Count,$s.ci.stale,$s.accel.bgfx.mp"`
Expected: e.g. `12 builds, ci.stale=False, accel.bgfx.mp=1.63` — non-zero builds, not stale.

- [ ] **Step 4: Build the dashboard from the real snapshot**

Run: `pwsh -File dashboard/scripts/build-dashboard.ps1`
Expected: `Wrote ...\dashboard.html (N KB) from ...snapshot.json`.

- [ ] **Step 5: Open it and confirm all three panels are real**

Run: `Start-Process dashboard/dashboard.html`
Expected: real build history (mixed green/red, real durations, real CLs), accel bars from the captured benches, perforce streams/depots. Then `docker compose -f ci/docker-compose.yml stop` to release infra.

- [ ] **Step 6: Run the full test suite once more (no regressions)**

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1; pwsh -NoProfile -File dashboard/tests/collect-metrics.Tests.ps1`
Expected: both `ALL PASS`.

- [ ] **Step 7: Commit the demo state**

```bash
git add dashboard/data/snapshot.json dashboard/dashboard.html
git commit -m "feat(track4): capture real snapshot + built dashboard (demo state)"
```

---

## Task 10: Wire into the roadmap + repo README

**Files:**
- Modify: `ROADMAP_NEXT.md` (mark Phase 1 step 4 done)
- Modify: `README.md` (repo root — add the dashboard track)

- [ ] **Step 1: Mark Phase 1 step 4 done in `ROADMAP_NEXT.md`**

Under "Phase 1 — LOCKED", append to item 4 a `→ 2026-06-04: DONE.` note summarizing: collector→snapshot→static HTML, all three tracks, real captured CI history, inline-SVG (no framework), `dashboard/dashboard.html` the committed demo artifact.

- [ ] **Step 2: Add the dashboard to the repo-root `README.md`** track list (one row/line, consistent with the existing per-track entries).

- [ ] **Step 3: Commit**

```bash
git add ROADMAP_NEXT.md README.md
git commit -m "docs(track4): mark Phase 1 step 4 (dashboard) done; close out Phase 1"
```

---

## Self-review notes (author)

- **Spec coverage:** collector (T6/T7), snapshot (T1 fixture, T9 real), generator (T2/T3/T4), three feeds (CI T6, accel T5/T6, perforce T6), real CI history (T7/T9), determinism + self-contained (T3 tests), README (T8), out-of-scope respected (no server/REST/UE). ✓
- **Refinement vs spec:** perforce feed queries live `p4` with stale-fallback (mirrors CI) instead of parsing `depot-layout.md` — more real, less brittle; noted to the user.
- **Known follow-ups for the executor:** confirm `demo-vcs-trigger.ps1` parameters (T7 step 1 note); the exact `$results` config labels each bench uses must match the `Get-AccelFeed` switch keys — verify against the live `-Json` output in T5/T9 and adjust the key strings if a label differs.
