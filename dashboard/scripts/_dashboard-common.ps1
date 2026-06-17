<#
.SYNOPSIS
  Shared dashboard helpers (dot-sourced, not run).

.DESCRIPTION
  ConvertTo-ConfigBest   — map a [{config,best}, ...] results array to a
                           config-name → best-time hashtable; replaces the
                           two-liner ($r=@{}; results | ForEach { $r[$_.config]=$_.best })
                           that appeared 4 times in collect-metrics.ps1 Get-AccelFeed.

  Forward-looking stub for build-dashboard.ps1: Format-When (the
  InvariantCulture+UTC date helper, S3/DB-6) will live here once it exists.
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
