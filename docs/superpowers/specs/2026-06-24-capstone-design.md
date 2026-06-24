# Capstone — Phase 2 Step 4 — Design Scope (MVP)

- **Date:** 2026-06-24 (revised same day after a sanity/scope check + a TeamCity-2026.1
  ephemeral-agent feasibility audit — see Slice 2).
- **Track:** Phase 2 Step 4 — the cap. Stitches Tracks 1–5 into one repo-as-demo.
- **Status:** Scoped (pre-implementation). This is the MVP scope the next session executes.
- **Operating principle (lab):** the demoable artifact is the **whole repo exercised on disposable
  infra**, with provenance + observability — not a new component.

## 1. Win-condition / demoable artifact

The "repo-as-demo" is **two coherent halves of one repo** (honest about which cook is real):

**(A) Pipeline mechanics** — a change submitted to `//game/main` **through the policy broker** →
TeamCity auto-fires the hoops chain on a **freshly-spun disposable agent** → Compile →
(Smoke Test ‖ Cook Data) → Package → **CL-version-stamped artifact** → the **dashboard** shows the
run → the agent is **disposed**.

**(B) The real cook** — the standalone **`Cook Assets`** stage runs the **content-addressed cooker**
(warm-cache hit/miss) and the dashboard **"Cook (Track 5)"** panel reflects it. This is the DDC/CAS
story; the toy `Cook Data` in (A) is only a stand-in so Package has content to bundle.

Point at four things: **provenance** (CL → artifact), **observability** (dashboard), **ephemeral CI**
(agent created-for / destroyed-after the build), and **content-addressed cook** (real cooker,
warm-cache semantics). Value proposition: *"I built an AAA-shaped pipeline — real VCS + policy,
CI on submit, a content-addressed cook, version-stamped packages, observable, on disposable agents —
and here's the demo."*

### Done-criterion (explicit)

**MVP-complete** (the bar that declares the Capstone done):
1. `demo-capstone.ps1` runs green end-to-end: P4 submit → hoops chain → CL-stamped artifact, with
   provenance printed; **and** triggers the `Cook Assets` real cook.
2. The **dashboard reflects both** — the chain run + the "Cook (Track 5)" panel.
3. The **Zen/DDC writeup exists** (incl. the K8s "production ephemeral" scoping, Slice 3).

**Headline stretch** (NOT required for MVP-complete — decoupled so the riskier piece can't gate
"done"): the demo build runs on a **scripted-disposable agent** (fresh container, auto-authorized,
disposed). Now low-risk post-audit (Slice 2), but kept as a stretch line so a hiccup doesn't block
declaring the Capstone complete.

## 2. Current state — what exists vs what the Capstone adds

**Exists (verified; reused as-is):**
- **P4 submit → policy-gated → auto-build:** broker freeze policy on `:1667`, p4d `change-commit`
  trigger, TeamCity VCS trigger; `demo-vcs-trigger.ps1` already proves allowlisted-fires /
  frozen-doesn't.
- **CI chain:** Compile → SmokeTest‖CookData → Package; CL-version-stamp; build-failure notifier.
  **The chain's cook is the toy `hoops_cooker`** (concatenates `Data/*.txt`).
- **Real cook:** the content-addressed cooker is in CI as the **standalone `Cook Assets`** config
  (warm-cache, **live-verified 2026-06-24**) — *not* in the hoops chain (additive by design).
- **Observability:** dashboard aggregates ci / accel / perforce / unreal / pipeline feeds.

**The Capstone adds:** (1) the **two-part stitched demo + runbook**; (2) a **disposable agent**;
(3) a **Zen/DDC + production-ephemeral writeup**.

## 3. Slices (ordered, each runnable)

