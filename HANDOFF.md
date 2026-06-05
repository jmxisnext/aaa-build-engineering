# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: 923f0d3 - feat(track4): rung #5 capability - CL version-stamp + TeamCity Lyra config

**This repo is PUBLIC:** https://github.com/jmxisnext/aaa-build-engineering . Never commit secrets, the real machine name (scrub to `WS01`), or job-hunt / employer specifics. No co-author trailer (matches the public release). `data/`, `localbak/`, vendor binaries, `accel/extern/`, `accel/.metrics/`, `unreal/.logs/`, and `unreal/.metrics/` are gitignored. `git push` is permission-blocked for the agent - the human runs `! git push origin main`. **Push state corrected: only ~2 commits ahead of `origin/main` now (this handoff + 923f0d3). The prior handoff's "20 ahead" was stale - `origin/main` is at d819f04, so that work was already pushed.**

## What was just built (2026-06-04, session 3 - Track 4 rung #5 CAPABILITY half, infra-free)
The headline-artifact pieces that need NO infra: a packaged Lyra build that self-reports the changelist that made it, plus the TeamCity config that runs the BuildGraph and emits it. The live CI run is the partly-manual follow-up.
- 923f0d3 **Rung #5 capability** - two scripts, committed + verified:
  - `unreal/scripts/stamp-lyra-package.ps1` - writes `build-info.json` INTO the package + a CL-named sidecar beside it (extends the Track-2 `build-info.json` provenance pattern to the Unreal package). **Tested 3 modes against the real 1.72 GB on-disk build** (`D:\LyraPackaged\Windows`): dry-run, standalone, TeamCity-mode. Carries Track-2 lesson #12 forward (cleans prior same-platform/config sidecars before writing, so a glob artifact rule can't double-publish). **Honest-provenance finding: Lyra is a launcher sample, NOT under P4 on this box** - so the "content depot CL" does not literally exist. The stamp records a REAL `engine_changelist` (44394996, from `Build.version`) AND a parameterizable `p4_changelist` (the live `%build.vcs.number%` from CI), each labeled by source - nothing fabricated. On-disk package left in honest standalone state (engine CL).
  - `ci/scripts/bootstrap-lyra.ps1` - provisions `AAASandbox_LyraPipeline` via the CSRF-safe REST pattern (lesson #10): pwsh runner -> `buildgraph-lyra.ps1` then the stamp with `%build.vcs.number%`; **pinned to a WINDOWS agent** (`os.name contains Windows`); VCS root attached MANUAL-checkout (real P4 CL, no needless sync); artifacts publish the stamp. **`-DryRun` validated** (parses, correct REST) - NOT yet applied to a live server.
- d819f04 **Parked seed** - factor the wrapper timing/log/metric spine into a shared `_unreal-common.ps1` helper (the stamp script repeats it once more; still inline, not promoted).

## Live edge
Rung #5 **capability is done + verified standalone**; the **CI config is authored + dry-run-validated but not applied to a live server**. The gating fact for the live run: Lyra needs a **native Windows TeamCity agent** (UE 5.6 + VS2022) - the Linux compose agents physically cannot build it. `bootstrap-lyra.ps1` already pins the Windows requirement. Nothing is running (no Docker, p4d, or broker - all cold).

## Next
**The live infra run - rung #5 HEADLINE demo: "BuildGraph executed from CI, emitting a CL-stamped Lyra package."** In order:
1. **Bring infra up:** start Docker Desktop, then `docker compose -f ci/docker-compose.yml up -d` (server + 2 Linux agents); `perforce/scripts/start-p4d.ps1`; `perforce/broker/start-broker.ps1`. (Compose pins `:latest`, drifted to 2026.x.)
2. **TeamCity first-run wizard** (manual, not scripted): admin account + license. Then `ci/scripts/bootstrap-builds.ps1` if the C++ chain isn't present.
3. **Install + authorize a native Windows TeamCity agent** on this host (it already has the engine `G:\UnrealEngine\UE_5.6`, VS2022, and the repo scripts). Agent zip at `<server>:8111/update/buildAgent.zip`; set `conf/buildAgent.properties` (serverUrl, name); start; **authorize** via UI or REST. This is the net-new, partly-scriptable piece.
4. **Run `ci/scripts/bootstrap-lyra.ps1` for real** (drop `-DryRun`), then trigger `AAASandbox_LyraPipeline`. Watch BuildGraph (warm ~73 s) + stamp emit `build-info.json` + the CL-named sidecar as TeamCity artifacts. **That run IS the demo.**
- **Heads-up (SEEDS, still open):** `bench-agents.ps1` still has the latent CSRF-on-writes bug - patch before relying on it.
- *Then* rung #6: dashboard ingests the `.metrics` cook/package/buildgraph/stamp durations.
