# Capstone — the cross-track spine, exercised end-to-end

**Value proposition:** *I built an AAA-shaped build pipeline — real VCS + branch policy, CI on
submit, a content-addressed cook, version-stamped packages, observable on a dashboard — and here's
the one command that drives the spine and proves it.*

This is the cap on Tracks 1–5. It doesn't add a new component; it **stitches the proven pieces into
one scripted, asserted, end-to-end demo** with provenance and observability. The demoable artifact
is the *cross-track spine (Tracks 1, 2, 5 + observability) exercised live on the sandbox stack* —
accel (Track 3) and unreal/Horde (Track 4) are surfaced on the dashboard, not re-run by this command.

```
pwsh -File capstone\demo-capstone.ps1
```

One green run = the Capstone. The script asserts every stage and exits non-zero if anything fails,
so it doubles as an integration self-test.

---

## What it demonstrates — point at four things

1. **Provenance** — a Perforce changelist flows all the way to a CL-version-stamped artifact
   (`hoops-brawl-cl<N>.tar.gz`), and the bundled `build-info.json` ties `CL → TeamCity build →
   artifact` together.
2. **Observability** — the dashboard's CI and Cook panels reflect *this exact run* after the demo
   regenerates the dashboard: the CI panel live from TeamCity, the Cook panel from the `cook-stats`
   artifact the demo just pulled into `pipeline/.metrics/`.
3. **Content-addressed cook** — the real cooker runs with warm-cache semantics; the Cook (Track 5)
   panel shows cooked-vs-cached. Warm reuse (cache hits) requires a *prior* successful `Cook Assets`
   build whose CAS gets restored — so the **first run on a fresh stack cooks cold (still green);
   re-run to demonstrate cache hits**.
4. **Ephemeral CI** — *scripted-disposable agent is Slice 2 (stretch)*; this Slice-1 run uses the
   standing compose agent. See **Roadmap** below.

---

## Two halves of one repo

The demo is honest about which cook is real:

### (A) Pipeline mechanics — the hoops spine
A tracked change is submitted to `//game/main` **through the policy broker** (`:1667`) → TeamCity's
VCS trigger auto-fires the chain **Compile → (Smoke Test ‖ Cook Data) → Package** → the Package step
**version-stamps** the build → a **CL-stamped tarball** is published. The chain's cook here is the
**toy `hoops_cooker`** (concatenates `Data/*.txt`) — it's only a stand-in so Package has content to
bundle. This half proves the *mechanics*: policy gate, CI-on-submit, fan-out, version-stamp, package.

### (B) The real cook — `Cook Assets`
The standalone **`Cook Assets`** config runs the **content-addressed cooker** (Track 5): it restores
the prior build's CAS via a self artifact-dependency, recooks only what changed, and a warm build
reuses unchanged assets as **cache hits**. This is the DDC/CAS story. It stays **additive** — it is
*not* merged into the hoops chain; the demo shows the two cooks **side-by-side** (toy = chain
stand-in, real = the content-addressed stage).

---

## Cross-track map

| Stage | Track | Reused piece (not rebuilt) |
|---|---|---|
| Submit through freeze broker → policy gate | **Track 1 — Perforce** | broker freeze policy `:1667`, `change-commit` trigger |
| Auto-fire chain on submit | **Track 2 — CI** | TeamCity VCS trigger, `Compile → SmokeTest‖CookData → Package` |
| CL version-stamp → provenance | **Track 2 — CI** | Package `version stamp` step → `build-info.json` |
| Real content-addressed cook | **Track 5 — Pipeline** | `Cook Assets` config, `pipeline/cook.py` CAS |
| Dashboard reflects the run | **Observability** | `collect-metrics.ps1` + `build-dashboard.ps1` |
| *(referenced as depth)* "same graph under TeamCity + Horde" | **Track 4 — Unreal** | Lyra BuildGraph orchestrator-parity panel |

The build acceleration levers (Track 3 — `/MP`, unity, PCH, FASTBuild, bgfx) show on the dashboard's
Accel panel but aren't on the demo's critical path; the hoops spine is the fast, deterministic,
fully-scriptable demo path on purpose.

---

## What a green run looks like

Abbreviated illustration (the script prints Cyan step headers, two preflight OKs, and full paths):

