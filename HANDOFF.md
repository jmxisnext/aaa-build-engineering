# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: eee20d0 - refactor(s2): DRY extraction — unreal spine + dashboard config-best helper

## What was just built
- eee20d0 - **Session 2, UE-1 + DB-5:** `Invoke-TimedBuildStep` extracted into `_unreal-common.ps1`
  (stopwatch/tee/metric-emit spine shared by compile/cook/package/buildgraph wrappers; each now
  passes an `-Action` scriptblock + domain `-Metric` fields; `[int]$LASTEXITCODE` coercion ensures
  cmdlet-only pipelines yield 0). New `dashboard/scripts/_dashboard-common.ps1` with
  `ConvertTo-ConfigBest` (replaces the 4× repeated config→best two-liner in `Get-AccelFeed`);
  `build-dashboard.ps1` dot-sources it (forward for S3's `Format-When`). 58 dashboard tests pass;
  all 9 changed scripts parse-clean.
- aee6d78 - **Session 2, AC-1:** `Measure-BestOf` / `Write-SpeedupTable` / `Write-MetricsJson`
  extracted into `accel/scripts/activate-msvc.ps1`; 4 accel bench scripts converted to the shared
  helpers (no behavior change; identical JSON diff confirmed semantically).
- fd36aad - **Session 2, CI-3:** TeamCity REST plumbing (`Get-SuperUserToken` / `Resolve-TeamCityToken`
  / `Connect-TeamCity` / `Invoke-TC`) extracted into `ci/scripts/_ci-common.ps1`; 6 CI scripts
  dot-source it. `{BaseUrl,Auth,Csrf,Session,DryRun}` connection object; `-DryRun` is inert;
  `setup-vcs-trigger.ps1` hook-mint opens its own session. GET-only scripts use only
  `Resolve-TeamCityToken`. Dry-run plan comparison (semantic JSON, sorted keys) confirmed no
  behavior change.

## Live edge
**Session 2 complete.** All S2 audit findings landed (CI-3, AC-1, UE-1, DB-5). Three local commits
await push — human runs `! git push origin main`. Remaining remediation sessions: S3 (DB-1/DB-4/DB-6
dashboard honesty), S4 (UE-3/UE-6/DB-2/DB-3 live Horde stamp run), S5–S6 (minor polish). The
`_dashboard-common.ps1` forward dot-source in `build-dashboard.ps1` is the S3 seam for `Format-When`.

## Next
Start **Session 3 — Dashboard honesty (M-sized, TDD-first).** Steps:
1. Write a failing cross-culture test in `dashboard/tests/`: force de-DE locale + non-UTC TZ at
   thread level, assert byte-equality of the render vs its own en-US/UTC render of the same fixture
   (no frozen literals like `62.2`). Confirm it's RED for the right reason.
2. Add `Format-When` to `dashboard/scripts/_dashboard-common.ps1` using
   `([datetimeoffset]$x).UtcDateTime.ToString('MM-dd HH:mm',[cultureinfo]::InvariantCulture)`;
   replace the 3 date-format copies at `build-dashboard.ps1:88,123,136` (DB-6).
3. Fix footer to use the raw ISO `generatedUtc` string, not culture/TZ-dependent formatting (DB-1).
4. Re-run new test → GREEN; full `build-dashboard.Tests.ps1` + `collect-metrics.Tests.ps1` green.
5. DB-4: render the `accel.link` row (already collected/committed; just wired in); update fixture.
6. Commit: `fix(dashboard): invariant-culture/UTC timestamps via Format-When (DB-1) + render accel.link row (DB-4); add cross-culture render test`
Plan file: `C:\Users\james\.claude\plans\lets-take-these-results-compiled-map.md` (Session 3 section).
