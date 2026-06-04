# Scripted VCS-Root Creation — Design Spec (Track 2)

- **Date:** 2026-06-04
- **Track:** 2 (CI / TeamCity build engineering)
- **Status:** Design approved, pending spec review → implementation plan
- **Lever:** Make the `docker compose down -v` reset story genuinely hands-off — script the
  creation of the `AAASandbox_GameMainStream` VCS-root *definition* so no manual TeamCity
  UI step sits in the middle of "blow it away, rebuild instant CI."

## 1. Goal / win-condition

After a full `docker compose down -v`, a short sequence of **scripted** commands
rebuilds the entire instant-CI stack with **no manual TeamCity-UI click-through**.
The specific gap this closes: nothing in the repo *creates* the Perforce VCS-root
definition the whole chain hangs off — it was created by hand in the UI, so after a
volume wipe it must be recreated by hand before any script works.

**Demoable artifact:** the reset story itself, proven end-to-end — delete the live
root, run `bootstrap-builds.ps1`, and confirm it recreates a root **byte-for-byte
identical** to the hand-made one, after which `setup-vcs-trigger.ps1` +
`demo-vcs-trigger.ps1` pass both policy cases. "I can rebuild the studio's CI from
an empty database in two scripts" is the interview line.

## 2. Background / current state — the precise gap

- `ci/scripts/bootstrap-builds.ps1` builds the chain (Compile → Smoke Test ‖ Cook Data
  → Package) via the TeamCity REST API and **attaches** the VCS root to each build type:
  its `Add-VcsRoot` POSTs `/app/rest/buildTypes/id:<bt>/vcs-root-entries` — a *vcs-root
  **entry*** (an attachment referencing a root by id). It does **not** POST
  `/app/rest/vcs-roots`, which is what *creates the root definition itself*.
- The root definition `AAASandbox_GameMainStream` was created **manually** via the
  TeamCity UI (the field table in `ci/README.md` → "Wiring to Track 1 Perforce").
- The stack was **STOPPED, not `down -v`'d**, so the definition currently still exists
  in the TeamCity DB — which is what let us read its exact shape (see §3).
- After a real `down -v`, the DB is wiped → the definition is gone → `Add-VcsRoot`'s
  attach and `setup-vcs-trigger.ps1`'s trigger both dangle against a non-existent root,
  and the chain cannot sync. The prior VCS-trigger spec (`2026-06-03-…`, §7) claimed
  "instant CI restored in two commands," but that was only ever true *if the root
  survived* — which it does not. **This lever makes that claim actually true.**
- **Documentation drift:** `ci/README.md`'s "Wiring to Track 1" table documents the root
  as a **client mapping** (`//game/main/... //%P4CLIENT%/...`). The live root uses no
  such mapping — it is **stream mode**. The README is wrong and is corrected as part of
  this work. (The `2026-06-03` spec's §2 already described it correctly as stream mode;
  only the README table drifted.)

## 3. Verification — zero-assumption ground truth

The exact root shape and the create-body were **verified against the live server**, not
inferred from docs:

