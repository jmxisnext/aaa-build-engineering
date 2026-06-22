# Heavy-Run Prep Campaign — Design Spec (Phase 2)

- **Date:** 2026-06-21
- **Scope:** Full Phase 2 — all remaining resource-heavy runs (finish-Horde, shared DDC, CI cook wiring, pre-flight/gated builds, Capstone).
- **Status:** Design approved (scope + sequencing), pending spec review → implementation plan.
- **Sequencing:** Approach A — cross-cutting + turnkey first, then per-run offline pieces.
- **Operating principle:** Front-load every offline-authorable item so each expensive run reduces to *"just the run"* — the same de-risk pattern already proven on Session 4 (commit `c0688df`).

## 1. Goal / win-condition

When the next heavy session opens, **every offline prerequisite is already built, committed, and verified**, so the only things left are the genuinely-gated ⛔ items: the actual cooks/runs that need UE + Horde + the service stack live. "Fully prepped and optimized" decomposed into three concrete properties per heavy run:

- **Turnkey** — bring-up is one command, not a manual checklist.
- **Optimized** — the run is as fast/cheap as it can be made offline (chiefly: warm shared DDC).
- **De-risked** — no latent failure (stale config, CSRF bug, missing toolchain) blows up an expensive run mid-flight.

**Demoable artifact (of the prep itself):** the committed offline artifacts below + a one-page heavy-session runbook; each heavy run has a green "preflight" path that exits 0 before any expensive work starts.

## 2. Background / current state (per heavy run)

- **Horde (Step 2)** — graph is **complete**: `lyra-pipeline.xml` has an in-graph `Stamp Lyra` node threading `$(Source)`, `Aggregate Lyra Pipeline` requires it. CL-stamp parity is therefore authored (the `horde/README.md` "⬜ item 4" status is **stale** — predates `c0688df`). Session-start state is an **8-item manual checklist** in `horde/README.md` (junction, sentinel, JobDriver `Executor=Local`, template `-NoP4`, server :13340, agent `online`, p4d up). Only the live run remains.
- **Shared DDC** — last Horde cook was cold, **~24.6 min** (Vulkan SM6 perms uncached). No shared DDC configured; TeamCity and Horde cooks don't share a cache.
- **CI cook wiring** — CI runs a toy `hoops_cooker`; the real `pipeline/cook.py` is not wired. `ci/agent/Dockerfile` has p4 + `build-essential` + `cmake` but **no Python/Pillow**. Cooker emits a `cooked/` CAS dir + `.toc`, but CI Package expects a single `Cooked.pak`.
- **Pre-flight / gated builds** — post-commit VCS trigger exists (`2026-06-03-vcs-trigger-design.md`); pre-flight (shelve trigger + personal builds) was explicitly scoped out (§8 of that spec).
- **Capstone (Step 4)** — nothing built.
- **Cooker internals** — `cook.py` flags are `--src/--out/--force/--stats-json`; **no `--dry-run`**. `manifest.toc.json` serializes per-asset entries but **no character→asset dependency edges**.
- **Latent bug** — `bench-agents.ps1` does write-REST without an `X-TC-CSRF-Token` (same bug already fixed in `bootstrap-builds.ps1` + `setup-vcs-trigger.ps1`); it will fail on the next bench run against a TeamCity 2026.x server.

## 3. The prep ledger

**Tags:** 🟢 turnkey · ⚡ optimize · 🔧 fix-latent-failure · 📋 spec/design · ⛔ gated (needs the heavy run — out of offline scope).

### 3.1 Cross-cutting (do first — cheapest, highest de-risk, serves every run)

