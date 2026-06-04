# VCS Trigger — Design Spec (Track 2)

- **Date:** 2026-06-03
- **Track:** 2 (CI / TeamCity build engineering)
- **Status:** Design approved, pending spec review → implementation plan
- **Lever:** Close the end-to-end studio loop — a P4 submit auto-fires the whole build chain, gated by broker policy.

## 1. Goal / win-condition

A P4 submit to `//game/main` that **passes broker policy** automatically fires the
full TeamCity chain (Compile → Smoke Test ‖ Cook Data → Package) within seconds,
with **no human in the loop**. A submit that the broker **rejects** fires nothing.

**Demoable artifact:** `demo-vcs-trigger.ps1` — a single script that proves both
halves (allowed submit → chain fires; frozen-out submit → rejected, no build) and
exits non-zero if either half fails. This is the "I built this, here's why" artifact
for the lever, and it ties Track 1 (broker policy) ↔ Track 2 (CI) by making each
prove the other.

## 2. Background / current state

- The chain already exists (created by `ci/scripts/bootstrap-builds.ps1` via the
  TeamCity REST API). Shape:

  ```
  Compile ──┬─> Smoke Test ─┐
            └─> Cook Data ──┴─> Package
  ```

  Snapshot dependencies are pull-based: triggering **Package** (the terminal node)
  pulls the whole chain; triggering Compile would build Compile alone. So the
  trigger belongs on **Package**, not Compile (correcting the handoff's wording).

- VCS root `AAASandbox_GameMainStream` (verified live): `vcsName=perforce`,
  `port=host.docker.internal:1667` (TeamCity polls **through the broker**),
  `stream=//game/main`, `user=james`. The Track 1↔2 wiring already exists — TeamCity
  sees P4 changes via the broker.
- **No triggers currently exist** on any of the four configs — clean slate.
- The broker (`perforce/broker/p4broker.conf`) sits on `:1667` → `p4d :1666` and
  enforces a code-freeze: `submit` is rejected for everyone except the allowlist
  `^(buildagent|build-svc|infra-svc)$`. This freeze is currently active.
- p4d + broker are **native Windows processes** under `C:\PerforceSandbox\`;
  TeamCity (server + 2 agents) runs in Docker, reset-able via `docker compose down -v`.

## 3. Industry-standard validation

The chosen approach is the JetBrains-documented pattern and what real P4+TeamCity
studios run (Warhorse, Gearbox). Verified against current docs (see §10):

- **Hybrid is correct, not over-built.** `commitHookNotification` *"does not
  automatically trigger builds; it forces TeamCity to check for new changes"* — a
  VCS trigger starts the build. So: P4 trigger = instant notify; VCS trigger = build.
- **Refinements adopted to match best practice exactly:**
  1. **Least-privilege service user** (`ci-hook`) holding only the *Run build*
     permission (Project Developer role) — not james, not superuser.
  2. **10-second delay** in the hook before notifying (JetBrains' own script does
     `sleep 10`) so Perforce finishes processing the changelist before TeamCity checks.
  3. **`change-commit`** confirmed as the correct trigger type (fires after the
     commit is durable).
- **Deliberate deviation (justified by topology):** JetBrains' dedicated script hits
  `/app/perforce/commitHook` and auto-detects roots by matching `p4port`. That fails
  here — the hook runs on the p4d host (`localhost:1666`) but TeamCity knows the root
  as `host.docker.internal:1667`; the strings don't match. We use the **generic**
  `commitHookNotification` endpoint with an explicit VCS-root-id locator instead.
- **Out-scoped improvement (next lever, seeded):** pre-flight / gated builds via the
  **Perforce Shelve Trigger** → personal builds on shelved changelists — validates a
  change *before* it lands on mainline. Bigger capability; captured in SEEDS.md.

## 4. Architecture & data flow

**Happy path — allowlisted submit → instant chain:**

```
dev (build-svc) --p4 submit--> p4broker :1667 --PASS (allowlisted)--> p4d :1666
                                     |                                   | commit lands
                                     v                                   v
                                broker.log                  p4d change-commit trigger
                                (audit)                     (scoped //game/main/...)
                                                                         |
                                                                         v
                                                       notify-teamcity.ps1 (p4d host)
                                                       sleep 10; POST commitHookNotification
                                                       Authorization: Bearer <ci-hook token>
                                                                         |
                                                                         v
                                                  TeamCity: check //game/main now
                                                  -> VCS trigger on PACKAGE fires
                                                  -> Compile -> SmokeTest||CookData -> Package
```

**Frozen-out path — non-allowlisted submit → nothing builds:**

```
dev (james) --p4 submit--> p4broker :1667 --REJECT--> X never reaches p4d
                                |
                                v
                          broker.log (reject logged)
                          -> no commit -> no change-commit trigger -> no build
```

**Key invariant:** the `change-commit` trigger lives in **p4d**, which only ever sees
submits the **broker** allowed through. The policy gate is therefore enforced
*upstream of CI by construction* — CI cannot run on a submit studio policy rejected,
because that submit never becomes a changelist. The hook is also fail-safe:
`change-commit` runs *after* the commit is durable, so a broken/slow hook can never
block or fail a submit.

## 5. Components & file layout

```
ci/scripts/
  setup-vcs-trigger.ps1     # NEW  idempotent: deploy + mint token + VCS trigger + install p4d trigger
  demo-vcs-trigger.ps1      # NEW  policy-gated end-to-end verification (the demo artifact)
perforce/triggers/
  notify-teamcity.ps1       # NEW  change-commit hook; deployed to C:\PerforceSandbox\triggers\ by deploy.ps1
  deploy.ps1                # MODIFY  existing helper — also deploy notify-teamcity.ps1
  README.md                 # MODIFY (additive) existing doc — fold in the hook + loop-safety note
ci/lessons-learned.md       # +#7  post-commit hook: topology + durable-auth gotchas
ci/README.md                # ~    document the trigger + demo
SEEDS.md                    # +    pre-flight gated builds = next lever
```

**Secrets live outside the repo.** The minted token and `hook.log` go under
`C:\PerforceSandbox\triggers\` (the native-P4 state area), not in the git tree —
so there is nothing to gitignore and no risk of committing the token. (This
supersedes the earlier "add to .gitignore" note from the design discussion.)

### 5.1 `setup-vcs-trigger.ps1`

The one script that makes a fresh machine (or a post-`down -v` stack) instant-CI-ready.
Auth for its own REST calls via the superuser-scrape (same as `bootstrap-builds.ps1`).
Idempotent, re-runnable actions:

0. **Deploy the hook** by invoking `perforce/triggers/deploy.ps1`, which copies
   `notify-teamcity.ps1` to `C:\PerforceSandbox\triggers\` — the existing
   deploy-then-register convention, so the git-repo path stays non-load-bearing.
1. **Mint a durable token.** Ensure TeamCity user `ci-hook` exists
   (`POST /app/rest/users`) and holds the `PROJECT_DEVELOPER` role scoped to project
   `AAASandbox`. Mint a durable token named `p4-commit-hook` and write its value to
   `C:\PerforceSandbox\triggers\teamcity-hook.token`. Re-runnable: the token is
   re-minted each run.
   **TC 2026.1 gotcha:** token minting is *self-service only* — `POST .../tokens` as
   the **superuser** is 403-rejected. So the installer sets a random bootstrap password
   on `ci-hook` (as superuser), authenticates **as** `ci-hook` to mint its own token,
   then clears the password in a `finally` (ci-hook ends up bearer-token-only). The
   bootstrap password is random and in-memory only. (See lesson #7.)
2. **Add the VCS trigger** to `AAASandbox_Package`
   (`POST /app/rest/buildTypes/id:AAASandbox_Package/triggers`, type `vcsTrigger`).
   Skip-if-exists. No special poll config needed: the trigger reacts to *detected*
   changes; the server's scheduled VCS check (~60s default) is the fallback path, and
   the hook forces an immediate check on top of it.
3. **Install the p4d `change-commit` trigger** (`p4 -p localhost:1666 triggers -i`,
   run as super `james`), referencing the **deployed** script path, skip-if-present:

   ```
   check-for-changes-teamcity change-commit //game/main/... "pwsh -NoProfile -File C:\PerforceSandbox\triggers\notify-teamcity.ps1 -Change %change%"
   ```

### 5.2 `notify-teamcity.ps1`

Runs on the p4d host on every commit to `//game/main/...`; receives `%change%`.

1. `Start-Sleep -Seconds 10` (commit-visibility buffer).
2. Read Bearer token from `C:\PerforceSandbox\triggers\teamcity-hook.token`.
3. `POST http://localhost:8111/app/rest/vcs-root-instances/commitHookNotification?locator=vcsRoot:(id:AAASandbox_GameMainStream)` with `Authorization: Bearer <token>`.
4. Append outcome (changelist, HTTP status) to `C:\PerforceSandbox\triggers\hook.log`.
5. **Always `exit 0`** — a hook failure must never wedge p4d; the poll fallback
   still catches the change.

### 5.3 `demo-vcs-trigger.ps1`

The demoable artifact / self-test. Setup-then-two-cases:

- **Identity setup (idempotent):** ensure P4 user `build-svc` (`p4 user -f -i`) and a
  client `build-svc-ws` mapping `//game/main/...` exist; `build-svc` matches the broker
  allowlist `^build-svc$`. The non-allowlisted identity is the existing `james`.
- **Demo change target:** `//game/main/ci-demo/heartbeat.txt` — an inert text file
  outside the C++ build globs, so submitting it triggers the chain *and* keeps Compile
  green. (A real source change would trigger identically.)
- **Case A (allowed):** snapshot the latest `AAASandbox_Package` build id; as
  `build-svc` via broker `:1667`, edit + submit `heartbeat.txt`. **Pass** =
  broker.log shows PASS **and** a new Package build (id > baseline) at the new
  changelist appears within 90s **and** it finishes green.
- **Case B (frozen-out):** as `james` via broker `:1667`, attempt the same submit.
  **Pass** = the submit returns the broker reject message / non-zero **and**
  `p4 changes -m1 //game/main/...` shows no new changelist **and** no new Package
  build appears within 30s.
- Print PASS/FAIL per case; exit non-zero if either fails.

## 6. Error handling / edge cases

- **Hook never breaks submits** — `change-commit` fires after the commit is durable,
  and the script always `exit 0`. Worst case: "instant" degrades to "next poll."
- **Polling fallback** — the server's scheduled VCS check (~60s) is the safety net if
  the hook POST fails (TeamCity down, bad token); the change still builds. Failures
  are logged to `hook.log`.
- **Token durability** — the minted `ci-hook` token persists in TeamCity's data dir
  and survives server restarts (unlike the superuser token, which rotates every boot —
  lesson #6). That is the whole reason the hook mints a token instead of scraping.
- **Loop-safety invariant** — the chain emits *TeamCity artifacts* (`build.zip`,
  `Cooked.pak`, the tarball), never P4 submits back into `//game/main`, so there is no
  commit→build→commit loop. The trigger is also path-scoped to `//game/main/...`. This
  invariant is stated in `perforce/triggers/README.md` so nobody later adds an
  artifact-submit-back step without realizing it would self-trigger.
- **Privilege** — installing a p4d trigger and creating P4 users require P4 super
  (james); the hook's TeamCity identity needs only *Run build*.

## 7. Reset story (`docker compose down -v`)

- p4d + broker are native → untouched by `down -v`; the p4d `change-commit` trigger
  entry **persists**.
- TeamCity's data dir is wiped → re-run two scripts: `bootstrap-builds.ps1` (rebuilds
  the chain) then `setup-vcs-trigger.ps1` (re-mints the token, rewrites the cred file
  the persisted p4d trigger reads, re-asserts the VCS trigger). Instant CI restored in
  two commands.

## 8. Out of scope (this lever)

- Pre-flight / gated builds (Perforce Shelve Trigger → personal builds) — **next
  lever**, captured in SEEDS.md.
- P4 Code Review / Swarm integration.
- Hardening the token beyond "lives outside the repo on the p4d host."
- The broker-**bypass** case (direct `:1666` submits skipping the broker) — a Track 1
  concern, not this trigger.

## 9. Assumptions / dependencies to verify during implementation

- `build-svc` can be created and can submit through the broker (broker passes by user
  name; P4 protections allow write to `//game/main/...`).
- `james` holds P4 super in the sandbox (needed for `triggers -i` and `user -f -i`).
- `pwsh` is resolvable from the p4d trigger invocation (else use the full path to
  `pwsh.exe` in the trigger line).
- TeamCity REST specifics hold as written: `PROJECT_DEVELOPER` roleId, the user/token
  endpoints, and `vcsTrigger` type. Confirm against the running server during build.
- `//game/main` has a writable location for `ci-demo/heartbeat.txt`.

## 10. References

- [Configuring VCS Post-Commit Hooks for TeamCity](https://www.jetbrains.com/help/teamcity/configuring-vcs-post-commit-hooks-for-teamcity.html)
- [Integrating TeamCity with Perforce](https://www.jetbrains.com/help/teamcity/integrating-teamcity-with-perforce.html)
- [Perforce Shelve Trigger](https://www.jetbrains.com/help/teamcity/perforce-shelve-trigger.html) ·
  [Running Personal Build](https://www.jetbrains.com/help/teamcity/personal-build.html)
- [Perforce: change-commit triggers](https://help.perforce.com/helix-core/server-apps/p4sag/current/Content/P4SAG/scripting.triggers.submits.commit.html) ·
  [Pre-flight builds and Perforce](https://www.perforce.com/blog/pre-flight-builds-and-perforce)
