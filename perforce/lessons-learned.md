# Perforce lessons learned (Track 1)

Real-world gotchas hit during the sandbox build-out — each a war story worth keeping: what bit, why a build engineer cares, and the fix.

## 1. `noallwrite` makes local files read-only — silent edit loss

**What happened:** After `p4 sync` I appended to `README.md` via PowerShell's `Add-Content` *before* running `p4 edit`. PowerShell did not surface an error. `p4 submit` ran clean. Change 8 went through. But the appended lines never made it to the depot — `p4 print` showed the original content.

**Root cause:** Workspace `Options` include `noallwrite`, which makes sync'd files read-only on disk. The append failed silently because PowerShell's default `$ErrorActionPreference` is `Continue`. `p4 edit` toggles the read-only bit; you must run `p4 edit` *before* the local modification, not after.

**Fix:** Always `p4 edit` before touching a file. Scripts that auto-modify files should either set `$ErrorActionPreference = "Stop"` or check `(Get-ItemProperty file).IsReadOnly` and call `p4 edit` first.

**Why a build engineer cares:** This bites artists especially hard — Photoshop or Maya will let you save into the workspace, silently losing the file to read-only when no Perforce client is integrated. A real shop solves it with:
- Tooling integration (Maya/Max plugins that auto-`p4 edit` on save)
- `allwrite` workspaces for content-author roles (paired with stricter triggers)
- File watcher that warns when read-only files are modified outside p4

## 2. `p4 populate` argument order: flags before paths

**What happened:** `p4 populate //game/main/... //game/dev/... -d "msg"` failed with `Missing/wrong number of arguments`.

**Fix:** Flags must come before positional args: `p4 populate -d "msg" //game/main/... //game/dev/...`. This isn't universal across `p4` commands — most accept flags anywhere — but `populate` is strict.

## 3. New stream depots start *empty*; `p4 populate` is mandatory

**What happened:** After `p4 stream -i` created `//game/dev` (parent `//game/main`), `p4 files //game/dev/...` returned `no such file(s)`. The README.md visible in `//game/main` did not auto-appear in dev.

**Root cause:** Streams encode a *view* of their parent, not a copy. To actually populate a new stream with its parent's content, you must run `p4 populate <parent>/... <stream>/...` (or `p4 populate -S <stream>`). Until then the stream is structurally defined but contains zero files.

**Why a build engineer cares:** A common mistake when standing up a new release branch is to define the stream and assume sync'ing will pull from the parent. It won't — and your release branch is empty, which the on-call engineer discovers at 11pm Friday before a launch window.

## 4. `StreamDepth` is fixed at depot creation

**What happened:** Depot created as `StreamDepth: //game/1`, then I tried to define `//game/release/1.0` (two segments after `//game/`). Stream creation rejected.

**Fix:** Either (a) pick depth 1 and use dashed naming (`//game/release-1-0`, `//game/feature-shotmeter`), or (b) recreate the depot with `StreamDepth: //game/2` and live with two-segment names for everything including `//game/main/main`.

**Why a build engineer cares:** This is a *one-time decision* — you can't change StreamDepth after a depot has streams in it. You'd have to recreate the depot, lose history, and migrate workspaces. Always pick depth at depot-design time, document the rationale.

## 5. Stream depots reject path-form integration commands

**What happened:** `p4 copy //game/feature-shotmeter/... //game/dev/...` failed with `Must use a stream view to copy into //game/dev`.

**Fix:** Use the stream-aware form: `p4 copy --from //game/feature-shotmeter` (run from a workspace bound to the target stream). The path-form is only legal between non-stream depots, or in *unrelated* stream depots.

**Why a build engineer cares:** Lots of legacy automation uses path-form integrate. When migrating an old depot to streams, every script that runs `p4 integrate src/... tgt/...` needs an update.

## 6. `p4 copy --from` only does *copy*-compatible work — `merge` brings the rest

