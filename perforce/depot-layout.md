# Depot layout — hypothetical small game project

> "Hoops Brawl" — a fictional small AAA-shaped game we use as a test bed for everything in this repo. The point is not the game; the point is exercising the depot-design decisions a real studio makes.

This file is the **design doc** that justifies the Perforce depot structure. In a real shop, this exact kind of document is the thing the build engineer drafts, gets sign-off on from leads, and then enforces with triggers, branch specs, and CI configs.

## Top-level depots

A studio rarely puts everything in `//depot/`. We carve out depots so we can apply different protections, retention, and lifecycle policies to different kinds of data.

```
//engine/        — proprietary engine source (Code-side)
//game/          — the game itself: gameplay code, raw content sources, cooked content
//tools/         — pipeline tools (Python, C# WPF), not shipped to players
//thirdparty/    — vendor source + prebuilt SDKs (large, mostly binary, slow-changing)
//build/         — build automation, CI configs, release manifests, BuildGraph XML
//spec/          — Perforce protection tables, branch specs, triggers, jobspecs (versioned config)
```

### Why split this way

| Depot | Why it's its own depot |
|---|---|
| `//engine/` | Engine is large, has its own ownership / release cadence, and may eventually become a separately-licensed product. Want protection table that lets game team **read** but only engine team **write**. |
| `//game/` | Highest-churn. Need fast `p4 sync` for hundreds of engineers daily. Stream depot so feature branches don't pollute the main view. |
| `//tools/` | Tools team has different release cycle (tools ship to internal users, not players). Different review process — tools can break iteration; game can't. |
| `//thirdparty/` | Binary-heavy, large, slow-changing. Want different archive depot type later (`archive` depot) so old SDK versions don't bloat workspaces. Different sync policy: engineers usually sync a known-good label, not tip. |
| `//build/` | CI lives here. Build engineer owns it. Triggered by changes here we *don't* want a 5GB content sync to fire. |
| `//spec/` | The `spec` depot is a special Perforce depot type that auto-versions branch specs, protections, etc. — invaluable for audit. |

## Stream graph for `//game/`

`//game/` is the only depot we set up as a **stream depot** for this exercise. Streams encode parent/child branching relationships and inheritance — the modern P4 branching model.

```
//game/main             type=mainline      # the trunk
   ├── //game/dev       type=development   # integration target for feature branches
   │     ├── //game/feature-shotmeter      type=development   # short-lived
   │     └── //game/feature-rebound        type=development   # short-lived
   └── //game/release-1-0  type=release    # locked, fix-only
   └── //game/release-1-1  type=release    # locked, fix-only
```

### Live snapshot (`p4 streams` / `p4 depots`, captured 2026-06-04)

The ASCII graph above is the *design intent* — it deliberately shows `feature-rebound` and
`release-1-1` as illustrative future branches. Below is the depot as it **actually exists** in the
sandbox today: the ground-truth output a build engineer pastes into a runbook so the doc can be
diffed against reality instead of trusted on faith (see auto-memory `verify-over-assume-on-portfolio`).

```text
$ p4 streams
Stream //game/dev               development //game/main 'dev'
Stream //game/feature-shotmeter development //game/dev  'feature-shotmeter'
Stream //game/main              mainline    none         'main'
Stream //game/release-1-0       release     //game/main  'release-1-0'
```

Read the third column as the parent link: `main` (mainline, no parent) ← `dev` ← `feature-shotmeter`;
`release-1-0` branches off `main`. Only the streams that were actually cut exist — `feature-rebound`
and `release-1-1` from the sketch above were never created, and a live snapshot surfaces that gap at a
glance. That is the whole point of checking the doc against `p4` output rather than the diagram.

```text
$ p4 depots
Depot build       2026/05/15 local     build/...       'CI configs, BuildGraph, release manifests'
Depot depot       2026/05/15 local     depot/...       'Default depot'
Depot engine      2026/05/15 local     engine/...      'Engine source (proprietary)'
Depot game        2026/05/15 stream  1 game/...        'Game project — streams'
Depot thirdparty  2026/05/15 local     thirdparty/...  'Vendor source + prebuilt SDKs'
Depot tools       2026/05/15 local     tools/...       'Pipeline tools (Python, C# WPF)'
```

`game` is the only `stream`-type depot (StreamDepth `1`); the rest are classic `local` depots. The
`//spec/` depot proposed above is still deferred (see the deferred-decisions table at the end).

**Stream-naming gotcha — `StreamDepth` is fixed per depot.** When you create a stream depot you commit to one depth (we picked `StreamDepth: //game/1` — single segment after `//game/`). That means every stream name must be exactly *one* segment, so `//game/release/1.0` is not legal in this depot — it would be two segments. Real shops handle this in one of two ways:

