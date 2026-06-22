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
| `unreal/scripts/horde-preflight.ps1` — automate the 8-item session-start checklist; **bake the serialization guardrails in as enforced checks** (refuse to run if the TeamCity/Docker stack is up; warn on low free RAM vs the 31 GB ceiling; assert DDC→D:/installs→G:/source→J:); optionally start p4d + agent | 🟢⚡ | On a cold box: reports every checklist item PASS/FAIL, blocks on a guardrail violation, and (with `-Start`) brings p4d + agent up; exits 0 only when run-ready |
| CSRF fix in `bench-agents.ps1` (the necessary fix). Extract a shared `Invoke-TC` helper **only if a clean lift** — do not rewrite the two already-working scripts | 🔧 | `bench-agents.ps1` issues writes with a per-session CSRF token; the next bench run survives a 2026.x server |
| Cooker dep-graph edges in `.toc` + `--dry-run` mode (TDD) | 🟢 | `.toc` carries character→asset edges; `cook.py --dry-run` computes cook-keys, reports would-recook, writes nothing; new unittests RED→GREEN |
| Correct stale `horde/README.md` item-4 status | 🔧 | README reflects in-graph stamp = parity authored |
| Pin `TEAMCITY_VERSION` in `ci/docker-compose.yml` | 🟢 | Explicit build pinned; drift note removed |

> Sanity-pass change: the standalone "heavy-session runbook" doc was dropped — its rules become **enforced guardrails inside `horde-preflight.ps1`** (executable > prose, and avoids duplicating ROADMAP_NEXT "Hardware reality" + the `dev-machine-specs` memory).

### 3.2 Per-run offline pieces — IN this campaign

| Heavy run | Item | Tag | Done when |
|---|---|---|---|
| Shared DDC | **(Batch 1 — pulled forward)** Configure shared DDC — **default: local `UE-SharedDataCachePath` folder on D:\ scratch** (simplest, fully offline; both cooks run on WS01 so a local folder is genuinely shared between them. Zen Server parked as its own demo — seed). Both cook paths point at it; document "warm once, reuse" | ⚡📋 | Config committed + both TeamCity and Horde cook envs point at the D:\ shared folder; warm-fill procedure documented |
| CI cook wiring | `RUN pip install pillow` (+ python3) in `ci/agent/Dockerfile`; `docker build` + `import PIL` smoke (**LIGHT — in-campaign, not gated**) | 🟢 | Image builds; `python3 -c "import PIL"` green at build time |
| CI cook wiring | Cooker pack-to-`.pak` mode — **clustered with the cooker work in §3.1** (dep-edges + `--dry-run` + pack land together) | 🟢 | `cook.py --pack out.pak` matches the CI Package single-`.pak` contract; tests green |
| CI cook wiring | Plan `cooked/`+cook-index persistence across CI runs (checkout reuse / artifact cache) | 📋 | Documented; enables a warm-vs-cold CI cook number |

### 3.3 Deferred to their own brainstorm → spec → plan cycle (NOT executed here)

Pre-flight/gated builds and the Capstone are each **new features**, not prep — each deserves its own design pass, so this campaign writes no thin stubs for them. They re-enter via `brainstorming` when reached:

- **Pre-flight / gated builds** — shelve trigger → personal builds → optional Swarm gate (own spec + script).
- **Capstone stitch** — end-to-end orchestration, repo-as-demo, ephemeral/containerized agent (opp #4), Zen/DDC writeup.

## 4. Sequencing (Approach A, refined by the sanity pass)

**Batch 1 — make the imminent Horde run turnkey AND warm (offline config/scripts):**
`horde-preflight.ps1` (checklist + serialization guardrails) · shared-DDC config · CSRF fix in `bench-agents.ps1` · README item-4 status fix · pin `TEAMCITY_VERSION`.

**Batch 2 — the cooker cluster (Python/TDD; serves CI-cook *and* the future WPF tool):**
dep-graph edges in `.toc` · `--dry-run` · pack-to-`.pak`.

**Batch 3 — CI cook wiring offline pieces:**
`ci/agent/Dockerfile` pillow + image smoke · `cooked/`+index persistence plan.

**Then (own brainstorm cycles, see §3.3):** pre-flight spec, Capstone design.

Each batch is independently committable; the gated ⛔ runs are NOT attempted in this campaign.

## 5. Explicitly gated (out of offline scope)

These wait for a heavy session and are the *only* things that should remain after this campaign: the live Horde run + real-facts `emit-run-metric`; the DDC **warm-fill cook**; the **full TeamCity-DAG cook** validating the wired cooker (the agent-image `docker build` itself is light and done in-campaign); live p4d+TeamCity validation of the shelve trigger; the Capstone end-to-end run.

(`horde-preflight.ps1`'s all-green path self-confirms at the start of the next heavy session — cheap, not a separate gated task.)

## 6. Success criterion / non-goals

- **Success:** every 🟢⚡🔧📋 item above is committed and (where runnable offline) verified green; opening a heavy session means running preflight → the gated run, nothing else.
- **Non-goals:** no game/gameplay work; no second-engine (Unity) arm (post-Capstone, per seed 2026-06-17); no Chronicle-kernel work (separate repo); the WPF artist tool GUI build is *not* in scope here — it is light and independently buildable anytime (not a resource-heavy run), and its cooker-side prerequisites (dep-edges, `--dry-run`) ride along as cross-cutting items.
- **Parked seed (this session):** stand up **Zen Server** as its own CAS-backed-DDC mechanics demo — distinct from the local shared-folder DDC used here for the cook-warm optimization.
