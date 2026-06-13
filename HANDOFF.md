# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 514378c - docs(track4): reconcile roadmap + Track-4 README with Horde Step-2 progress

**Repo is PUBLIC** (https://github.com/jmxisnext/aaa-build-engineering): never commit secrets, the
real machine name (scrub to `WS01`), or job-hunt specifics. **No co-author trailer.** `git push` is
agent-blocked — the human runs `! git push origin main`. **Unpushed: 3 commits** (this session's two
+ the closeout) — push when convenient.

## What was just built
- 514378c - docs: reconcile ROADMAP_NEXT + unreal/README with Horde Step-2 progress (was still "smallest slice / in progress").
- d816ec7 - feat: the unmodified `lyra-pipeline.xml` runs **compile→cook→package end-to-end under Horde** (job `6a2da13d…`, Complete; ~28.5 min, cook ~24.6 min cold-ish). Horde job emits a `source=horde` `.metrics`; the dashboard renders an **"Orchestrator parity — Horde vs TeamCity"** row (collector groups buildgraph by source; `stages` baseline excludes Horde to stay warm/honest). Both dashboard test suites green. Stream template default flipped to the full pipeline. Root cause of the initial hang found + checklist-fixed: **p4d was down**, and Horde validates the Perforce cluster at lease-assignment → infinite lease-cancel loop.

## Live edge
Step 2 is functionally done — the full graph runs under Horde and the dashboard proves portability.
The one remaining Step-2 gap is **CL-stamp parity**: the BuildGraph `Package` node writes the paks
but not `build-info.json`, so `D:\LyraPackaged\Windows\build-info.json` still carries the *prior
TeamCity* stamp (CL 51, built 2026-06-05), not the Horde run's.

## Next
Close CL-stamp parity: run `unreal/scripts/stamp-lyra-package.ps1` against the Horde-produced package
in `D:\LyraPackaged` (or add a stamp node to `lyra-pipeline.xml`), emitting a `source=horde` stamp
`.metrics` so the dashboard's stamp provenance reflects the Horde run, then mark README Status #4 done.
**First, bring services up** (this session killed them): `.\perforce\scripts\start-p4d.ps1` then
`dotnet G:\HordeAgent\HordeAgent.dll` — **p4d MUST be listening on :1666 before submitting** or the
job hangs in a lease-cancel loop (see `unreal/horde/README.md` machine-state checklist).
