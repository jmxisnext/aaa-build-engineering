# Scripted Project + VCS-Root Creation — Design Spec (Track 2)

- **Date:** 2026-06-04
- **Track:** 2 (CI / TeamCity build engineering)
- **Status:** Design approved (scope expanded to include the project), pending implementation plan
- **Lever:** Make the `docker compose down -v` reset story genuinely hands-off — script the
  two TeamCity objects the whole chain hangs off that nothing currently creates: the
  **`AAASandbox` project** and the **`AAASandbox_GameMainStream` VCS-root definition**.

## 1. Goal / win-condition

After a full `docker compose down -v` **and** the one-time TeamCity first-run setup,
a short sequence of **scripted** commands rebuilds the entire instant-CI stack with
**no per-reset manual UI click-through**. The gap this closes: two objects the chain
depends on — the project and the Perforce VCS-root definition — were created by hand in
the UI and are recreated by *nothing* in the repo, so after a volume wipe they must be
hand-built before any script works.

**Demoable artifact:** the reset story proven end-to-end — on a wiped DB, run
`bootstrap-builds.ps1` and watch it recreate the project + a root **byte-for-byte
identical** to the hand-made one, then `setup-vcs-trigger.ps1` + `demo-vcs-trigger.ps1`
pass both policy cases. "I can rebuild the studio's CI from an empty database in two
scripts" is the interview line.

**Scope honesty:** "hands-off" means *after initial server setup*. Two UI actions remain
out of scope and are stated plainly in the README (see §7/§8): the **first-run setup
wizard** (admin account + maintenance token) and **agent authorization**.

## 2. Background / current state — the precise gaps

`ci/scripts/bootstrap-builds.ps1` builds the chain (Compile → Smoke Test ‖ Cook Data →
Package) via the TeamCity REST API, but it **assumes two objects already exist** and
creates neither:

1. **The project.** Every `New-BuildType` POSTs `project = {id: AAASandbox}`, and
   `Add-VcsRoot` / the root POST are project-scoped to it — but a repo-wide grep for
   project creation (`/app/rest/projects`, `New-Project`, `parentProject`, …) returns
   **no matches**. The live project (`id=AAASandbox`, name "AAA Sandbox", parent `_Root`)
   was created **manually in the UI**.
2. **The VCS-root definition.** `Add-VcsRoot` POSTs `/app/rest/buildTypes/id:<bt>/vcs-root-entries`
   — a *vcs-root **entry*** (an attachment referencing a root by id), **not**
   `/app/rest/vcs-roots` (which creates the definition). The live root
   `AAASandbox_GameMainStream` was also created **manually** (the field table in
   `ci/README.md` → "Wiring to Track 1 Perforce").

The stack was **STOPPED, not `down -v`'d**, so both objects currently still exist in the
TeamCity DB — which is what let us read their exact shapes (§3). After a real `down -v`,
the DB is wiped → both are gone → `New-BuildType` fails with "project not found" before it
ever reaches the chain. The prior VCS-trigger spec (`2026-06-03-…`, §7) claimed "instant CI
restored in two commands," but that was never true — **this lever makes it true.**

**Documentation drift:** `ci/README.md`'s "Wiring to Track 1" table documents the root as a
**client mapping** (`//game/main/... //%P4CLIENT%/...`). The live root uses no mapping — it
is **stream mode**. The README is wrong and is corrected here. (The `2026-06-03` spec's §2
already described it correctly as stream mode; only the README table drifted.)

## 3. Verification — zero-assumption ground truth

Verified against the live server, not inferred from docs:

- **VCS root (fully proven):** `GET`'d the live root; captured all six properties incl. the
  exact `workspace-options` block (char-code-inspected: column-16-aligned with **spaces**,
  not tabs; **LF** newlines). Then a **non-destructive round-trip probe** — `POST` a
  throwaway `…_probe` root with the candidate body, `GET` it back, diff vs live, `DELETE`
  the probe — showed **ZERO diffs across all six properties**. The live root was never
  touched.