**What happened:** `p4 copy --from feature-shotmeter` from a dev workspace copied Shotmeter.cpp (a clean *branch* — file new on this side) but did not bring a parallel README edit (whose content also differed). Output said "1 file" instead of "2 files."

**Root cause:** In Perforce, *copy* and *merge* are different actions:
- **copy** — for "no real merge needed; just move bytes." Fails when the target has its own history that diverges from the ancestor.
- **merge** — for "needs review; may have conflicts." Always opens for `p4 resolve` even if auto-resolvable.

`copy --from` runs both passes but only emits the *copy*-eligible files. To bring everything, run `p4 merge --from <src>`, resolve, then `p4 copy --from <src>` for the rest. In the stream model, this is the canonical "**merge-down**" / "**copy-up**" dance.

## 7. `p4 resolve -am` correctly *skips* conflict cases — and that's the point

**What happened:** Created a deliberate conflict (main bumped `release_window_ms` to 110.0f; feature bumped it to 75.0f). Merged main → dev (auto-resolved cleanly because dev had no local edits). Then merged dev → feature, which has feature's 75.0f vs dev's now-110.0f.

`p4 resolve -am` output: `Diff chunks: 0 yours + 0 theirs + 0 both + 1 conflicting. resolve skipped.`

**The lesson:** This is the *correct* behavior. `-am` is "auto-merge safe cases only." Conflicting chunks are intentionally left for a human. A build engineer designing a CI integration job should run `p4 resolve -am` followed by `p4 resolved` — if anything is still unresolved, the job stops and pings the merge owner.

## 8. Merge-target files stay read-only during resolve — second-order silent loss

**What happened:** Wanted to hand-resolve to 95.0f (compromise). After `p4 merge --from //game/dev` had marked Shotmeter.cpp as needing resolve, I tried to `Set-Content` the local file to write 95.0f. PowerShell said `Access denied`. I missed the error and ran `p4 resolve -ay`, which marked resolution as "accept yours = current on-disk content" — which was still 75.0f, the unchanged feature value. Result: main's 110.0f change was effectively reverted.

**Root cause:** Files in the "needs resolve" state are read-only. The merge tool (or `p4 resolve -e` interactive editor) is the supported way to write the resolved content. Or `attrib -r` then edit, then mark resolved.

**Why a build engineer cares:** A common content-team workflow problem. Artist starts a merge in P4V, gets distracted, comes back, opens file in DCC tool, "fixes" things by saving over the merge state, then "marks resolved" — losing one side of the merge silently. Solutions:
- Train the team to always finish resolves before context-switching.
- Custom tool that screams when a resolve is left open for > 1 hour.
- Trigger: reject submits with `... resolve skipped.` files still pending.

## 9. Trigger scripts run in p4d's environment — no PATH

**What happened:** First trigger script crashed with `FileNotFoundError: [WinError 2]` when it ran `subprocess.run(("p4", ...))`. The trigger had been registered and was firing correctly — the crash was inside the script. Plain `"p4"` couldn't be resolved because p4d's child-process environment doesn't have the user PATH on Windows.

**Fix:** Resolve external executables explicitly. The trigger now uses `shutil.which("p4")` as a first attempt and falls back to `C:\Program Files\Perforce\p4.exe`. Override via `P4_EXE` env var for testing.

**Why a build engineer cares:** This is the *first* thing that goes wrong when you migrate triggers from dev to a fresh prod server. The dev box has p4 on PATH for the interactive shell; the prod p4d child env doesn't. The trigger works in dev tests, fails on prod. The fix is to always pin tooling paths in triggers, and have a CI integration test that runs the trigger against a sandbox p4d under the same env constraints prod uses.

## 10. `p4 submit -c <CL>` is the resubmit form for trigger rejections

**What happened:** A trigger rejected change 19. The changelist entered *pending* state. A second `p4 submit -d "..."` without `-c 19` reported `No files to submit from the default changelist` because the default changelist was empty — the files were still attached to pending CL 19.

