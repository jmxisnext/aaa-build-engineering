# aaa-build-engineering

Skill ladder for AAA build / databuild engineering roles. Operating principle (from README): **build real artifacts over reading.** Each track ends with one demoable thing you can point at in an interview.

> **Working with other agents (Copilot / Codex / Gemini / multiple Claude sessions)?** The cross-agent rules — track isolation, branch/PR conventions, review & merge, safety — live in [`AGENTS.md`](./AGENTS.md) (model-neutral, canonical) with the step-by-step in [`CONTRIBUTING.md`](./CONTRIBUTING.md). This file is Claude-specific and defers to `AGENTS.md` for anything in its scope.

## Scope contract

- Every track's success criterion is a **demoable artifact** ("I built this, here's why"). Define that artifact before starting the track; loop until it runs / demos.
- Bias to building. If you catch yourself producing notes or research instead of a runnable artifact, stop and build the smallest version that runs.
- Keep tracks isolated in their subdir (`perforce/`, `ci/`, `accel/`, `unreal/`, `pipeline/`; `pipeline/` is Track 5 — slice 1 (content cooker) + CI wiring (additive `Cook Assets` stage + dashboard panel; live-validated 2026-06-24, cold→warm) landed; C# WPF tool still to come). Don't let one track's work bleed into another's.
