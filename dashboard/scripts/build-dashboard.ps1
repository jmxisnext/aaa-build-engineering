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
