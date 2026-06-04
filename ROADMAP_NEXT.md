# ROADMAP_NEXT — sequencing & 2026 landscape

Companion to `SKILLS_ROADMAP.md` (the original 5-track definition). Captures a completeness
audit of tracks 1–3, a 2026 landscape update for tracks 4–5, the "workload tier" principle,
hardware reality, and the agreed near-term sequence. Planted 2026-06-04.

**Strategy: consolidate-first.** Finish tracks 1–3 + the dashboard, THEN re-sanity the order
for tracks 4–5. Phase 1 below is locked; Phase 2 is deliberately left to be sequenced after
the dashboard ships.

## Track audit — where 1–3 actually stand

- **Track 1 (Perforce) ~95%.** Steps 1–6 are real and demoable (p4d, depot-layout doc,
  stream graph + promote, `require-engine-tag.py` trigger, P4Python `stale_cl_janitor.py`,
  broker). **Only literal gap: no `p4p` proxy** (roadmap says "proxy/broker"; only the broker
  was built). Polish: embed a live `p4 streams` snapshot in `depot-layout.md`; document
  `P4CLIENT`; janitor `--json`. Cosmetic: Track-2 `notify-teamcity.ps1` bleed in
  `perforce/triggers/`; `.venv/` committed.
- **Track 2 (CI) — core done + EXCEEDS the roadmap** (policy-gated VCS trigger, agent-pool
  benchmark, scripted-from-scratch project+root+reset, 9 lessons). **Missing roadmap items:**
  Package **version-stamp** with the P4 changelist # (S); **build-failure notification** (S–M);
  **static REST dashboard** (M). The C++ sample is non-trivial in structure, thin in logic
  (adequate).
- **Track 3 (accel) — mechanics complete, every lever measured** (`/MP` 3.97×, unity, a
  PCH hypothesis tested *and refuted* with `/Bt+`, FASTBuild cache 14.4×, linker
  `/INCREMENTAL` + `/LTCG` 269× + symbol-bloat sweep). **Weakness: synthetic 32-TU fixture**
  → can't say "I cut a real 25-min build." Fix = adopt a real codebase (workload tier).

Net: tracks 1–3 are interview-demoable today; what's left is polish / gap-closing, not deep work.

## 2026 landscape delta (affects tracks 4–5; from web research 2026-06-04)

