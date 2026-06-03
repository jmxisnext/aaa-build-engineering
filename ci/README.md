# ci/ — Track 2 sandbox (TeamCity + P4 broker)

Goal of this track: stand up a real CI server, wire it to the Track 1 Perforce
depot **through the broker**, and build a non-trivial chained pipeline against
a sample C++ project.

The broker layer is the deliberate choice — running CI through `:1667` instead
of `:1666` means every command the build agent issues is recorded in
`C:\PerforceSandbox\broker\broker.log` and is subject to broker policy.
That's how studios actually wire CI: through the policy layer, not around it.

## What's in here

| Path | Purpose |
|---|---|
| `docker-compose.yml` | TeamCity Server + **two** Linux Build Agents, networked together |
| `.env` | `TEAMCITY_VERSION` pin (default `latest` until a known-good is identified) |
| `data/` | Server DB, agent conf, logs — all gitignored, all regenerable |
| `scripts/bootstrap-builds.ps1` | Idempotent REST bootstrap of the 4-config build chain |
| `scripts/bench-agents.ps1` | Measure chain wall-clock with 1 vs 2 agents (parallelism demo) |
| `lessons-learned.md` | Track 2 incident log (same pattern as `perforce/lessons-learned.md`) |

## Bring up / tear down

```powershell
# From J:\jammers-lab\aaa-build-engineering\ci
docker compose up -d
docker compose ps              # both services should be Up; server health: starting -> healthy in ~90s
docker compose logs -f teamcity-server   # watch first-run init

# Stop, keep data:
docker compose stop

# Stop, wipe DB + agent identity (full reset):
docker compose down -v
Remove-Item -Recurse -Force .\data
```

## First-run wizard

After `docker compose up -d`, open `http://localhost:8111/` and walk:

1. Accept the data directory (`/data/teamcity_server/datadir`).
2. Pick **Internal (HSQLDB)** for the DB. (See lessons-learned #1 — HSQLDB is the
   right call for a sandbox; first thing to switch out in production.)
3. Accept the EULA.
4. Create an admin user. Use anything — this is local-only.
5. After login, go to **Agents** → **Unauthorized**. The Linux agent
   `agent-linux-01` should be sitting there. Authorize it.

## Wiring to Track 1 Perforce

From inside the containers, the Windows host's P4 broker is reachable at
`host.docker.internal:1667`. The compose file declares `extra_hosts` so this
resolves on Linux hosts too (Docker Desktop on Windows resolves it
automatically, but explicit is portable).

The VCS root in TeamCity should be configured as:

| Field | Value |
|---|---|
| Type | Perforce Helix Core |
| Port | `host.docker.internal:1667` |
| User | `james` |
| Client mapping | `//game/main/... //%P4CLIENT%/...` |
| Use ticket-based auth | (no auth required in this sandbox) |

Verify the connection from the TeamCity UI; broker.log on the host will show
the command if it really came through the broker.

## Operational notes

- **Server is memory-hungry.** Defaults ~1 GB heap. Increase via the
  `TEAMCITY_SERVER_MEM_OPTS` env var if the container OOMs during indexing.
- **Agent identity persists across restarts** because `conf/` is volume-mounted.
  If you ever see two "agent-linux-01"s appear in TeamCity's Agents page, one
  is stale — delete the unauthorized one.
- **Server takes ~60–90s to be healthy on first boot.** The healthcheck reflects
  that; the agent waits on `service_healthy` before starting.
- **Don't commit `data/`.** Already gitignored.

## Agent pool — parallelism benchmark

The build chain fans out at Compile into `Smoke Test ‖ Cook Data` (both
depend only on Compile, both feed Package). With one agent those two
leaves serialize; with two they run concurrently. `scripts/bench-agents.ps1`
measures the difference directly — it runs the chain with agent-02 disabled,
then enabled, forcing `rebuildAllDependencies` both times:

```powershell
# stack must be up; run a warmup chain first so caches are warm
pwsh -File .\scripts\bench-agents.ps1
```

Measured result — **median of 5 A/B trials** (2026-06-03, `latest` =
TeamCity 2026.1):

| Config | Leaf phase (Smoke‖Cook) | Overlap? | Whole chain |
|---|---|---|---|
| 1 agent  | 22s (min 22, max 23) | no  | 45s |
| 2 agents | 11s (min 11, max 11) | yes | **34s** |

**2× on the leaf phase** (two equal ~11s leaves overlapping), ~24% off the
whole chain — and the pattern held in **all 5 trials**: 1-agent never
overlapped, 2-agent always did, and the 2-agent leaf span was a dead-flat
11s every trial (zero variance — it's one overhead-bound build either way,
just parallelized). That flatness also rules out CPU contention between the
two same-host agent containers; if they were fighting over cores the
2-agent leaf would have crept up under load. Two caveats that make this
honest rather than a vanity number:
the ~11s/build is fixed overhead (p4 sync through the broker + artifact
download + agent handshake), not the toy project's sub-second compute — but
that overhead is *exactly* what a second agent overlaps, and it only grows
on a real depot. And a *third* agent would buy nothing here: the DAG is only
2-wide at its widest stage. See `lessons-learned.md` §5.

## What this stack does not do yet

- No external DB (HSQLDB only — sandbox-tier).
- Two Linux agents, no native Windows agent yet. C++ MSBuild work on Windows
  will need a separate native Windows agent registered against the same
  server (deferred — the current chain builds the C++ seed with gcc/CMake on
  Linux).
- Builds are manual / dependency-triggered only — no VCS-change trigger wired
  yet, so a P4 submit through the broker does not auto-fire the chain.
- No HTTPS / reverse proxy. Production would front this with nginx + a real
  cert.
