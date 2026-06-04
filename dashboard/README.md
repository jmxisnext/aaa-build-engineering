# dashboard/ — Track 4: build-pipeline observability

**Goal:** one self-contained `dashboard.html` that shows the whole pipeline at a
glance — the three finished tracks (CI, accel, perforce) on a single page,
built from a committed real snapshot, that **opens offline and demos any time**.
No server, no build step at view time, no external requests.

This is the capstone view for the repo: it doesn't add a new build capability,
it *aggregates* the ones the earlier tracks proved and makes them legible in
one screen — the "here's the pipeline I built" artifact you point an interviewer at.

## The pipeline

```
  TeamCity REST ─┐
  bench -Json   ─┼─►  collect-metrics.ps1  ─►  data/snapshot.json  ─►  build-dashboard.ps1  ─►  dashboard.html
  p4 streams    ─┘     (gather + normalize)      (committed state)        (render, no JS)        (committed artifact)
```

Two stages, deliberately split so the *capture* (needs infra) is separate from
the *render* (pure, deterministic, runs anywhere):

1. **`collect-metrics.ps1`** queries the three feeds and writes a normalized
   `data/snapshot.json`. Each feed independently falls back to the prior
   snapshot's section (marked `stale`) if its source is unreachable — so a
   partial infra state still produces a complete, committable snapshot.
2. **`build-dashboard.ps1`** renders that snapshot into `dashboard.html` —
   inline CSS + inline SVG, **no JS framework, no CDN, no `<link>`/`<script>`**.

Both `snapshot.json` and `dashboard.html` are committed as the demo state.

## What's here

| Path | What |
|---|---|
| `scripts/collect-metrics.ps1` | Gathers the three feeds (CI: TeamCity REST · accel: `bench -Json` emits · perforce: live `p4`) into `data/snapshot.json`, with per-feed stale-fallback. Pure transforms (`ConvertFrom-TcBuilds`, `ConvertFrom-P4Streams`, `Get-AccelFeed`, `Merge-Feed`) are unit-tested. |
| `scripts/build-dashboard.ps1` | Renders a snapshot into a single self-contained `dashboard.html`. Inline SVG helpers (`New-SvgTimeline`, `New-SvgBars`, `New-DurationBars`) + `Get-DashboardHtml`. Deterministic. |
| `scripts/seed-build-history.ps1` | Operational: brings TeamCity up, bootstraps the AAASandbox chain, and drives `-Builds` real changelist/chain runs so the CI panel has a real trend. Re-uses `ci/scripts` wholesale. `-DryRun` prints the plan without touching infra. |
| `data/snapshot.fixture.json` | Small deterministic fixture exercising every render path (green + red CI builds across changelists, all accel sub-sections, the perforce panel). Drives the render tests. |
| `data/snapshot.json` | **Committed demo state** — the real captured snapshot. |
| `dashboard.html` | **Committed artifact** — the built page. Open it directly in a browser; no server. |
| `tests/_assert.ps1` | Tiny throw-on-failure assertion harness (repo convention; no Pester). |
| `tests/build-dashboard.Tests.ps1` | Render tests: SVG helpers, full HTML on the fixture, self-contained checks, byte-determinism. |
| `tests/collect-metrics.Tests.ps1` | Collector transform tests: REST→CI, `p4 streams`→streams, stale-fallback. |

## Reproduce

Run tests (pure-local, no infra) from the repo root:

```powershell
pwsh -File dashboard/tests/build-dashboard.Tests.ps1
pwsh -File dashboard/tests/collect-metrics.Tests.ps1
```

Re-render the committed snapshot (or preview the fixture):

```powershell
pwsh -File dashboard/scripts/build-dashboard.ps1
pwsh -File dashboard/scripts/build-dashboard.ps1 -Snapshot dashboard/data/snapshot.fixture.json -Out dashboard/_preview.html
```

Refresh the **real** state (needs the sandbox infra + MSVC):

```powershell
# accel feed — re-run any bench with -Json into the collector's drop-dir (gitignored)
. .\accel\scripts\activate-msvc.ps1
New-Item -ItemType Directory -Force accel\.metrics | Out-Null
pwsh -File .\accel\scripts\bench.ps1       -Json accel\.metrics\compile.json
pwsh -File .\accel\scripts\demo-fbuild.ps1 -Json accel\.metrics\fastbuild.json
pwsh -File .\accel\scripts\bench-link.ps1  -Json accel\.metrics\link.json
pwsh -File .\accel\scripts\bench-bgfx.ps1  -Json accel\.metrics\bgfx.json

# CI + perforce feeds — drive a real history, then collect, then render
pwsh -File .\dashboard\scripts\seed-build-history.ps1 -Builds 12
pwsh -File .\dashboard\scripts\collect-metrics.ps1
pwsh -File .\dashboard\scripts\build-dashboard.ps1
```

## Guarantees

- **Deterministic render.** The "generated" timestamp is read from the snapshot,
  not the clock, so the same `snapshot.json` produces byte-identical `dashboard.html`
  (asserted in the render tests). Diffs in the committed HTML mean the data changed.
- **Self-contained.** No `<script>`, no `<link>`, no `https://`/CDN refs — the page
  is one file that opens offline. ASCII output (Unicode glyphs are HTML entities),
  so no encoding surprises across machines.
- **Provenance.** Every number traces to its source: CI → TeamCity REST, accel →
  the `bench -Json` emit that produced it, perforce → live `p4 streams`/`depots`.
  Nothing on the page is hand-entered; re-running the pipeline regenerates it.
