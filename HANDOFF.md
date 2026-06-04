# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: f6a5681 - docs(track2): correct reset story - down -v doesn't wipe bind mounts (lesson #9)

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. Commits carry **no co-author trailer** (matches the public release). `data/` and `localbak/` (TeamCity DB/agent conf, pre-reset snapshots) plus vendor binaries are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **9 increment commits (`55f175a..f6a5681`) + this closeout are local and UNPUSHED.**

## What was just built
Track 2 - **scripted VCS-root + project creation**: `bootstrap-builds.ps1` now rebuilds the studio's CI config (project + Perforce VCS root + chain) from an empty project with no manual TeamCity-UI step. 9 commits, newest first:
- `f6a5681` Correct reset story + **lesson #9**: `docker compose down -v` does NOT wipe this stack (state is host **bind mounts**, not volumes) - the inherited "reset" was a no-op. Documented the two real resets (config-level project delete; full datadir wipe).
- `999fb75` **Lesson #8**: "attach != create" - bootstrap attached a root + referenced a project that *nothing created*; idempotent != reproducible.
- `dd3d13d` README: VCS root is **stream mode** (not the client-mapping the docs claimed) + auto-created; honest reset story.
- `a9b4ea7` / `cbcffa4` `Ensure-Project` + `Ensure-VcsRootDefinition` in bootstrap (live-verified, zero-diff-probed bodies), wired project->root->chain with a safe reverse-dependency `-Recreate` teardown.
- `55f175a` / `f59e0ee` / `52b063b` design spec (scope expanded to include the project) + 8-task implementation plan.
- The prior session's **VCS-trigger increment** (through `851af05`) is now also merged & public - its closeout never ran (power outage); this session merged everything to main.

## Live edge
VCS-root-creation increment is **complete and verified end-to-end**, merged to main (fast-forward), 9 commits local & unpushed. Verified live this session: idempotent no-op, `-Recreate` zero-diff, and a **config-level reset** (deleted the AAASandbox project -> `bootstrap-builds.ps1` recreated project+root+chain from absence -> `demo-vcs-trigger.ps1` both policy cases PASS, exit 0). Carried thread closed: `bench-agents.ps1` by-name fix (`b3c708f`) ran live - resolves `agent-linux-02` -> id 11, 2.18x leaf. Sandbox infra (TeamCity x3 + p4d + broker) is **STOPPED**, data preserved.

## Next
1. **Push:** human runs `! git push origin main` (9 increment commits + this closeout).
2. **Pick the next Track 2 lever.** Strongest is **pre-flight / gated builds** (TeamCity Perforce Shelve Trigger -> personal builds on shelved changelists) - validates a change *before* it lands on mainline; already seeded in `SEEDS.md` (2026-06-03) as the explicit next lever after the VCS trigger. (Alt: native Windows agent for MSBuild; or script the last unscripted reset steps - agent authorization + first-run wizard - see today's new seed.)
3. **Bring the stack up first** for any Track 2 work: `perforce\scripts\start-p4d.ps1` -> `perforce\broker\start-broker.ps1` -> `docker compose -f ci\docker-compose.yml up -d`. On restart TeamCity re-inits for a few min and **rotates the superuser token** - scrape the *last* occurrence after init (lesson #6), don't tight-loop auth.