| Item | Tag | Done when |
|---|---|---|
| `unreal/scripts/horde-preflight.ps1` — automate the 8-item session-start checklist; optionally start p4d + agent; exit non-zero on any red | 🟢 | Running it on a cold box reports every checklist item PASS/FAIL and (with a `-Start` switch) brings p4d + agent up; exits 0 only when the box is run-ready |
| CSRF fix in `bench-agents.ps1` (+ factor a shared CSRF-aware `Invoke-TC` helper) | 🔧🟢 | Bench script issues all writes with a per-session CSRF token; the helper is the single REST-write path |
| Heavy-session runbook (`docs/HEAVY_SESSION_RUNBOOK.md`) — serialization order (UE+Horde+agent never concurrent with TeamCity/Docker, 31 GB ceiling), drive placement (DDC→D:, installs→G:, source→J:), bring-up/tear-down sequence | ⚡📋 | One page; each heavy run links to it |
| Cooker dep-graph edges in `.toc` + `--dry-run` mode (TDD) | 🟢 | `.toc` carries character→asset edges; `cook.py --dry-run` computes cook-keys, reports would-recook, writes nothing; new unittests RED→GREEN |
| Correct stale `horde/README.md` item-4 status | 🔧 | README reflects in-graph stamp = parity authored |
| Pin `TEAMCITY_VERSION` in `ci/docker-compose.yml` | 🟢 | Explicit build pinned; drift note removed |

### 3.2 Per-run offline pieces

| Heavy run | Item | Tag | Done when |
|---|---|---|---|
| Shared DDC | Configure shared DDC — **default: local `UE-SharedDataCachePath` folder on D:\ scratch** (simplest, fully offline-configurable; Zen Server is the noted alternative if a CAS-backed story is wanted later) so TeamCity + Horde cooks share one cache; document "warm once, reuse" | ⚡📋 | Config committed + both cook paths point at the D:\ shared folder; warm-fill procedure documented |
| CI cook wiring | `RUN pip install pillow` (+ python3) in `ci/agent/Dockerfile` | 🟢 | Image builds; `python3 -c "import PIL"` green at build time |
| CI cook wiring | Cooker "pack `cooked/` + `.toc` → single `.pak`" mode (TDD) | 🟢📋 | `cook.py --pack out.pak` produces a `.pak` matching the CI Package contract; tests green |
| CI cook wiring | Plan `cooked/`+cook-index persistence across CI runs (checkout reuse / artifact cache) | 📋 | Documented; enables a warm-vs-cold CI cook number |
| Pre-flight builds | Write the pre-flight spec (shelve trigger → personal builds → optional Swarm gate) | 📋 | `2026-06-21-*` spec committed |
| Pre-flight builds | Author shelve-trigger script + personal-build config | 🟢 | Scripted offline; ready to validate when stack is up |
| Capstone | Capstone orchestration design + repo-as-demo narrative + Zen/DDC writeup outline | 📋 | Design committed |
| Capstone | Ephemeral/containerized agent Dockerfile (opp #4) | 🟢 | Dockerfile builds an agent image that registers + tears down |

## 4. Sequencing (Approach A)

1. **Cross-cutting (§3.1)** — `horde-preflight.ps1`, CSRF fix + shared helper, heavy-session runbook, cooker dep-edges + `--dry-run`, README status fix, version pin.
2. **Shared DDC config** (§3.2) — the single biggest optimizer; unblocks both finish-Horde and CI-cook warm numbers.
3. **CI cook wiring offline pieces** (Dockerfile, pack-to-`.pak`, persistence plan).
4. **Pre-flight spec + scripts.**
5. **Capstone design + ephemeral-agent Dockerfile.**

Each step is committable independently; the gated ⛔ runs are NOT attempted in this campaign.

## 5. Explicitly gated (out of offline scope)

These wait for a heavy session and are the *only* things that should remain after this campaign: the live Horde run + real-facts `emit-run-metric`; the DDC warm-fill cook; CI-stack validation of the wired cooker; live p4d+TeamCity validation of the shelve trigger; the Capstone end-to-end run.

## 6. Success criterion / non-goals

- **Success:** every 🟢⚡🔧📋 item above is committed and (where runnable offline) verified green; opening a heavy session means running preflight → the gated run, nothing else.
- **Non-goals:** no game/gameplay work; no second-engine (Unity) arm (post-Capstone, per seed 2026-06-17); no Chronicle-kernel work (separate repo); the WPF artist tool GUI build is *not* in scope here (its cooker-side prerequisites — dep-edges, `--dry-run` — are, as cross-cutting items).
