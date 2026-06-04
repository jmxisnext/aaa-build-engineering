# perforce/triggers

The instant-CI hook for Track 2's VCS trigger.

`notify-teamcity.ps1` is registered in p4d as a **change-commit** trigger on
`//game/main/...` (installed idempotently by `ci/scripts/setup-vcs-trigger.ps1`).
On every commit it asks TeamCity to check the VCS root immediately, collapsing
poll latency to ~instant. TeamCity's VCS trigger on Package then fires the chain.

## Install / reinstall

```
pwsh -File ci\scripts\setup-vcs-trigger.ps1
```

This mints the durable token (written to `C:\PerforceSandbox\triggers\teamcity-hook.token`,
**outside this repo**), adds the VCS trigger to Package, and installs the p4d trigger.

## Loop-safety invariant (do not break this)

The build chain emits **TeamCity artifacts** (`build.zip`, `Cooked.pak`, the
tarball) — it never `p4 submit`s back into `//game/main`. That is what keeps
this hook from looping: commit → build → (no commit). **If you ever add a step
that submits build output into a path under `//game/main/...`, this trigger
will re-fire on it and you'll get an infinite build loop.** Submit such output
to a separate depot/path the trigger does not watch, or guard it by user.

## Auth note

The hook uses a durable minted access token, not the superuser token — the
latter rotates every server restart (see `ci/lessons-learned.md` #6, #7).
