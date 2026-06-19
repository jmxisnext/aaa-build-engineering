# Contributing

Whether you're a human or an AI agent (Claude, Copilot, Codex, Gemini, …), the
process is the same. The full rulebook is **[AGENTS.md](./AGENTS.md)**; this is
the step-by-step.

## Per-task workflow

1. **Pick / file an issue.** Work is tracked as GitHub Issues, one per unit of
   work, labeled by track (`track:perforce`, `track:ci`, `track:accel`,
   `track:unreal`, `track:dashboard`). **Assign yourself** to claim it — this is
   how parallel agents avoid working the same task.
2. **Branch** off the latest `main`: `<agent>/<track>-<short-task>`
   (e.g. `copilot/accel-link-bench`).
3. **Work in one track's subdir only.** See AGENTS.md §1.
4. **Open a draft PR early** — it signals "I'm working here" to other agents.
   Reference the issue (`Closes #N`).
5. **Test** using the repo conventions (AGENTS.md §3) and run the local gate:
   ```bash
   ./run-tests.sh
   ```
   Wire any new suite into both `run-tests.sh` and `.github/workflows/tests.yml`.
6. **Mark the PR ready** when `./run-tests.sh` is green and the Definition of
   Done (AGENTS.md §2) is met.
7. **Address review.** CI must be green; resolve review threads or reply with a
   reason. Cross-model review is welcome.
8. **A maintainer squash-merges.** No self-merge.

## Running tests

```bash
# Everything (skips suites whose toolchain is absent):
./run-tests.sh

# Or a single track's suite:
python3 -m unittest discover -s perforce/tests -t perforce/tests -v
(cd ci/samples/hoops-brawl-seed/stream && cmake -S . -B _build && cmake --build _build --target hoops_tests && ctest --test-dir _build --output-on-failure)
pwsh -File dashboard/tests/build-dashboard.Tests.ps1   # needs PowerShell
```

## What "good" looks like here

- A **demoable artifact**, not notes — the repo's operating principle.
- Changes **isolated to one track**.
- **Tests in the no-framework style** (throw on failure, stdlib only).
- Track `README.md` / `lessons-learned.md` updated.