- **Project (shape confirmed, body to probe in plan):** `GET`'d the live project →
  `id=AAASandbox`, `name="AAA Sandbox"`, `parentProject=_Root`. The candidate create-body
  (§4) is simple; the plan's pre-flight runs the same throwaway round-trip to confirm it
  before relying on it.
- **Attachment count (for `-Recreate`, §9):** the live root is referenced by **4 build
  types** (Compile, SmokeTest, CookData, Package).

**Harness note (not a product concern):** the literal `rmdir` inside `workspace-options`
(a Perforce client option, `…nomodtime rmdir`) trips the agent sandbox's destructive-command
guard *when a REST snippet containing it is run as an ad-hoc shell command*. Inside the
committed `bootstrap-builds.ps1` run via `pwsh -File`, the guard scans the command line, not
the file body, so the literal is fine there. Relevant only to anyone replaying these REST
calls by hand.

## 4. Verified create-bodies

**Project** — `POST /app/rest/projects`:

```
{ name: "AAA Sandbox", id: "AAASandbox", parentProject: { locator: "_Root" } }
```

**VCS root** — `POST /app/rest/vcs-roots` (the §3-proven body):

```
id       = AAASandbox_GameMainStream
name     = "Game Main Stream"
vcsName  = perforce
project  = { id: AAASandbox }          # project-scoped — REQUIRES the project to exist first
properties:
  port              = host.docker.internal:1667   # TeamCity polls through the broker
  user              = james
  use-client        = stream                        # stream mode...
  stream            = //game/main                   # ...bound to this stream
  p4-exe            = p4
  workspace-options = <4-line block, each label PadRight(16) + value, LF-joined>
```

`workspace-options`, reproduced exactly via per-line `.PadRight(16)`:

```
Options:        noallwrite clobber nocompress unlocked nomodtime rmdir
Host:           %teamcity.agent.hostname%
SubmitOptions:  revertunchanged
LineEnd:        local
```

(`"Options:".PadRight(16)` = 8 trailing spaces; `"Host:"` = 11; `"SubmitOptions:"` = 2;
`"LineEnd:"` = 8 — every value column-aligns at 16, matching the captured char codes.)

## 5. Design — `Ensure-Project` + `Ensure-VcsRootDefinition`

Two new idempotent functions in **`bootstrap-builds.ps1`** (placement decision A: fold into
the existing installer — it already owns the build configs and the root *attachment*, so it
owning the project + root *creation* is cohesive, and the reset collapses to two scripts).

**Strict ordering** in the main body, before the build-type loop:

```
Ensure-Project              # POST /app/rest/projects (skip-if-exists)
Ensure-VcsRootDefinition    # POST /app/rest/vcs-roots, project-scoped (skip-if-exists)
foreach config: New-BuildType + Add-VcsRoot + steps/deps   # existing loop, now attaches a root that exists
```

- **Idempotency:** each does `GET id:…`; if present, `[skip]` (matching the existing
  `[create]`/`[skip]` console style).
- **`-Recreate`:** honors the existing switch. Project/root deletes must be sequenced
  correctly against the 4 build-type attachments — see §9 (verified in the plan, not assumed).
- **Bodies:** the §4 bodies. `workspace-options` built with `.PadRight(16)` per line.
- **Failure:** script-wide `$ErrorActionPreference = "Stop"` — a failed create aborts
  bootstrap rather than proceeding to a dangling attach.

### Contract change

`bootstrap-builds.ps1`'s synopsis currently says configs are created "under the **existing**
AAASandbox project, attached to the **existing** Game Main Stream VCS root." After this change
it *creates* both, so the synopsis and the `ci/README.md` reset note are updated to match.

## 6. Components & file layout

```
ci/scripts/bootstrap-builds.ps1   # MODIFY  add Ensure-Project + Ensure-VcsRootDefinition, called (in that order) before the build-type loop; update synopsis
ci/README.md                      # MODIFY  fix "Wiring to Track 1" table (stream mode, not client mapping); update reset story to the true 2-script form; state the 2 remaining one-time UI steps
ci/lessons-learned.md             # +#8     "attach ≠ create": the project + root-entry vs root-definition gaps, and doc drift caught by a live round-trip probe
docs/superpowers/specs/2026-06-04-vcs-root-creation-design.md   # NEW (this)
docs/superpowers/plans/2026-06-04-vcs-root-creation.md          # NEW (next, via writing-plans)
```

