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
# ---- Track-4 unreal / Lyra pipeline panel ----
Assert-Match 'Unreal / Lyra Pipeline'          $html 'has the Track-4 unreal panel'
Assert-Match '44394996'                         $html 'renders the engine changelist (stamp provenance)'
Assert-Match 'CL\s*51'                          $html 'renders the stamp changelist'
Assert-Match '1432'                             $html 'renders the cook stage duration'
Assert-Match '62\.2'                            $html 'renders the BuildGraph end-to-end duration'
Assert-Match 'cold'                             $html 'has the cook cold-baseline note'
# ---- Horde vs TeamCity orchestrator parity ----
Assert-Match 'Orchestrator parity'              $html 'has the Horde-vs-TeamCity parity section'
Assert-Match 'horde'                            $html 'renders the Horde orchestrator row'
Assert-Match 'teamcity'                         $html 'renders the TeamCity orchestrator row'
Assert-Match '1711'                             $html 'renders the Horde end-to-end duration'
# ---- Track-5 cook panel ----
Assert-Match 'Cook \(Track 5\)' $html 'has the Track-5 cook panel'
Assert-Match 'cached'           $html 'cook panel shows cache hits'
# self-contained: no external script/style/CDN (xmlns + localhost build links are OK)
Assert-NotMatch '<script'                       $html 'no <script> tags'
Assert-NotMatch '<link\s'                       $html 'no <link> stylesheet refs'
Assert-NotMatch 'https://'                      $html 'no https CDN refs'
Assert-NotMatch 'cdn|googleapis|unpkg|jsdelivr' $html 'no known CDN hosts'
# determinism: two renders of the same snapshot are byte-identical
$html2 = Get-DashboardHtml -Snapshot $snap
Assert-Equal $html.Length $html2.Length 'render is deterministic (same length)'
Assert-True  ($html -ceq $html2)        'render is deterministic (byte-identical)'

# ---- DB-1/DB-6: render is byte-identical across locale + timezone ----
# The "commit a snapshot, anyone re-renders the same HTML" contract (dashboard/README.md)
# breaks if the render varies by the host's culture/TZ. The two breakers: date .ToString
# (calendar cultures shift month/day -- ar-SA is Hijri) and the -f number operator (decimal
# separator -- de-DE uses a comma). Re-PARSE + re-render the SAME fixture under a non-en-US
# culture and a non-UTC TZ; bytes must equal the en-US/UTC render. (Re-parse, not just
# re-render, so ConvertFrom-Json's own date handling is exercised under the foreign locale.)
function Get-RenderUnder {
    param([string]$Culture, [string]$Tz, [string]$FixturePath)
    $oc  = [System.Threading.Thread]::CurrentThread.CurrentCulture
    $otz = $env:TZ
    try {
        $env:TZ = $Tz; [System.TimeZoneInfo]::ClearCachedData()
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo($Culture)
        $s = Get-Content $FixturePath -Raw | ConvertFrom-Json
        return (Get-DashboardHtml -Snapshot $s)
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $oc
        $env:TZ = $otz; [System.TimeZoneInfo]::ClearCachedData()
    }
}
$fx       = Join-Path $here "..\data\snapshot.fixture.json"
$baseUtc  = Get-RenderUnder 'en-US' 'UTC'              $fx
$deRender = Get-RenderUnder 'de-DE' 'Asia/Kolkata'     $fx   # Gregorian, comma decimal, +05:30
$arRender = Get-RenderUnder 'ar-SA' 'America/New_York' $fx   # Hijri calendar, arabic decimal, -05:00
Assert-True ($deRender -ceq $baseUtc) 'render is locale-invariant (de-DE/+05:30 == en-US/UTC)'
Assert-True ($arRender -ceq $baseUtc) 'render is locale-invariant (ar-SA/-05:00 == en-US/UTC)'

# ---- DB-4: accel link levers (full/incremental/ltcg) are rendered ----
Assert-Match 'linker:' $html 'renders the accel link row'
Assert-Match '/LTCG'   $html 'renders the LTCG link cost'

Assert-Summary