**Fix:** Always retry with `p4 submit -c <CL>` after a trigger rejection. To change the description on retry, update via `p4 change -o <CL> | <edit> | p4 change -i` first, then `p4 submit -c <CL>`.

**Why a build engineer cares:** This is the second-most-common Perforce confusion after read-only-during-resolve. Engineers think their files vanished. They didn't — they're sitting in the pending changelist, which `p4 changes -s pending` will show.

## 11. Broker allowlist = ordered first-match rules; anchor the user regex

**What happened:** The code-freeze rule (`command: ^submit$ { action = reject; }`) blocked *everyone*, including the `buildagent` CI identity. During Track 2 that forced a broker *bypass* — submitting straight to p4d on `:1666` — to seed the depot. It worked, but the submit then never appeared in `broker.log` (see `../ci/lessons-learned.md` #3: "the broker is a router, not a journal").

**Fix:** Add a service-account allow rule *before* the reject. Broker command handlers are first-match-wins, so ordering is the whole mechanism:

```
command: ^submit$           # evaluated first
{
    user   = ^(buildagent|build-svc|infra-svc)$;
    action = pass;
}
command: ^submit$           # only reached if the user didn't match above
{
    action = reject;
}
```

Two gotchas:
- **Order matters.** Put the reject first and the allow rule is dead code — every submit is rejected before the allow is ever consulted.
- **Anchor the user regex.** `user = build-svc;` is unanchored — it also matches `build-svc-test`, `not-build-svc`, etc. Use `^(...)$`, the same discipline as the command pattern (`^submit$`, not bare `submit`).

**Verified:** through the broker, `buildagent` and `build-svc` submits log `Config: [PASS] / Action: [PASS]` and reach p4d (which replies `No files to submit from the default changelist` — a p4d-only message, proving traversal); `james` logs `[REJECT]` and gets the freeze message from the broker itself.

**Why a build engineer cares:** This is how you reconcile two requirements that look contradictory — "freeze all submits" and "the build pipeline must keep submitting." The exemption belongs in *policy* (versioned, reviewable, logged), not in an operator remembering to bypass. And because allowed submits PASS *through* the broker, they stay in `broker.log` — closing the audit-trail gap that bypassing opened.

**Takeaway:** *"A broker freeze that blocks everyone forces people to bypass the broker, which destroys your audit trail. The fix is an ordered allowlist — service-account `pass` rule before the blanket `reject`, anchored user regex — so automation keeps moving AND every submit decision still lands in the broker log."*

## 12. `change-submit` vs `change-content` — register at the phase that has your data

**What happened:** Building `validate-submit.py` (a depot-hygiene trigger that rejects compiled build output *and* oversized files), the size rule needs each file's byte count. Wired naively as a `change-submit` trigger, the forbidden-extension half worked but the size half always no-op'd — `p4 fstat` came back with no `fileSize` because the file content wasn't on the server yet.

**Root cause:** A submit fires three trigger phases in order — **`change-submit`** (after submit starts, *before* file transfer: metadata + file list only), **`change-content`** (after transfer, *before* commit: content is on the server, addressable via the `@=<change>` revision specifier), **`change-commit`** (after the commit is durable: too late to reject). A check that needs only the file *list* — forbidden extensions, or the existing `require-engine-tag` description check — can run at `change-submit`. A check that needs the *bytes/size* must run at `change-content`.

**Fix:** Register `validate-submit` as **`change-content`** and read sizes with `p4 fstat -Ol //path@=<change>` — the `@=change` spec resolves to the in-flight content of the pending change. One trigger then authoritatively enforces both rules. Proven by `triggers/demo-validate-submit.ps1` (5/5 cases: build-artifact reject, clean accept, oversized reject *via @=change*, `[large-ok]` override accept, `//thirdparty/` exemption accept).

**Why a build engineer cares:** Getting this wrong yields a trigger that *passes a quick test* (the extension half fires) but silently lets multi-GB blobs through (the size half ran too early to see them) — the classic "green in the demo, broken in prod" trap. Rule of thumb: register at the **earliest** phase where all the data your check needs already exists, and no earlier. And the size rule is preventive for a reason: an oversized file is effectively permanent here because `p4 obliterate` is **broker-blocked** (`broker/p4broker.conf`) — cheaper to stop the blob at submit than to file a ticket to rewrite history.

## 13. p4p / p4d / p4broker are not in the P4V bundle — separate filehost binaries

**What happened:** The roadmap said "proxy/broker"; only the broker existed. Standing up the proxy needs `p4p.exe`, which — unlike `p4`, `P4V`, `P4Admin`, `P4Merge` — is **not** part of `winget install Perforce.P4V`. Like `p4d.exe` and `p4broker.exe` it's a standalone download from the Perforce filehost, version-matched to the server (`r25.2/bin.ntx64/p4p.exe`).

**Second-order lesson (tooling / security):** an agent-initiated download of an executable from an external URL is — correctly — a **gated action**; the harness blocked the auto-download. The right response is not to route around the gate but to build the *entire* harness (`start-p4p.ps1`, `stop-p4p.ps1`, `demo-proxy.ps1`, `proxy/README.md`) so the human-approved binary fetch is the **single** remaining step, documented with the exact command. See `proxy/README.md`.

**Why a build engineer cares:** Knowing which Helix components ship in which package is provisioning-101 — you do **not** get `p4d`/`p4broker`/`p4p` from the visual-client installer, so a "just install P4V" runbook leaves you without a server, broker, or proxy. And "build everything around the one privileged step" is exactly how you keep provisioning/CI automation reviewable instead of smuggling credentialed or binary-fetching steps into the middle of a script.

---

## TL;DR — interview-ready bullets

These are the kinds of one-liners a build engineer interviewee should be able to deliver fluently:

- "Stream depots require `p4 populate` to seed new streams from a parent — they don't auto-inherit content."
- "`StreamDepth` is fixed at depot-creation; that's a one-time decision and you pick the segment count up front."
- "Stream depots restrict integration to the stream-aware form; path-form `p4 copy src tgt` won't work — must be `--from <stream>`."
- "`copy-up` and `merge-down` are the two halves of stream promotion: copy only handles trivial cases, merge handles conflict-bearing cases. Use both."
- "`p4 resolve -am` is the right setting for CI — it auto-resolves the safe stuff and leaves a human-flagged remainder."
- "On Windows, `noallwrite` workspaces silently fail saves before `p4 edit`. Tools that save into the workspace need integration to call `p4 edit` first, or the workspace needs `allwrite`."
- "Triggers run in p4d's environment, not the user's — always pin full paths for external tools, and integration-test triggers under the prod env constraints."
- "After a trigger rejects a submit, the changelist enters *pending* state — retry with `p4 submit -c <CL>`, not a fresh `p4 submit -d ...`."
- "Broker command patterns are regex — bare `submit` would also match `submitlist` etc. Anchor with `^submit$`."
- "Broker `redirection = selective` (default) prevents replication-lag bugs in GUIs by sticking a session to master once a write touches it; `pedantic` always reroutes per-command rule. Production usually wants selective for interactive sessions and pedantic for scripted workloads against replicas."
- "Proxy = file-content cache; broker = command-level policy; replica = read-mostly mirror; edge server = local-write replica that forwards submits. Real studios run all four."
- "A broker freeze that blocks everyone forces an audit-destroying bypass. Reconcile 'freeze' with 'CI must keep submitting' via an *ordered* service-account allowlist — a `pass` rule (anchored user regex) before the blanket `reject` — so allowed submits stay in `broker.log`."
- "Submit triggers fire change-submit → change-content → change-commit. Filename/description rules can run at change-submit; size/content rules MUST run at change-content, reading bytes via the `@=<change>` revision spec. Register at the earliest phase that already has your data."
- "p4p (proxy), p4d (server), and p4broker are NOT in the P4V client bundle — they're separate version-matched filehost binaries. Provisioning a server or remote office means fetching those, not running the GUI installer."