No new secrets, no new external state. Pure addition of two REST calls + idempotency guards
to an existing installer, reusing its `Invoke-TC` helper and superuser-scrape auth.

## 7. Reset story — now hands-off after initial setup

**Correction found during implementation:** `docker compose down -v` does NOT wipe this
stack. All state is a host **bind mount** under `ci/data/` and `-v` removes only
named/anonymous volumes (here, a lone temp dir) — so `down -v && up -d` returns the
server with project/root/chain intact, and bootstrap would `[skip]` everything. The
earlier spec's "down -v reset" premise (inherited here in draft) was false. Two real
reset paths:

- **Config reset (the one verified — no wizard):** delete the `AAASandbox` project
  (`DELETE /app/rest/projects/id:AAASandbox`, cascades root + chain) → `bootstrap-builds.ps1`
  recreates project + root + chain from absence → `setup-vcs-trigger.ps1` → `demo-vcs-trigger.ps1`.
- **Full wipe:** stop, delete `ci/data/teamcity_server/datadir` (+ agent `conf`), `up -d`
  — truly empty, but resurrects the one-time first-run wizard + agent authorization.

p4d + broker are native Windows processes → untouched either way. The two things
previously manual *per config reset* — creating the project and the VCS root — are now
`bootstrap-builds.ps1`. The first-run wizard + agent authorization remain the only
unscripted steps (§8), and only the full wipe re-triggers them. See lessons #9.

## 8. Out of scope (this lever)

- **First-run setup wizard** (admin account + maintenance token) — a one-time-per-server UI
  flow, not per-reset; not scripted.
- **Agent authorization** — UI action on a fresh DB; separate concern, stated in README so
  "hands-off" is not overstated.
- **Reconciling drift on an existing project/root.** Both `Ensure-*` are skip-if-exists by
  id; they do not diff-and-patch an object that exists with stale properties. `-Recreate` is
  the escape hatch. Deliberate.
- **Credentials/tickets** — the sandbox root uses no password (ticket-auth/none); real-shop
  credential handling is not addressed.
- Any change to the trigger, hook, or demo from the `2026-06-03` lever — this is additive.

## 9. Assumptions / dependencies to verify in the plan (pre-flight)

- **Project create-body** (§4) round-trip-probed before use (same technique as the root).
- **Ordering** project → root → build-types holds; `New-BuildType` and the root POST both
  fail fast if the project is absent (already `Stop`).
- **`-Recreate` delete-while-referenced — UNVERIFIED, do not assume.** The live root has 4
  attachments. It is not yet known whether `DELETE /app/rest/vcs-roots/id:…` cascades
  (auto-detaches) or refuses with 409. The plan **verifies this non-destructively** (throwaway
  root + throwaway build type + attach + delete + observe), then codes `-Recreate` to a clean
  teardown order (build types → root → project) → rebuild (project → root → build types) based
  on the result. The **fresh-DB reset path is create-only**, so this affects only re-runs
  against a populated DB.
- **`p4-exe=p4`** requires `p4` reachable by TeamCity — already satisfied (the live chain
  syncs; lesson #2 put `p4` in the agent image). Noted, not a new dependency.

## 10. References

- [TeamCity REST API — VCS Roots](https://www.jetbrains.com/help/teamcity/rest/manage-vcs-roots.html) ·
  [Projects](https://www.jetbrains.com/help/teamcity/rest/manage-projects.html)
- [Integrating TeamCity with Perforce](https://www.jetbrains.com/help/teamcity/integrating-teamcity-with-perforce.html)
- Prior lever: `docs/superpowers/specs/2026-06-03-vcs-trigger-design.md` (§2 root shape, §7 reset story this corrects)
