# perforce/ — Track 1 sandbox

Goal of this track: be fluent enough with Perforce that an interviewer asking *"how would you administer P4 for a 300-engineer studio?"* gets a real answer, not a bluff.

## What's installed (on this machine)

| Component | Location | Source |
|---|---|---|
| p4 CLI | `C:\Program Files\Perforce\p4.exe` | `winget install Perforce.P4V` (bundle includes p4, P4V, P4Admin, P4Merge) |
| P4V (visual client) | `C:\Program Files\Perforce\P4V.exe` | same bundle |
| p4d (server) | `C:\PerforceSandbox\bin\p4d.exe` | direct download from `https://filehost.perforce.com/perforce/r25.2/bin.ntx64/p4d.exe` |
| p4broker | `C:\PerforceSandbox\bin\p4broker.exe` | same filehost (`.../p4broker.exe`) |
| p4p (proxy) | `C:\PerforceSandbox\bin\p4p.exe` | same filehost (`.../p4p.exe`) — installed, `P4P/2025.2` |
| Depot data | `C:\PerforceSandbox\depot\` | created by p4d on first activity |

Server-side binaries (`p4d`, `p4broker`, `p4p`) live **outside the git repo** on purpose — they're multi-MB binaries and the depot will grow. The git repo holds only scripts, configs, docs. Note these three are **separate filehost downloads**, *not* part of the `winget` P4V bundle (which is p4/P4V/P4Admin/P4Merge only) — see `lessons-learned.md` #13.

## Persisted P4 env (via `p4 set`)

```
P4PORT   = localhost:1666
P4USER   = james
P4CLIENT = james-WS01-game-main      # the active stream workspace
```

`P4CLIENT` selects which workspace (and therefore which stream / view) `p4`
operates on; the name follows the `username-machine-stream` convention from
`depot-layout.md` → *Workspace conventions*. Switch streams by switching client:
`-c james-WS01-game-dev` per command, or `$env:P4CLIENT = "..."` per shell.

These are stored in the Windows registry under `HKCU\Software\Perforce\Environment`. Override per shell with `$env:P4PORT = "..."` etc. To target a *different layer*, override the port: `-p localhost:1667` (broker) or `-p localhost:1668` (proxy) instead of the server on `:1666`.

## Start / stop the server

```powershell
# Start (foreground; close the window to stop):
& "C:\PerforceSandbox\bin\p4d.exe" -r C:\PerforceSandbox\depot -p 1666 -L C:\PerforceSandbox\depot\p4d.log

# Or use the helper:
.\scripts\start-p4d.ps1
.\scripts\stop-p4d.ps1

# Verify:
p4 info
```

When running, you should see something like:

```
Server version: P4D/NTX64/2025.2/2907753 (2026/03/09)
Server root: C:\PerforceSandbox\depot
Server license: none      # 5-user / 20-workspace free tier
```

## What lives in this directory

| Path | Purpose |
|---|---|
| `scripts/` | PowerShell helpers — start/stop p4d, set up a fresh sandbox depot |
| `triggers/` | Server-side trigger scripts (Python / PowerShell) hooked via `p4 triggers` |
| `broker/` | P4 Broker (`:1667`) — command-level policy layer (block obliterate, code-freeze allowlist) |
| `proxy/` | P4 Proxy (`:1668`) — file-content cache for remote offices + cache-hit demo |
| `tools/` | Client-side automation (P4Python utilities, dashboards, janitors) |
| `depot-layout.md` | The design doc for the hypothetical-game depot structure (see Track 1 step 3) |

## Track 1 progress checklist

- [x] 1. Install P4D, P4V, P4 CLI
- [x] 2. Configure env vars (P4PORT, P4USER, P4CLIENT) via `p4 set`
- [x] 3. Design + create a depot layout for a hypothetical small game (`depot-layout.md`); depots `//engine/`, `//game/`, `//tools/`, `//thirdparty/`, `//build/` created
- [x] 4a. Set up a stream depot with mainline / development / release streams — `//game/main`, `//game/dev`, `//game/release-1-0` exist; workspace `james-WS01-game-main` synced; first file submitted as change 4
- [x] 4b. **Promote a change up the stream graph** — created `//game/feature-shotmeter` (parent dev); submitted Shotmeter.cpp + README on it; copy-up feature → dev → main (changes 8-12); then created a deliberate conflict (edited same line on main and feature in parallel — main 110.0f, feature 75.0f), ran merge-down main→dev (auto-resolved, change 15) and dev→feature (`p4 resolve -am` correctly skipped — 1 conflicting chunk detected), hand-resolved with `-ay`, copied back up (changes 16-18). Final state: all streams at 75.0f. Lessons banked in `lessons-learned.md`.
- [x] 5. Wrote `require-engine-tag.py` as a `change-submit` trigger. Registered via `p4 triggers`. Three test cases proved: (TEST 1) `//engine/` submit without tag → rejected with custom message; (TEST 2) same submit with `[engine]` in description → accepted as change 19; (TEST 3) `//game/` submit without tag → accepted (exempt). Triggers' README documents the workflow + hardening notes for production.
- [x] 6. `tools/stale_cl_janitor.py` — P4Python (3.13 wheel from r25.2/bin.ntx64) janitor with `--days`, `--user-filter`, `--verbose`, `--apply`. Safe by default; mutating mode shelves work then reverts files. Demoed end-to-end against CLs 21 and 22 — both shelved + reverted; `p4 unshelve -s 21` would recover the work. Venv at `tools/.venv/`; wrapper `tools/janitor.ps1`. Full design notes in `tools/README.md`.
- [x] 7. **P4 Broker** stood up on `:1667` forwarding to `:1666`. Config in `broker/p4broker.conf` encodes two real-world policies: block `obliterate` (destructive op, common AAA broker rule) and block `submit` (code-freeze maintenance window). Four end-to-end demos passed: through-broker `p4 info` displays both broker + server addresses; `obliterate` rejected via broker with custom message; `submit` rejected with code-freeze message; same submit succeeded when bypassing broker (direct to `:1666`, change 23). `broker.log` confirms every command is recorded with `[PASS]` or `[REJECT]`. `broker/README.md` includes the proxy-vs-broker-vs-replica-vs-edge vocabulary cheat sheet.
- [x] 8. **Submit-validation trigger** — `triggers/validate-submit.py` (a **`change-content`** trigger on `//...`) enforces depot hygiene: rejects compiled build output (`.obj/.pdb/.lib/.exe/.dll/...`, **exempting `//thirdparty/`** where prebuilt vendor SDKs are legitimate) and oversized files (>50 MB) lacking a `[large-ok]` override. `triggers/demo-validate-submit.ps1` proves all 5 cases end-to-end (build-artifact reject · clean accept · oversized reject *via `@=change`* · `[large-ok]` override accept · `//thirdparty/` exemption accept) and self-cleans. Closes roadmap **opp #5**; see `lessons-learned.md` #12 (change-submit vs change-content).
- [x] 9. **Perforce Proxy (p4p)** — caching proxy **live** on `:1668` → `:1666` (`proxy/`). `demo-proxy.ps1 -SeedMB 50` verified end-to-end: empty cache → client A fills it to **50 MB** from upstream (0.9 s) → client B syncs the same revisions with **0 cache growth** (all hits, 0.2 s, zero upstream fetches). `-SeedMB` is the Track-1 workload-tier knob. Closes the roadmap's literal "proxy" gap; see `lessons-learned.md` #13.
