<#
.SYNOPSIS
  Shared dashboard helpers (dot-sourced, not run).

.DESCRIPTION
  ConvertTo-ConfigBest   — map a [{config,best}, ...] results array to a
                           config-name → best-time hashtable; replaces the
                           two-liner ($r=@{}; results | ForEach { $r[$_.config]=$_.best })
                           that appeared 4 times in collect-metrics.ps1 Get-AccelFeed.

  Format-When / Format-Num — the byte-determinism guards for build-dashboard.ps1.
                           The render must be identical on any host (commit a snapshot,
                           anyone re-renders the same HTML). Two things break that under a
                           foreign locale: dates formatted with the ambient calendar
                           (ar-SA is Hijri → a different month/day) and the -f operator,
                           which honours the culture's decimal separator (de-DE → "4,0").
                           Both helpers pin InvariantCulture (and UTC for dates) so the
                           output is locale-independent. (PowerShell's own [string] casts
                           of dates/numbers are already invariant — only .ToString(fmt)
                           and -f leak the culture, so only those sites need wrapping.)
#>

# Map a results array (each element has .config and .best) to a lookup hashtable
# keyed on the config name. Used by Get-AccelFeed's four switch arms so they don't
# each repeat the two-liner.
function ConvertTo-ConfigBest {
    param([object[]]$Results)
    $h = @{}
    foreach ($x in $Results) { $h[$x.config] = $x.best }
    $h
}

# Format a timestamp to a fixed UTC wall-clock string under InvariantCulture, so the
# render never shifts with the host's calendar or timezone. $When is usually a [datetime]
# (ConvertFrom-Json parses ISO-8601 'Z' strings to Kind=Utc); a raw string is parsed
# as universal. Anything unparseable falls back to its own string form (mirrors the old
# try/catch the call sites used to carry).
function Format-When {
    param($When, [string]$Format = 'MM-dd HH:mm')
    if ($null -eq $When -or "$When" -eq '') { return '' }
    try {
        $dto = if ($When -is [datetime]) { [datetimeoffset]$When }
               else { [datetimeoffset]::Parse([string]$When, [cultureinfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeUniversal) }
        $dto.UtcDateTime.ToString($Format, [cultureinfo]::InvariantCulture)
    } catch { [string]$When }
}

# Format a number under InvariantCulture (period decimal separator) so "{0:N1}" -style
# output is the same on every host. Replaces bare `-f` formatting, which uses the
# ambient culture's separator.
function Format-Num {
    param([double]$Value, [string]$Format = 'N1')
    $Value.ToString($Format, [cultureinfo]::InvariantCulture)
}