**Slice 1 — Two-part demo runbook (`demo-capstone.ps1` + `capstone/README.md`). ~1 session.**
One scripted run + a **cross-track narrative** runbook (Track 1 policy → Track 2 CI → version-stamp
provenance → Track 5 real cook → dashboard; Track 4 Horde-parity referenced). The script: ensure
stack up → trivial tracked change → submit to `//game/main` via `:1667` → wait for the chain →
fetch + print the CL-stamped `build-info.json` → trigger `Cook Assets` + point at its panel → point
at the dashboard. Reuses `demo-vcs-trigger.ps1`'s submit + Package's artifact + this session's
`Cook Assets`.
- **First action next session:** bring the stack up (Docker + p4d + broker) and run **one**
  submit→chain→stamped-artifact cycle to confirm the baseline still works **after this session's
  changes** (the `//tools` stream import + the `Cook Assets` config) — then write `demo-capstone.ps1`.
  *(Static audit 2026-06-24: the hoops root `CMakeLists.txt` uses explicit `add_subdirectory`, no
  globbing, so the imported `pipeline/` dir can't pollute the C++ build — baseline risk is low.)*

**Slice 2 — Disposable CI agent (scripted). ~1 session, LOW-RISK (de-risked by the 2026-06-24 audit).**
- **Audit finding:** TeamCity 2026.1 has **NO bundled Docker cloud profile** for a local Docker host
  (bundled cloud types = EC2 / vSphere / Kubernetes; the old third-party Docker-cloud plugins are
  dead — 2017/2020-era). The "configure a Docker cloud profile" idea is invalid; **do not chase it.**
- **Build:** a wrapper (`compose run` service or script) that launches a **fresh agent container per
  demo build** and disposes it: `docker compose run --rm` the existing
  `aaa-build-engineering/teamcity-agent` image with `SERVER_URL=http://teamcity-server:8111` +
  `AGENT_TOKEN=<one-time-captured token>` **on the compose network** (+ `host.docker.internal` for the
  broker). `AGENT_TOKEN` makes the agent **auto-register and auto-authorize** (skips the manual
  Unauthorized-Agents approval); `--rm` disposes it on exit.
- **No Docker socket into the server** (a host script launches the agent, not the server) and **no
  docker-in-docker** (the hoops/cooker builds don't build images) — so the socket-mount the compose
  lacks is a non-issue for this path.
- **Setup:** (1) start an agent once, authorize, capture its agent token → `AGENT_TOKEN`; (2) the
  disposable runner; (3) **demo proof:** the Agents list + `docker ps` before / during / after a build.
- **Scope, don't build:** the **Kubernetes cloud profile** (Docker Desktop's built-in K8s) is the
  *bundled* production-scale path — true min/max + `terminateIdleMinutes` disposal + auto-auth, but a
  multi-session fight (K8s enable, API URL/CA/token, RBAC, pod template, networking). **Write it up
  (Slice 3) as the production version I scoped but deliberately didn't stand up locally** — judgment
  signal, not a build.

**Slice 3 — Zen/DDC + production-ephemeral writeup. ~½ session.**
Frame the `.toc` CAS as a hand-rolled mini-DDC (cook-key vs output-hash, content-addressed dedupe,
incremental cook / UE 5.7, Zen Server as the default UE DDC since 5.4, the **cross-machine** shared-DDC
story from lessons #5/#6). **Plus** the **K8s-cloud-profile** scoping from Slice 2 (the production
disposable-agent answer + why it wasn't stood up). Pure writing; leverages existing lessons-learned.

## 4. Scope / non-goals

**In scope:** the two-part demo (hoops spine for mechanics + `Cook Assets` for the real cook); the
**scripted-disposable** agent; the Zen/DDC + K8s-scoping writeup; the **hoops C++ chain as the demo
spine** (fast, deterministic, fully scriptable).

**Non-goals:**
- NOT rebuilding any existing piece.
- NOT merging the real cooker into the hoops chain — `Cook Assets` stays **additive**; the demo shows
  the two cooks **side-by-side** (toy = chain stand-in, real = the DDC/CAS stage), not merged.
- NOT standing up **Zen Server** (separate seed; literacy/writeup only).
- NOT standing up **Kubernetes** (scoped in the writeup only).
- NOT a remote cloud provider (local Docker only).
- NOT the Lyra/Horde heavy path as the scripted spine — the writeup **references** the "same graph
  under TeamCity + Horde" parity as depth; the demo runs the fast hoops spine.

## 5. Effort + sequencing

**~3 sessions, tighter upper bound** now that Slice 2's multi-session risk is removed (the K8s fight
is demoted to a writeup paragraph):
- **Slice 1** ~1 (low risk) → **Slice 2** ~1 (scripted-disposable, low-risk post-audit) →
  **Slice 3** ~½, + ~½ integration/polish.
- **MVP-complete = Slice 1 + Slice 3** (two-part demo + writeup). The disposable agent (Slice 2) is the
  **headline stretch** — low-risk, but decoupled so a hiccup can't gate "done." Fallback within Slice 2
  is already the primary (scripted), so there's no further downside to bound.

## 6. First action (next session)
Bring the stack up; run one submit→chain→stamped-artifact cycle to confirm the post-this-session
baseline; then Slice 1 (`demo-capstone.ps1` + the two-part cross-track runbook).
