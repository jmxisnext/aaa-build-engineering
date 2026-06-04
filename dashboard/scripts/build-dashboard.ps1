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
        "<li><code>$(ConvertTo-HtmlText $t.name)</code> <span class='dim'>$(ConvertTo-HtmlText $t.type)</span> &mdash; $(ConvertTo-HtmlText $t.desc)</li>"
    }
    $proxyLine = if ($p.proxy) { "<p class='note'>p4p proxy: $($p.proxy.cachedMB) MB cached, client B upstream fetches = $($p.proxy.upstreamFetchesClientB)</p>" } else { "" }

    $gen = ConvertTo-HtmlText $Snapshot.generatedUtc

@"
<!doctype html>
<html lang='en'><head><meta charset='utf-8'>
<title>AAA Build Pipeline &mdash; Observability</title>
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
<h1>AAA Build Pipeline &mdash; Observability</h1>
<div class='chips'><b>$($builds.Count)</b> builds &middot; <b>$pct%</b> green &middot; <b>$clRange</b> &middot; accel <b>$([bool]$a.compile)</b> &middot; perforce$pStale</div>

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

<footer>generated $gen &middot; CI &rarr; TeamCity REST &middot; accel &rarr; bench -Json &middot; perforce &rarr; p4 streams/triggers &middot; self-contained, no external requests</footer>
</div></body></html>
"@
}

function Invoke-Main {
    param([string]$Snapshot, [string]$Out)
    $snap = Get-Content $Snapshot -Raw | ConvertFrom-Json
    $html = Get-DashboardHtml -Snapshot $snap
    Set-Content -Path $Out -Value $html -Encoding ascii -NoNewline
    Write-Host "Wrote $Out ($([math]::Round((Get-Item $Out).Length/1KB,1)) KB) from $Snapshot"
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main -Snapshot $Snapshot -Out $Out }