- **Horde + UBA (Unreal Build Accelerator) went GA in UE 5.5 (late 2024)** — production-relevant
  NOW, not future. UBA is a first-class interview topic ("how do you accelerate compile at
  scale?"); the roadmap, written ~mid-2025, underweights it.
- **BuildGraph (XML) is still the standard authoring format** Epic uses for its own pipelines;
  JetBrains open-sourced a TeamCity BuildGraph runner → it plugs into the CI we already have.
- **Zen Server is the default DDC backend since UE 5.4**; content-addressable-storage by
  content hash is the paradigm. Track 5's `.toc` cooker is a miniature DDC/CAS — frame it that
  way. Incremental cooking (UE 5.7 beta) is a strong "how did you cut cook time" answer.
- **WPF is still valid for Track 5** (Cloud Imperium lists "WPF or Blazor"); Qt/PySide6 dominates
  Maya-adjacent artist tooling — keep WPF, be ready to defend the choice.
- Sources (full set in session record): Epic UE 5.5 / 5.7 release notes; GDC 2025 "Horde on AWS";
  Unreal Fest Orlando 2025 Horde talk; JetBrains TeamCity UE-plugin posts; AAA build-engineer
  job postings (Rockstar, Cloud Imperium, etc.).

## Workload tier — the missing substrate

The portfolio's numbers are toy / overhead-bound until the heavy-lifting tracks run against a
**real, recognizable workload**. The move is to ADOPT one, **not build a game from scratch**
(the target role is build-engineering, not gameplay — a from-scratch game is a scope sink with
little build-eng signal). Two injections:

- **bgfx `examples/common`** (raw C++, ~25 standalone TUs) → **Track 3 finalization (Phase 1)**.
  Cheap (~1 day), recognizable, yields an honest accel before/after. *First appearance of the tier.*
- **Lyra** (Epic sample game) → **Phase 2 (Track 4 onward)** as the UE substrate for compile
  (UBT/UBA) → cook (DDC/Zen) → package (BuildGraph); reused through Track 5 + capstone.
  **CitySample** = heavier stress option (RAM-tight).

The **dashboard consumes this tier**: v1 on existing + bgfx data (Phase 1), enriched with
Lyra/cook metrics in Phase 2.

## Hardware reality

Ryzen 7 7800X3D (8c/16t) · 31 GB RAM · **RTX 3060 12 GB** · F: 2.8 TB free.

- **GPU is NOT a constraint** — the 3060 12 GB runs the UE5 editor + Lyra comfortably,
  interactively. CitySample is reachable but RAM-tight. (An earlier "favor cmdline" note was
  based on a misread integrated GPU and is retracted.)
- **RAM (31 GB) is the binding ceiling** — serialize heavy stacks (don't run UE + Horde +
  TeamCity + Docker all at once); CitySample's editor wants 32 GB+.
- **8 cores caps distribution realism** — Horde/UBA on one box is an honest *mechanics* demo
  (overhead-overlap), not farm-scale numbers. Frame accordingly in interviews.
- **Drive placement (F: is a slow external USB HDD — NOT for builds):** UE5 + Lyra + installs-to-keep → **G: (NVME_DURABLE, NVMe, 365 GB free)**; DDC + build/cook scratch → **D: (NVME_SCRATCH, NVMe, 404 GB free)**; source → **J: (Dev Drive)**. **F: (TRON, USB HDD, 2.8 TB) = archive/backup only** (`F:\Jammers_Archive`; external, not always attached). Keep heavy build I/O off C: (SATA OS drive). See auto-memory `dev-machine-specs`.
- **Implication for the near-term plan:** Phase 1 (finalize 1–3 + dashboard) is
  CPU/infra/disk-bound → **unaffected by the GPU correction**. The hardware fix upgrades
  Phase 2 (Unreal), which is deferred anyway.

## Sequence

### Phase 1 — LOCKED: consolidate (finalize tracks 1–3 + dashboard)

1. **Finalize Track 1** — `p4p` proxy (`:1668`→`:1666`) + cache-hit demo; live `p4 streams`
   snapshot in `depot-layout.md`; change-submit validation trigger (opp #5). [~½–1 session]
   → **2026-06-04: DONE.** ✅ live `p4 streams`/`p4 depots` snapshot embedded in
   `depot-layout.md`. ✅ `validate-submit.py` (`change-content`) depot-hygiene trigger +
   self-cleaning `demo-validate-submit.ps1` (5/5 cases) — **opp #5 closed**. ✅ p4p proxy
   **live** on `:1668`→`:1666` (`perforce/proxy/`); `demo-proxy.ps1 -SeedMB 50` verified
   cache-fill→hit (50 MB cached, client B = 0 upstream fetches). Track 1 now at ~100%;
   next is Phase 1 step 2 (Track 2 version-stamp + build-failure notification).
2. **Finalize Track 2 core** — version-stamp Package with the P4 changelist # (S);
   build-failure notification, file-write or TeamCity rule (S–M). [~½ session]
   → **2026-06-04: DONE.** ✅ version-stamp — Package writes `dist/build-info.json`
   (P4 CL via `%build.vcs.number%` + build#/id/UTC) and names the tarball
   `hoops-brawl-cl<N>.tar.gz`; verified on real builds at CL 29/46. ✅ build-failure
   notifier (`notify-build-failure.ps1`, file-write to `data/notifications/`) — proven by
   a CL-45 `[DEMO-BREAK]` failing test → caught → fix-forward CL 46 → green. Bonus
   hardening: CSRF fix on `bootstrap-builds.ps1` + `setup-vcs-trigger.ps1` (TeamCity 2026.x
   blocks session-authed writes), tarball-staleness fix, instant-CI restored. Lessons #10–12.
3. **Finalize Track 3** — adopt **bgfx `examples/common`** → real before/after numbers;
   `/d2cgsummary` snippet; single-file-edit compile timing. [~1 day] — *workload tier injection #1*
4. **Build the dashboard** — aggregate the three finished tracks: CI builds + version/CL stamps +
   duration/status trends, FASTBuild/bgfx cache-hit & accel numbers; honest about overhead-bound
   parallelism. Closes Track 2's roadmap dashboard **and** is the #1 cross-portfolio differentiator.
   [~2–3 days]
   → **2026-06-04: DONE.** ✅ Two-stage pipeline: `collect-metrics.ps1` gathers three live feeds
   (TeamCity REST · `bench -Json` emits · `p4` streams/depots) → committed `snapshot.json` →
   `build-dashboard.ps1` renders a self-contained `dashboard.html` (inline SVG, **no JS framework/CDN**,
   byte-deterministic). Real captured demo state: **23 CI builds** across all 4 configs (CLs 46–51) with
   **one genuine red** Smoke Test (a `ctest` break injected + fixed), real accel numbers
   (compile/bgfx/link/FASTBuild), live perforce streams/depots. TDD throughout (`dashboard/tests/`);
   the real capture even caught a collector timestamp bug the fixture had masked. **Closes Phase 1.**

### Phase 2 — TBD: re-sanity the order after the dashboard ships

Candidates (sequence to be decided once Phase 1 is done and the dashboard is visible):
- **Track 4 — Unreal**: BuildGraph (compile→cook→package via `RunUAT`) on **Lyra**, wired into
  TeamCity. [~1–2 sessions] — *workload tier injection #2 (Lyra)*
- **Horde-on-one-box + UBA** running that BuildGraph (most differentiating; hardware-bounded;
  time-box it). [opp #2]
- **Track 5 — cook pipeline + WPF tool** (the long pole, ~2–3 weeks): Python cooker (dep graph +
  content-hash incremental + `.toc`) → WPF UI → replaces Track 2's stub Cook Data → feeds the
  dashboard. Frame as a hand-rolled DDC/CAS. [opp #3]
- **Capstone stitch** — end-to-end submit→CI→cook→package→versioned artifact; repo-as-demo;
  containerized/ephemeral agent (opp #4); Zen/DDC writeup.

## High-leverage opportunities (ranked, from the audit + web research)

1. **Observability dashboard** — highest ROI; *is* Phase 1 step 4 (closes Track 2 gap + top differentiator).
2. **Horde + UBA** — most differentiating Unreal skill; fold into Track 4.
3. **Zen / DDC / CAS literacy** — frame Track 5's `.toc` as a mini-DDC; speak to incremental cook.
4. **Containerized / ephemeral CI agents** — ~1 day; Rockstar explicitly requires Docker.
5. **P4 change-submit validation trigger** — ~1 day; folded into Phase 1 step 1.