1. Brought the (stopped, data-preserved) stack up; waited for REST to return real JSON
   and scraped the current superuser token (last occurrence — lesson #6).
2. `GET /app/rest/vcs-roots/id:AAASandbox_GameMainStream` → captured all six properties,
   including the exact `workspace-options` block (char-code-inspected: column-16-aligned
   with **spaces**, not tabs; **LF** newlines).
3. **Non-destructive round-trip probe:** `POST`ed a throwaway `…_probe` root with the
   candidate body, `GET` it back, diffed property-by-property against the live root, then
   `DELETE`d the probe. Result: **ZERO diffs across all six properties** — a from-scratch
   scripted root reproduces the hand-made one exactly. The live working root was never
   touched.

**Harness note (not a product concern):** the literal token `rmdir` inside the
`workspace-options` value (a Perforce client option, `…nomodtime rmdir`) trips the
agent sandbox's destructive-command guard *when a REST snippet containing it is run as an
ad-hoc shell command*. Inside the committed `bootstrap-builds.ps1` executed via
`pwsh -File`, the guard scans the command line, not the file body, so the literal is
fine there. Relevant only to anyone replaying these REST calls by hand.

## 4. Verified create-body

`POST /app/rest/vcs-roots` (auth: superuser-scrape, same as the rest of `bootstrap-builds.ps1`):

```
id       = AAASandbox_GameMainStream
name     = "Game Main Stream"
vcsName  = perforce
project  = { id: AAASandbox }          # project-scoped, NOT a global root
properties:
  port              = host.docker.internal:1667   # TeamCity polls through the broker
  user              = james
  use-client        = stream                        # stream mode...
  stream            = //game/main                   # ...bound to this stream
  p4-exe            = p4
  workspace-options = <4-line block, each label PadRight(16) + value, LF-joined>
```

`workspace-options` is reproduced exactly via per-line `.PadRight(16)`:

```
Options:        noallwrite clobber nocompress unlocked nomodtime rmdir
Host:           %teamcity.agent.hostname%
SubmitOptions:  revertunchanged
LineEnd:        local
```

(`"Options:".PadRight(16)` = 8 trailing spaces; `"Host:"` = 11; `"SubmitOptions:"` = 2;
`"LineEnd:"` = 8 — every value column-aligns at 16, matching the captured char codes.)

## 5. Design — `Ensure-VcsRootDefinition`

A new idempotent function added to **`bootstrap-builds.ps1`** (placement decision A:
fold into the existing installer rather than a standalone script — bootstrap already
owns the project, build configs, and root *attachment*, so it owning root *creation* is
cohesive, and the reset collapses to two scripts).

- **Ordering:** called once in the main body **before** the build-type loop, so the
  subsequent `Add-VcsRoot` attaches a root that now exists. The project `AAASandbox` must
  exist first (dependency — see §9).
- **Idempotency:** `GET /app/rest/vcs-roots/id:AAASandbox_GameMainStream`; if present,
  `[skip]` (matching the existing `[create]`/`[skip]` console style). Honors the existing
  **`-Recreate`** switch: when set, `DELETE` the root then re-`POST` it.
- **Body:** the §4 verified body. `workspace-options` built with `.PadRight(16)` per line.
- **Failure:** `$ErrorActionPreference = "Stop"` (script-wide) — a failed create aborts
  bootstrap rather than proceeding to a dangling attach.

### Contract change

`bootstrap-builds.ps1`'s synopsis currently says configs are "attached to the **existing**
Game Main Stream VCS root." After this change it *creates* the root, so the synopsis and
the `ci/README.md` reset note are updated to match.

## 6. Components & file layout

```
ci/scripts/bootstrap-builds.ps1   # MODIFY  add Ensure-VcsRootDefinition + call before the build-type loop; update synopsis
ci/README.md                      # MODIFY  fix "Wiring to Track 1" table (stream mode, not client mapping); update reset story to the true 2-script form
ci/lessons-learned.md             # +#8     "attach ≠ create": the root-entry vs root-definition gap, and doc drift caught by a live round-trip probe
docs/superpowers/specs/2026-06-04-vcs-root-creation-design.md   # NEW (this)
docs/superpowers/plans/2026-06-04-vcs-root-creation.md          # NEW (next, via writing-plans)
```

No new secrets, no new external state. Pure addition of one REST call + idempotency guard
to an existing installer.

## 7. Reset story — now genuinely hands-off

```powershell
docker compose -f ci\docker-compose.yml down -v
docker compose -f ci\docker-compose.yml up -d        # wait for healthy + agents
pwsh -File .\ci\scripts\bootstrap-builds.ps1          # NOW creates the root, then the chain
pwsh -File .\ci\scripts\setup-vcs-trigger.ps1         # mint token + triggers
pwsh -File .\ci\scripts\demo-vcs-trigger.ps1          # both policy cases PASS
```

p4d + broker are native Windows processes → untouched by `down -v`. The only thing that
was previously manual — recreating the VCS root in the UI — is now `bootstrap-builds.ps1`.

**Honest remaining manual step:** TeamCity **agent authorization** (Agents → Unauthorized
→ Authorize) may still be a UI action on a fresh DB. That is a separate concern from the
VCS root and is **out of scope** here (§8); it is called out so the "hands-off" claim is
not overstated.

## 8. Out of scope (this lever)

- **Reconciling drift on an existing root.** `Ensure-VcsRootDefinition` is skip-if-exists
  by id; it does not diff-and-patch a root that exists with stale properties. `-Recreate`
  is the escape hatch (delete + recreate). Documented, deliberate.
- **Agent authorization automation** (see §7) — separate concern.
- **Credentials/tickets** — the sandbox root uses no password (ticket-auth/none); real-shop
  credential handling is not addressed.
- Any change to the trigger, hook, or demo from the `2026-06-03` lever — this is additive.

## 9. Assumptions / dependencies to verify during implementation

- **Project `AAASandbox` exists before the root is created.** The root is project-scoped;
  the `POST` fails if the project is absent. Confirm `bootstrap-builds.ps1` creates (or
  assumes) the project ahead of the new call, and order `Ensure-VcsRootDefinition`
  accordingly. (Pre-flight step in the plan.)
- REST specifics hold as verified: `POST /app/rest/vcs-roots` body shape, `vcsName=perforce`,
  the six property names. (Already confirmed live in §3 — the plan re-confirms on a fresh DB.)
- `-Recreate` delete path: `DELETE /app/rest/vcs-roots/id:…` succeeds when the root has
  attached entries / is referenced by build types, or those must be detached first. Verify
  the delete-while-referenced behavior during implementation.
- The superuser-scrape auth path is identical to the rest of `bootstrap-builds.ps1` (no new
  auth surface).

## 10. References

- [TeamCity REST API — VCS Roots](https://www.jetbrains.com/help/teamcity/rest/manage-vcs-roots.html)
- [Integrating TeamCity with Perforce](https://www.jetbrains.com/help/teamcity/integrating-teamcity-with-perforce.html)
- Prior lever: `docs/superpowers/specs/2026-06-03-vcs-trigger-design.md` (§2 root shape, §7 reset story this corrects)
