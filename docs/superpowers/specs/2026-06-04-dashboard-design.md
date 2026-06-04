# Design — Build Pipeline Observability Dashboard (Track 4 / Phase 1 step 4)

**Date:** 2026-06-04
**Status:** approved design, pre-implementation
**Roadmap:** `ROADMAP_NEXT.md` Phase 1 step 4 — "Build the dashboard"; closes Track 2's
roadmap dashboard gap and is the #1 cross-portfolio differentiator (audit opp #1).

## Goal / success criterion

A **demoable artifact**: a single self-contained `dashboard.html` that aggregates the
three finished tracks into one build-pipeline observability view, opens offline (no
server, no CDN, no JS framework), and renders from a **committed real snapshot** so it
demos any time — infra up or down. "Here's my build pipeline at a glance: CI health +
changelist provenance, the acceleration scorecard, and the depot/policy setup."

Done when: `collect-metrics.ps1` captures a real snapshot (incl. a real CI build history),
`build-dashboard.ps1` turns it into `dashboard.html`, both are committed, and the HTML
opens in a browser showing all three panels populated from real data.

## Architecture

Collector → committed snapshot → static generator. Only the collector touches live
sources; everything downstream reads the snapshot, so the dashboard is deterministic and
offline-demoable.

```
live sources                     collect-metrics.ps1            build-dashboard.ps1
------------                     ------------------             -------------------
TeamCity REST  ──┐
bench *-Json     ├──(gather)──>  data/snapshot.json  ──(render)──>  dashboard.html
depot-layout.md ─┘                (committed)                        (committed)
```

Both scripts and the artifacts live in a new top-level track directory, sibling to
`accel/`, `ci/`, `perforce/`:

```
dashboard/
  scripts/
    collect-metrics.ps1     # gathers the three feeds -> writes data/snapshot.json
    build-dashboard.ps1     # data/snapshot.json -> dashboard.html (self-contained)
    seed-build-history.ps1  # one-time: drive a real CI build history (wraps ci/ scripts)
  data/
    snapshot.json           # COMMITTED: normalized demo state, all three tracks
  dashboard.html            # COMMITTED: the built artifact (open offline)
  README.md                 # what it is, how to refresh, the data provenance
```

