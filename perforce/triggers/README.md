# Triggers

Server-side hooks that gate or react to Perforce operations. Triggers are how a build engineer enforces policy — and wires automation — at the version-control layer. Some reject bad submits (the studio's "you shall not pass"); some fire downstream automation the instant a change lands.

## What's here

| File | Type | What it does |
|---|---|---|
| `require-engine-tag.py` | `change-submit` | Rejects submits that touch `//engine/...` unless the description contains `[engine]` somewhere |
| `validate-submit.py` | `change-content` | Depot hygiene on `//...`: rejects compiled build output (`.obj/.pdb/.lib/.exe/...`, except `//thirdparty/`) and oversized files (>50 MB) without a `[large-ok]` override |
| `notify-teamcity.ps1` | `change-commit` | On every commit under `//game/main/...`, asks TeamCity to check the VCS root *now* — firing the build chain near-instantly instead of waiting for the next poll |
| `deploy.ps1` | helper | Copies the trigger scripts in this dir (`*.py` + `notify-teamcity.ps1`) to `C:\PerforceSandbox\triggers\` (where p4d reads them from) |
| `demo-validate-submit.ps1` | demo | Self-contained end-to-end proof of `validate-submit.py` — 5 asserted cases, throwaway clients, full cleanup |

## Why a separate deploy step

Trigger scripts must live at a path the **p4d server process** can read. Keeping the canonical script in git (this dir) and deploying to a server-readable path keeps two real-world properties:

1. **The trigger is versioned** — same review/branch/promote story as any code.
2. **The git-repo path is not load-bearing** — if the repo moves, the live trigger keeps running. Only the deploy step needs updating.

In a real shop the deploy step is a CI job that runs on every change to the trigger scripts: validate → unit test → deploy to staging server → smoke test → promote to prod. The same pattern we're practicing in miniature.

## Registering a trigger

The trigger is registered in the per-server `triggers` table:

```
p4 triggers -i
```

reading from stdin a spec like:

```
Triggers:
    require-engine-tag change-submit //engine/... "C:\Python313\python.exe C:\PerforceSandbox\triggers\require-engine-tag.py %change%"
```

Verify with `p4 triggers -o`.

The `change-commit` hook below is registered for you by `ci/scripts/setup-vcs-trigger.ps1`, which deploys the script and appends a line like:

```
check-for-changes-teamcity change-commit //game/main/... "pwsh -NoProfile -File C:\PerforceSandbox\triggers\notify-teamcity.ps1 -Change %change%"
```

## Instant-CI hook (`notify-teamcity.ps1`)

`notify-teamcity.ps1` closes the studio loop: a P4 submit that passes broker policy auto-fires the whole TeamCity chain (Compile → SmokeTest‖CookData → Package). It runs on the p4d host on every commit, waits 10s for the change to settle, then POSTs TeamCity's `commitHookNotification` endpoint (Bearer auth via a durable minted token at `C:\PerforceSandbox\triggers\teamcity-hook.token`). TeamCity's VCS trigger on Package then fans out the chain.

Installed end-to-end by `ci/scripts/setup-vcs-trigger.ps1` (mint token → deploy this script → add the VCS trigger to Package → register the p4d trigger); proven by `ci/scripts/demo-vcs-trigger.ps1`.

It is **fail-safe**: `change-commit` fires *after* the commit is durable and the script always exits 0, so a hook failure can never block a submit — worst case "instant" degrades to "next scheduled poll."

(`hook.log` at `C:\PerforceSandbox\triggers\hook.log` grows unbounded — fine for the sandbox; rotate it if this is ever productionized.)

### Loop-safety invariant (do not break this)

The build chain emits **TeamCity artifacts** (`build.zip`, `Cooked.pak`, the tarball) — it never `p4 submit`s back into `//game/main`. That is what keeps this hook from looping: commit → build → (no commit). **If you ever add a step that submits build output into a path under `//game/main/...`, this trigger will re-fire on it and you'll get an infinite build loop.** Submit such output to a separate depot/path the trigger does not watch, or guard it by user.

### Auth note

The hook uses a durable minted access token, not the superuser token — the latter rotates every server restart (see `../../ci/lessons-learned.md` #6, #7).

## Testing the engine-tag trigger

```powershell
# 1. Negative case — submit to //engine/ without [engine] in description
#    EXPECTED: rejected with our custom message
p4 add Code/Renderer.cpp
p4 submit -d "stub the renderer"

# 2. Update description to include [engine] and resubmit
#    EXPECTED: accepted
p4 change <CL>                          # opens editor to add [engine] tag
p4 submit -c <CL>

# 3. Exemption — submit to //game/ without [engine] tag
#    EXPECTED: accepted (trigger is //engine/-scoped only)
p4 edit //game/main/README.md
# ...modify...
p4 submit -d "tweak README"
```

All three were exercised end-to-end on changes 19 and 20 in this sandbox.

## Depot-hygiene validation (`validate-submit.py`)

A second policy trigger, distinct from the engine-tag one in both *what* it
checks and *which phase* it runs at. It gates two things across the whole depot:

1. **No compiled build output** — `.obj .pdb .lib .exe .dll .ilk .pch ...`. These
   are produced by the build and must be rebuilt from source in CI, never
   versioned. **Exempt: `//thirdparty/`**, whose entire purpose is checked-in
   *prebuilt* vendor SDKs (matches the depot split in `../depot-layout.md`).
2. **No oversized files** (>50 MB, env-overridable via `P4_MAX_FILE_MB`) unless
   the description carries `[large-ok]`. Guards against the accidental giant blob
   that bloats the depot permanently — "permanently" because `p4 obliterate`, the
   only clean removal, is **broker-blocked** (`../broker/p4broker.conf`).

**Why it's `change-content`, not `change-submit`** (the load-bearing detail):
the extension check needs only the file *list* (available at `change-submit`),
but the size check needs the file *content/size*, which is only on the server at
`change-content` (read via the `@=<change>` revision spec). Registering at the
later phase lets one trigger own both rules. Pick the **earliest** phase that has
all the data your check needs — no earlier. (See `../lessons-learned.md` #12.)

Registered as:

```
validate-submit change-content //... "C:\Python313\python.exe C:\PerforceSandbox\triggers\validate-submit.py %change%"
```

### Demo

`demo-validate-submit.ps1` proves it end-to-end and self-cleans (throwaway
clients, obliterates its own committed test files, restores the size threshold):

```powershell
.\demo-validate-submit.ps1
#   PASS  A  .obj in //game/dev rejected
#   PASS  B  clean .cpp accepted
#   PASS  C  oversized rejected (via @=change)
#   PASS  D  oversized + [large-ok] accepted
#   PASS  E  .dll under //thirdparty/ accepted
#   RESULT: 5 passed, 0 failed
```

It restarts p4d with a low `P4_MAX_FILE_MB` so the size cases use ~6 MB files
instead of churning 50 MB through the sandbox, then restores the default on exit.

## Lessons banked while building this trigger

See `../lessons-learned.md` for the full list. New ones from this step:

- **Triggers run in a minimal environment** — p4d does not inherit a useful PATH. Resolve `p4.exe` and any other binaries via full path (or `shutil.which` then a hard-coded fallback). The first attempt at this trigger crashed with `FileNotFoundError: [WinError 2]` because plain `subprocess.run(("p4", ...))` couldn't find p4 on the trigger PATH.
- **`p4 submit -c <CL>` is the resubmit form** — when a submit is rejected by a trigger, the changelist enters *pending* state. A second `p4 submit -d "..."` without `-c` will look at the *default* changelist (empty), not the pending one. Always use `-c <CL>` to retry. This is the second-most-common Perforce confusion after read-only-during-resolve.

(For the instant-CI hook's own lessons — durable token vs. the rotating superuser token, and the auto-detect endpoint's topology assumption — see `../../ci/lessons-learned.md` #7.)

## Hardening the trigger (deferred — interview-discussion points)

The current implementation is a sandbox sketch. In production it would also:

| Hardening | Why |
|---|---|
| Use `p4 -ztag describe` or `p4 -G` (marshal output) instead of regex parsing of `p4 describe -s` | Less brittle; the human-readable describe format is not API-stable |
| Cache the p4 user/ticket for the trigger | Triggers run as the server user; cross-user impersonation is via `-u` |
| Log every rejection to a structured log with CL #, user, timestamp, files | Build telemetry on policy churn — which teams hit the trigger most? |
| Have a "bypass" mechanism (e.g., honor `[skip-engine-gate]` from a privileged user group) | Build engineers themselves need escape hatches for genuine emergencies; the bypass should be audited |
| Run under a timeout so a hung trigger does not hold submits open | Triggers are synchronous from the submitter's perspective; slow triggers feel like outages |
| Integration tests in CI: fire a fake submit at a sandbox p4d and assert behavior | Triggers are the single most under-tested layer in most studios |
