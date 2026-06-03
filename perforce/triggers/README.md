# Triggers

Server-side hooks that gate Perforce operations. Triggers are how a build engineer enforces policy at the version-control layer — the studio's "you shall not pass" mechanism.

## What's here

| File | Type | What it does |
|---|---|---|
| `require-engine-tag.py` | `change-submit` | Rejects submits that touch `//engine/...` unless the description contains `[engine]` somewhere |
| `deploy.ps1` | helper | Copies all `*.py` scripts in this dir to `C:\PerforceSandbox\triggers\` (where p4d reads them from) |

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

## Lessons banked while building this trigger

See `../lessons-learned.md` for the full list. New ones from this step:

- **Triggers run in a minimal environment** — p4d does not inherit a useful PATH. Resolve `p4.exe` and any other binaries via full path (or `shutil.which` then a hard-coded fallback). The first attempt at this trigger crashed with `FileNotFoundError: [WinError 2]` because plain `subprocess.run(("p4", ...))` couldn't find p4 on the trigger PATH.
- **`p4 submit -c <CL>` is the resubmit form** — when a submit is rejected by a trigger, the changelist enters *pending* state. A second `p4 submit -d "..."` without `-c` will look at the *default* changelist (empty), not the pending one. Always use `-c <CL>` to retry. This is the second-most-common Perforce confusion after read-only-during-resolve.

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