Language: **PowerShell** (matches the repo's all-`.ps1` convention). Output: one HTML file
with **inline CSS + inline SVG**, zero external requests — honors the build constraint
"do not introduce new frameworks unless explicitly requested."

## Data feeds → snapshot

`collect-metrics.ps1` writes a normalized `data/snapshot.json`. Each feed is independent;
a feed that can't be collected (e.g. TeamCity down) falls back to the prior snapshot's
section and is flagged `stale: true` rather than failing the whole collect.

### CI feed (Track 2) — the centerpiece
Source: TeamCity REST `/app/rest/builds`, same auth fallback chain as
`notify-build-failure.ps1` (token via param / `$env:TEAMCITY_TOKEN` / superuser log).
Query the **full** history (all statuses, not just failures) for the AAASandbox project.
Per build capture: `config` (buildType name), `number`, `cl` (P4 changelist via
`revisions.revision.version`), `status` (SUCCESS/FAILURE), `statusText`, `durationSec`
(finishDate − startDate), `finishUtc`, `url` (webUrl). Also capture the config list
(Compile, Smoke Test, Cook Data, Package) for grouping.

### Accel feed (Track 3)
Source: bench-script JSON emits. Add a `-Json <path>` parameter to `bench.ps1`,
`demo-fbuild.ps1`, `bench-link.ps1`, and `bench-bgfx.ps1` that writes the same result
table the script prints, as JSON (config/label → best seconds + speedup). The collector
reads the latest emitted JSON files from a known location (`accel/.metrics/*.json`,
gitignored) and folds them into the snapshot under `accel`. Re-running a bench refreshes
its numbers; the collector never recompiles on its own (keeps a CI refresh fast). If a
bench has never been run, that sub-section is omitted (panel shows only what exists).

### Perforce feed (Track 1)
Source: the live `p4 streams`/`p4 depots` snapshot already embedded in
`perforce/depot-layout.md`, plus the trigger configs. Captured into structured fields:
`streams` (depot/stream graph), `promote` (path), `triggers` (`require-engine-tag` form
trigger, `validate-submit` change-content trigger), `proxy` (p4p cache-hit fact). Parsed
from the existing doc/config — no live p4d required at collect time (it's structural, not
time-series).

### Snapshot schema (sketch)
```json
{
  "generatedUtc": "2026-06-04T17:00:00Z",
  "ci": {
    "configs": ["Compile", "Smoke Test", "Cook Data", "Package"],
    "stale": false,
    "builds": [
      {"config":"Smoke Test","number":45,"cl":45,"status":"FAILURE",
       "statusText":"Exit code 8 ...","durationSec":1.1,"finishUtc":"...","url":"http://..."}
    ]
  },
  "accel": {
    "compile":   {"serial":20.27,"mp":5.10,"unity":0.72,"pchWarm":4.37},
    "fastbuild": {"miss":5.33,"hit":0.37},
    "link":      {"full":0.081,"incremental":0.033,"ltcg":21.8},
    "bgfx":      {"serial":7.57,"mp":1.63,"unity":1.96,"trivialEditPerFile":0.13,"trivialEditUnity":1.96}
  },
  "perforce": {
    "streams": [...], "promote": "...", "triggers": [...], "proxy": {...}, "stale": false
  }
}
```

## Rendering

`build-dashboard.ps1` reads `snapshot.json` and emits `dashboard.html` via here-string
templating with small helpers (`New-SvgBars`, `New-SvgTimeline`, `Html-Encode`). Layout:

```
┌─ AAA Build Pipeline — Observability        generated <snapshot ts> ─┐
│  summary chips: N builds · %green · CL range · accel ✓ · p4 panels   │
├─────────────────────────────────────────────────────────────────────┤
│  CI BUILDS (Track 2) — centerpiece                                   │
│    pass/fail timeline (SVG squares, time-ordered)                    │
│    duration trend (SVG bars, x=build#, y=sec)                        │
│    history table: config│#│CL│status│dur│when│url  (red rows for ✗)  │
├──────────────────────────────────┬──────────────────────────────────┤
│  ACCEL (Track 3)                  │  PERFORCE (Track 1)              │
│   speedup bars (SVG):             │   streams graph, promote path,   │
│    /MP, unity, PCH, FASTBuild,    │   triggers (form + content),     │
│    link, bgfx /MP/unity/incr      │   p4p proxy cache-hit            │
│   caveat: overhead-bound, 8 cores │                                  │
└──────────────────────────────────┴──────────────────────────────────┘
```

Charts are **hand-generated inline SVG** (deterministic, no libraries):
- **Pass/fail timeline** — one green/red square per build, time-ordered (health at a glance).
- **Duration trend** — SVG bar series (x = build #, y = seconds); honest about small abs times.
- **Accel speedup bars** — horizontal bars per lever; a one-line "overhead-bound on 8
  physical cores" caveat carries the REPORT's honesty into the dashboard.

Style: clean dark theme, monospace numerics, semantic color (green/red builds), red
failure rows linking to the TeamCity build URL. A footer states each number's provenance
(CI → TeamCity REST, accel → bench JSON, perforce → depot-layout) so it reads as real
instrumentation. **Determinism:** same snapshot → byte-identical HTML; the "generated"
timestamp is read from the snapshot, not wall-clock.

## Real CI history capture (one-time, per the approved Q3 choice)

`seed-build-history.ps1` brings TeamCity up and drives a real series of ~8–15 builds
across CL 29..46 using the existing `bootstrap-builds.ps1` + `demo-vcs-trigger.ps1`
(re-using the already-built CI chain), producing a mix of green/red builds with real
durations. Then `collect-metrics.ps1` captures the real REST history into `snapshot.json`,
which is committed as the demo state. After capture, infra can be stopped — the committed
snapshot keeps the dashboard demoable.

## Scope / YAGNI

**In scope (v1):** the three feeds, the normalized snapshot, the static generator, the
self-contained HTML with the three panels + the three SVG chart types, the one-time real
CI history capture, the `-Json` emit added to the four bench scripts, a `dashboard/README.md`.

**Out of scope (deliberately):** any live server / auto-refresh / websockets; a REST API
endpoint; historical snapshot retention or diffing over time; auth/multi-user; per-build
log drill-down beyond the URL link; cooking/UE metrics (Phase 2 enrichment, per roadmap);
re-running benches inside the collector. These are notable-but-deferred — add later if a
real need appears.

## Testing / verification

- **Collector:** run against a captured TeamCity history; assert `snapshot.json` parses,
  has ≥1 build with a non-null CL and a positive duration, and that a forced "TeamCity
  down" path falls back to the prior section with `stale:true` instead of throwing.
- **Generator:** run twice on the same snapshot → assert byte-identical HTML (determinism).
  Assert the HTML contains no `http(s)://` resource references except TeamCity build-URL
  links (i.e. self-contained: no CDN/script src). Open it and eyeball all three panels.
- **Bench `-Json`:** assert each emit is valid JSON whose numbers match the printed table.
- **End-to-end:** `seed-build-history` → `collect-metrics` → `build-dashboard` → open
  `dashboard.html`, confirm real builds + accel bars + perforce panel all render.

## Build constraints honored

Runnable/inspectable artifact (the HTML), small/testable/deterministic, no new frameworks
(inline SVG, PowerShell only), every component tied to a real track. Capability progress =
a new demonstrable thing (one-glance pipeline observability), not docs/refactor.
