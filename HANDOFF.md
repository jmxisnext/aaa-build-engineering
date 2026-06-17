# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: c9be38d - fix(dashboard): locale-invariant render via Format-When/Format-Num (DB-1/DB-6) + accel.link row (DB-4)

## What was just built
- c9be38d - **Session 3, DB-1/DB-6/DB-4 (dashboard honesty, TDD).** Made the render
  byte-identical across locale/TZ by code, closing the `dashboard/README.md:82-87` claim.
  Added `Format-When` (UTC + InvariantCulture dates) and `Format-Num` (InvariantCulture
  numbers) to `_dashboard-common.ps1`; wired the 3 date sites + 7 `-f` number sites in
  `build-dashboard.ps1`. New cross-culture regression test re-parses + re-renders the
  fixture under de-DE/+05:30 and ar-SA/-05:00, asserting byte-equality vs en-US/UTC
  (RED 4 asserts -> GREEN). DB-4: rendered the collected-but-unshown linker levers
  (full/incremental/ltcg) as a note; regenerated `dashboard.html`. Suite 37/37 + 24/24.

## Live edge
**Session 3 complete.** Two corrections to the plan, both verified: the footer needed NO
fix (PowerShell `[string]` casts are already invariant), and the real de-DE breaker was the
`-f` decimal separator (numbers), which the plan only anticipated as a date issue - both now
covered. Remaining: S4 (the one expensive live Horde run + DB-2/DB-3), then S5-S6 polish.
**6 commits unpushed** (S1-S3 + 3 closeouts) - human runs `! git push origin main`.

## Next
Start **Session 4 - Horde stamp/metric chain + the ONE live run + DB-2/DB-3 (atomic).**
This is the infra-gated, expensive session - it needs services UP first: p4d on :1666,
the Horde agent, Horde server on :13340, plus the junction/sentinel (hard gate; the server
validates the Perforce cluster at lease-assignment, so p4d must be up). Strict step order
(each HARD-precedes the next, or the single live run is wasted):
1. **UE-3:** add `-Source`/`-Orchestrator` params to `unreal/scripts/buildgraph-lyra.ps1`,
   emit them via the shared `Invoke-TimedBuildStep` spine (from S2); widen
   `stamp-lyra-package.ps1`'s `-Source` ValidateSet `{standalone,teamcity}` ->
   `{standalone,teamcity,horde}` (enum-widen HARD-precedes the Stamp node, else ValidateSet
   errors).
2. Add a **"Stamp Lyra"** node to `unreal/buildgraph/lyra-pipeline.xml`
   (`Requires="Package Lyra"`) invoking `stamp-lyra-package.ps1 -Source horde`; assert it
   writes into the `.metrics` dir `collect-metrics.ps1` scans (not stdout only), or DB-3
   stays empty.
3. **UE-6:** warm the DDC (HARD-precedes the run, for the ~3-4 min warm-cook goal).
4. Run the unmodified graph under Horde **exactly once**; re-collect; apply honest DB-2/DB-3
   dashboard labels (the `source=horde` stamp must not collapse onto the teamcity baseline);
   commit atomically.
Full step list + the strict dependency chain: `C:\Users\james\.claude\plans\lets-take-these-results-compiled-map.md` (Session 4 section).