| Approach | Examples | Trade-off |
|---|---|---|
| **Depth 1 + dashed naming** | `//game/release-1-0`, `//game/feature-shotmeter` | Simple, flat. We picked this. |
| **Depth 2 + namespaced** | `//game/main/main`, `//game/release/1.0`, `//game/feature/shotmeter` | Cleaner namespaces, but every stream URL is two-deep including mainline (some teams find this awkward). |

Either is fine in practice — the lesson is *pick at depot-creation time, you can't change it later without rebuilding the depot.* A real build engineer learns this once and never forgets.

**Flow direction (Perforce stream "merge to / copy to" convention):**

- **merge down** — `main` → `dev` → `feature/*`. Engineers pull mainline changes into their feature streams.
- **copy up** — `feature/*` → `dev` → `main`. Only allowed when the stream is "no changes to merge" (clean). Enforces that integration happens *down* the tree.
- **release branching** — a release stream is `copy`-d from main at branch time, then `merge` only goes from release back to main (cherry-picked fixes). Release never accepts from main.

### View remap example

`//game/main` stream spec:

```
Stream:       //game/main
Owner:        build-team
Name:         main
Parent:       none
Type:         mainline
Paths:
    share Code/...
    share Content/...
    share Tools/.../game/...      # game-specific tool plugins
    isolate Local/...              # per-workspace cache, never submitted
    import //engine/main/Engine/... Engine/...
    import //thirdparty/sdk/...    Thirdparty/sdk/...
Remapped:
    Content/Cooked/... .nosync/Cooked/...    # don't auto-sync cooked artifacts
Ignored:
    *.pdb
    *.exp
    *.tmp
```

**Why the `import` directives matter:** they let engineers see `//engine/` content in their `//game/` workspace as if it were a subdirectory, without having to manage two clients. The engine team still owns the source of truth in `//engine/`.

## Workspace (client) conventions

Workspace names follow `username-machine-stream`:

```
james-WS01-game-main
james-WS01-game-feature-shotmeter
buildbot-CI01-game-main
buildbot-CI01-engine-main
```

The CI machine identity in the client name lets the build engineer find them quickly via `p4 clients -e "buildbot-*"`.

## Protections (`p4 protect`)

Sketch — full table goes in `triggers/protect.p4spec`:

```
write   user    *                       *       //game/...
write   user    *                       *       //tools/...
write   group   engine-team             *       //engine/...
read    group   game-team               *       //engine/...
review  group   engine-team             *       //engine/...
super   user    build-engineer          *       //...
admin   user    build-engineer          *       //...
write   user    buildbot                *       //build/...
write   user    buildbot                CI01    //...                # buildbot can only auth from CI01
=write  user    *                       *       //game/release/...   # exact-match: nobody but release process writes here
```

Note the `=write` on `release/*` — exact-permission lines override the broader `write` above and block accidental release-stream writes. This is the kind of subtle thing that bites studios in shipping crunch.

## File-type policies

`//game/Content/...` is binary-heavy. Some sane defaults to enforce (via `p4 typemap`):

```
binary+l        //game/Content/.../*.uasset       # +l = exclusive lock (texture/mesh/anim)
binary+l        //game/Content/.../*.umap         # maps are also exclusive-lock
binary          //game/Content/.../*.wav
binary          //game/Content/.../*.png
binary          //game/Content/.../*.fbx
text            //game/Code/.../*.cpp
text            //game/Code/.../*.h
text+w          //game/Code/.../*.txt             # +w = always writable (engineers edit in place)
```

The `+l` (lockfile) attribute is **critical** for binary art assets: it forces exclusive checkout so two artists can't both edit a .uasset and lose one's work to merge-impossible conflict. Studios that skip this learn the lesson once.

## Decisions deliberately deferred

| Question | Note |
|---|---|
| Archive depot for thirdparty? | Yes eventually — `//thirdparty/` will move to `type=archive` once it has size pressure. |
| Proxy / broker placement? | **Done.** Broker on `:1667` (`broker/`, policy layer) + proxy on `:1668` (`proxy/`, content cache) both stand up in the sandbox alongside p4d on `:1666`. One proxy per remote office in production. |
| Spec depot path? | `//spec/` is auto-created; just need to enable it in `p4 depots`. |
| Per-stream change-review workflow? | Skipping for now. In real shops use Swarm or Helix Swarm. |

## What to do with this doc

This is the **artifact** for Track 1 step 3. Next steps actually execute it:

1. `p4 depot //engine/` and friends — create each depot.
2. `p4 stream` — define the stream graph above.
3. `p4 protect` — install the protections.
4. `p4 typemap` — install the file-type policy.
5. Submit a couple sample changes through the stream graph to prove `merge-down` / `copy-up` works as described.
