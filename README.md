# aaa-build-engineering

**Launchpad for AAA Build / Databuild Engineer roles.** The skill stack practiced here is the public AAA build-engineering surface — Perforce, CI/CD, build acceleration, Unreal build tooling, and content-cook pipelines — so it generalizes across AAA studios.

This is not a one-off experiment. It's an ongoing skill ladder.

## Layout

- `ROLE_NOTES.md` — what the target role actually is, day-to-day, and what its tech surface looks like.
- `SKILLS_ROADMAP.md` — 5 practice tracks + a capstone. Each track produces one demoable artifact.
- `HANDOFF.md` — current session resume.
- `SEEDS.md` — parked ideas.
- Subdirs added per track as work progresses: `perforce/`, `ci/`, `accel/`, `unreal/`, `pipeline/`.
- `dashboard/` — observability dashboard aggregating all four built tracks (CI, accel, perforce, Unreal/Lyra) into one self-contained `dashboard.html` that opens offline. Built from a committed real snapshot (`collect-metrics` → `snapshot.json` → `build-dashboard`).

## How to use this repo across sessions

- Open a session: `/jam:startup`. Reads `HANDOFF.md`, gives a resume block.
- Close a session: `/jam:closeout`. Overwrites `HANDOFF.md` with the next-session prompt, optionally appends to `SEEDS.md`.
- Parked thoughts go in `SEEDS.md` so they're not lost between sessions but also don't dilute the active live-edge.

## Operating principle

Bias toward **building real artifacts** over reading. An hour spent standing up TeamCity in a container teaches more than a day reading about CI. Each track ends with something you can point at in an interview and say *"I built this, here's why."*