```
[1/6] Preflight ...        OK: p4d + broker up;  OK: TeamCity <ver> up; N agent(s) connected
[2/6] Track 1 ...          OK: submitted CL N through the freeze broker (allowlisted build-svc)
[3/6] Track 2 ...          OK: chain green: Package #N at CL N
[4/6] Provenance ...       { p4_changelist, teamcity_build_number, ... };  OK: provenance: CL N -> build #N -> hoops-brawl-clN.tar.gz
[5/6] Track 5 ...          OK: Cook Assets #N SUCCESS - WARM cache hit: cached 8   (first run on a fresh stack: "cold cook" + a cold-cache WARN)
[6/6] Observability ...    OK: dashboard regenerated: <path>\dashboard.html

================ CAPSTONE DEMO: GREEN ================
```

`build-info.json` (inside the tarball) is the provenance object:

```json
{
  "project": "hoops-brawl",
  "p4_changelist": "54",
  "teamcity_build_number": "13",
  "teamcity_build_id": "804",
  "built_at_utc": "...",
  "chain": "Compile -> SmokeTest||CookData -> Package"
}
```

---

## Prerequisites

The stack the demo drives (the demo's preflight starts p4d + broker if they're down; it does **not**
start Docker):

- **p4d** `:1666` + **p4broker** `:1667` — `perforce/scripts/start-p4d.ps1`, `perforce/broker/start-broker.ps1`
- **TeamCity** `:8111` + ≥1 connected, authorized **Linux compose agent** (name `agent-linux-*`,
  from `ci/docker-compose.yml`; preflight requires this specifically) — `docker compose -f ci/docker-compose.yml up -d`
- The `AAASandbox` project bootstrapped (the `Compile/SmokeTest/CookData/Package` chain + `Cook Assets`).

The TeamCity token resolves automatically (scraped from the server log) — or pass `-Token` /
set `$env:TEAMCITY_TOKEN`.

Flags: `-SkipDashboard` (skip the regenerate step), `-ChainTimeoutSec` (wait for the chain to *fire*)
/ `-FinishTimeoutSec` (wait for the Package build to *finish*) / `-CookTimeoutSec` (a cold first build
after a restart is slower — bump these), plus `-BaseUrl`, `-Stream`, etc.

---

## Honest scoping

- **Two cooks on purpose.** The hoops-chain `Cook Data` is a toy stand-in; the real content-addressed
  cook is the additive `Cook Assets` stage. They are shown side-by-side, never merged.
- **First run cooks cold.** Warm-cache hits need a prior `Cook Assets` build to restore the CAS from.
  On a freshly-bootstrapped/reset stack the first run is legitimately green-but-cold (the script prints
  a cold-cache WARN and qualifies the summary); a second run demonstrates the warm cache hits.
- **Cook → dashboard wiring.** `collect-metrics.ps1` pulls the **CI feed live from TeamCity** but reads
  the **cook feed from local `pipeline/.metrics/`**. `demo-capstone.ps1` bridges that itself — it
  downloads the latest `Cook Assets` `cook-stats` artifact into `pipeline/.metrics/` before
  regenerating the dashboard. (A general fix — teaching `collect-metrics` to pull the cook feed live
  too — was considered and deliberately deferred; the demo path doesn't need it.)
- The canonical **policy-gating proof** (allowlisted submit fires *and* frozen-out submit is rejected)
  is `ci/scripts/demo-vcs-trigger.ps1`. This runbook drives only the happy path end-to-end.

---

## Roadmap (post-Slice-1)

- **Slice 2 — disposable CI agent (stretch).** A scripted fresh agent container per demo build,
  auto-authorized via a captured `AGENT_TOKEN`, disposed with `--rm`. TeamCity 2026.1 has no bundled
  Docker-cloud profile for a local host, so this is a host-script wrapper, not a cloud profile.
- **Slice 3 — Zen/DDC + production-ephemeral writeup.** Frames the `.toc` CAS as a hand-rolled
  mini-DDC, and scopes the Kubernetes cloud-profile path as the production disposable-agent answer
  (deliberately written up, not stood up locally).

Full design: `docs/superpowers/specs/2026-06-24-capstone-design.md`.
