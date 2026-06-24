# Capstone — Phase 2 Step 4 — Design Scope (MVP)

- **Date:** 2026-06-24
- **Track:** Phase 2 Step 4 — the cap. Stitches Tracks 1–5 into one end-to-end demo.
- **Status:** Scoped (pre-implementation). This is the MVP scope the next session executes.
- **Operating principle (lab):** the demoable artifact is the **whole repo exercised as one flow on
  disposable infra**, with provenance + observability — not a new component.

## 1. Win-condition / demoable artifact

A single scripted run that demonstrates the full pipeline end-to-end on ephemeral infra:

> A change is submitted to `//game/main` **through the policy broker** → TeamCity auto-fires the
> chain on a **freshly-spun, disposable agent** → Compile → (Smoke Test ‖ Cook) → Package → a
> **CL-version-stamped release artifact** → the **dashboard** shows the run → the agent is **disposed**.

Point at three things in an interview:
1. **Provenance** — `build-info.json` + `hoops-brawl-cl<N>.tar.gz` trace back to the exact P4 changelist.
2. **Observability** — the build appears on the dashboard (status / duration / CL).
3. **Ephemeral CI** — the agent was created *for* and destroyed *after* the build (the Docker signal
   Rockstar names).

Value proposition: *"I built an AAA-shaped pipeline — real VCS + policy, CI on submit,
content-addressed cook, version-stamped package, observable, on disposable agents — and here's the
one-command demo."*

## 2. Current state — what exists vs what the Capstone adds

**Exists (verified; reused as-is):**
- **P4 submit → policy-gated → auto-build:** broker freeze policy on `:1667`, p4d `change-commit`
  trigger, TeamCity VCS trigger. `demo-vcs-trigger.ps1` already proves allowlisted-submit-fires /
  frozen-submit-doesn't.
- **CI chain:** Compile → SmokeTest‖CookData → Package; CL-version-stamp (`build-info.json` +
  `hoops-brawl-cl<N>.tar.gz`); build-failure notifier.
- **Cook:** the real content-addressed cooker is in CI (`Cook Assets`, warm-cache, **live-verified
  2026-06-24**). The hoops chain's toy `Cook Data` stays as-is (additive).
- **Observability:** the dashboard aggregates ci / accel / perforce / unreal / pipeline feeds.

**The Capstone adds:**
1. The end-to-end **stitch + demo runbook** — one scripted run exercising the whole flow (today the
   pieces are proven individually, not as one coherent narrative).
2. **Ephemeral / disposable agents** — fresh-per-build agents instead of the persistent ones (opp #4).
3. **Zen/DDC writeup** — frame the cooker as a mini-DDC; Zen / UE-DDC / incremental-cook literacy (opp #3).

## 3. Slices (ordered, each runnable)

**Slice 1 — End-to-end demo runbook (`demo-capstone.ps1` + a `capstone/README.md`). ~1 session.**
Orchestrate the existing flow into one demonstrable run: ensure stack up → make a trivial tracked
change → submit to `//game/main` through the broker `:1667` → wait for the chain → fetch + show the
CL-stamped artifact's `build-info.json` → point at the dashboard run. Reuses `demo-vcs-trigger.ps1`'s
submit + Package's artifact. Deliverable: `demo-capstone.ps1` exits 0 and prints the artifact
provenance; a `capstone/README.md` runbook narrating the flow.
- **First action next session:** bring the stack up (Docker + p4d + broker) and run **one**
  submit→chain→stamped-artifact cycle to confirm the baseline still works **after this session's
  changes** (the `//tools` stream import + the new `Cook Assets` config), *then* write
  `demo-capstone.ps1` around the verified flow.

**Slice 2 — Ephemeral / disposable CI agent. ~1 session (the main risk).**
Configure a TeamCity **Docker cloud profile** so builds run on fresh-per-build agents that
**auto-authorize** (cloud agents are trusted) and are **disposed** when idle. Approach: cloud profile
→ local Docker host, the existing `aaa-build-engineering/teamcity-agent` image, min-instances 0 (spun
on demand, torn down idle).
- **Unknowns / risks:** cloud-profile REST/UI shape; Docker-socket access from the server container;
  cloud-agent auto-auth behavior; image self-registration.
- **Fallback** if the cloud profile is too fiddly: a scripted "disposable agent" — `compose run` a
  fresh agent container per demo build, remove it after (same narrative, less elegant).
- **Decision to make at impl:** keep one persistent agent for dashboard/bench history + ephemeral for
  the demo, or go fully ephemeral.
- Deliverable: a build runs on an agent that didn't exist before it and is gone after; documented +
  a `ci/lessons-learned.md` entry for whatever bites.

**Slice 3 — Zen/DDC writeup. ~½ session.**
A doc (new `docs/` page or extend `pipeline/README.md`) framing the `.toc` CAS as a hand-rolled
mini-DDC: cook-key vs output-hash, content-addressed dedupe, incremental cook (UE 5.7 beta), Zen
Server as the modern UE DDC paradigm (content-addressed by hash, default since 5.4), and the
**cross-machine** shared-DDC story (this session's lessons #5/#6 — shared DDC is a cross-machine win,
not a one-box one). Pure writing; leverages existing lessons-learned.

## 4. Scope / non-goals

**In scope:** stitch + demo runbook; ephemeral agents (local Docker); Zen/DDC writeup; the **hoops C++
chain as the demo spine** (fast, deterministic, fully scriptable).

**Non-goals:**
- NOT rebuilding any existing piece.
- NOT replacing the toy `Cook Data` with the real cooker (`Cook Assets` stays additive — per the
  2026-06-22 cook-wiring spec).
- NOT standing up Zen Server itself (separate seed; here Zen is literacy/writeup, not infra).
- NOT a cloud provider (local Docker cloud only).
- NOT the Lyra/Horde heavy path as the scripted spine (manual/heavy) — the **writeup references** the
  Lyra "same graph under TeamCity + Horde" parity as depth, but the demo runs the fast hoops spine.

## 5. Effort + sequencing

~2–3 sessions: **Slice 1 (~1) → Slice 2 (~1, the risk) → Slice 3 (~½).** Slice 1 first because it
verifies the spine still works and yields the demonstrable end-to-end; Slice 2 layers the
differentiator onto a working demo; Slice 3 is packaging.

## 6. First action (next session)
Bring the stack up; run one submit→chain→stamped-artifact cycle to confirm the post-this-session
baseline; then start `demo-capstone.ps1` (Slice 1).
