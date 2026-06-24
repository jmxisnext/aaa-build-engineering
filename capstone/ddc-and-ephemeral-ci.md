# Production-scale notes — DDC/CAS and ephemeral CI

The capstone demos two AAA-shaped ideas at **toy scale on bundled tooling**: a content-addressed
cook, and a disposable CI agent. This note frames each at **production scale** — what I built, the
real Unreal/TeamCity feature it maps to, and (for the parts I deliberately *didn't* stand up locally)
why, and what standing them up would take. It's the "I know where this goes" half of the cap.

---

## Part 1 — The cooker is a hand-rolled mini-DDC

`pipeline/cook.py` is a ~400-line content-addressed cook with the same core mechanics as Unreal's
Derived Data Cache. Two hashes do the work (`pipeline/cooker/hashing.py`):

- **`cook_key` = SHA-256(`cooker_version` ∥ `params` ∥ `source_bytes`)** — the identity of a cook
  *input*. An unchanged key short-circuits to the known output without re-cooking. Bumping
  `COOKER_VERSION` changes every key → a global re-cook (exactly how a DDC version/format bump
  invalidates the whole cache).
- **`output_hash` = SHA-256(`cooked_bytes`)** — the identity of a cooked *output*, used as the
  **content-addressable store key**. Blobs are written as `<output_hash>.<ext>`, so identical
  outputs **dedupe** to one file.

The incremental engine (`pipeline/cooker/cache.py`): a persisted `.cookindex.json` maps
`cook_key → {outputHash, ext, size}`. `cook_or_reuse` is a **hit** iff the key is in the index *and*
its blob still exists on disk — only a miss runs the cook function. The `.toc` (`manifest.toc.json`)
is sorted and timestamp-free, so a no-change re-cook is **byte-identical** — determinism you can diff.

**Dependency propagation:** characters reference their assets *by cooked output hash*, so editing one
texture invalidates that texture and only the characters that use it — not the whole set. That's the
DDC property that makes incremental cooks actually incremental.

### Map to Unreal's Zen / DDC

- **Zen Storage Server** is Unreal's content-addressed DDC. Since **UE 5.4** it is the **default
  *Local* DDC backend** — DDC data lives in a separate `Zenserver` process (`AppSettingsDir/Zen/Data`),
  and the legacy filesystem DDC is demoted to delete-only. UE 5.7 also supports Zen as a **Shared
  DDC** and as a **cooked-output store**.
- The parallels are 1:1: my `cook_key` ≈ UE's DDC cache key (input + build/version identity);
  my `output_hash`/CAS ≈ Zen's content-addressed blob store; my `.cookindex.json` ≈ the DDC's
  key→data index; `COOKER_VERSION` ≈ a DDC format/version bump invalidating the cache.
- **The thing being cached at AAA scale is shader compilation.** A cook's cost *is* shader-compile
  time (Track 4, lesson #4: a cold cook was **~24 min / ~15k shaders**). The DDC is what turns that
  into seconds on the second cook — same lever as my cooker's `cached=8` warm hit, just with the
  expensive work being DXC instead of Pillow.

> **GC caveat (honest scope):** my cooker doesn't garbage-collect orphaned blobs/keys (harmless — the
> `.toc` only references current assets). Zen/DDC have real eviction (size/age-based); the legacy UE
> filesystem DDC, e.g., expires after ~N days. GC is the one mini-DDC mechanic I left out.

---

## Part 2 — Why the DDC is *the* cook lever, and why sharing it is a **cross-machine** story

The single most load-bearing lesson from the Unreal track (lessons #4–#5):

- **UE's DDC is a multi-node hierarchy** (Boot → Local → Shared → project), read in order.
  "Move the DDC to fast disk" is multi-node, not one path — `UE-LocalDataCachePath` redirects only
  the Local node (lesson #4, gotcha B). You verify the regime by *where hits resolve*, not by a
  folder's size.
- **A warm *Local* DDC makes a *Shared* DDC look useless on one box.** Setting up a cold→warm shared-
  DDC demo on a single machine, the Shared folder stayed near-empty and the cook still ran fast —
  because every shader resolved as a **Local hit, and Local hits don't back-propagate to Shared**
  (lesson #5). Empty Shared + warm Local ⇒ fast cook + sparse Shared.
- **So the shared-DDC payoff is inherently cross-machine.** Its value is letting a *second* machine
  with a *cold* Local DDC skip shader compile by reading another machine's results. To seed a Shared
  DDC you need producers that genuinely *miss* Local. On one box with one warm Local DDC there's no
  payoff to demonstrate.

Production shape: a team/build-farm points at **one shared Zen DDC** (or Horde's), so the cold
~24-min shader compile is paid **once across the org**, and every other machine/agent reads through.
That's the real-world version of my single-machine `cached=8` — the same content-addressed reuse,
scaled from one box's Local cache to a shared cache across the farm.

---

## Part 3 — Ephemeral CI at production scale (the Kubernetes cloud profile)

**What the capstone demos locally (Slice 2, `capstone/demo-disposable-agent.ps1`):** a fresh
`docker run --rm` agent container that auto-authorizes, runs a build, and is disposed — **ephemeral
compute on a stable, licensed identity.**

**The constraint that shaped it (verified this session):** TeamCity Professional (free) caps at
**3 agent licenses**, and the sandbox uses all 3 (`maxAgents=3, agentsLeft=0`). A genuinely-*new*
4th agent **cannot be authorized** — authorizing one returns `LicenseNotGrantedException`. So the
disposable agent **reuses an existing authorized agent's name + token to reclaim its license**; the
container is disposable, the licensed *identity* is the stable slot. This is not a workaround — it's
exactly how a cloud agent profile works: fixed licensed/cloud capacity, disposable pods/VMs within it.

**Two facts about TeamCity 2026.1 (from the 2026-06-24 audit) that fix the local design:**

1. There is **no bundled Docker-cloud profile** for a local Docker host. The bundled cloud types are
   **Amazon EC2, VMware vSphere, and Kubernetes**; the old third-party Docker-cloud plugins are dead
   (2017/2020-era). So "configure a Docker cloud profile" against local Docker is a dead end — the
   local disposable agent is necessarily a **host-script wrapper** (what Slice 2 is), not a cloud
   profile.
2. The **bundled production-scale path is the Kubernetes cloud profile** (Docker Desktop ships a
   built-in K8s). A cloud profile gives the real thing the host script only mimics: **min/max agent
   counts**, **`terminateIdleMinutes`** automatic disposal, token **auto-authorization**, and agents
   as **pods** created on demand and torn down when idle — all managed by the server, no host script.

**Why I scoped it but didn't stand it up locally (the judgment signal):** a K8s cloud profile is a
multi-session fight — enable Kubernetes in Docker Desktop, wire the API URL / CA / service-account
token, RBAC, a pod template (the agent image + the compose-network reachability the host script gets
for free), and networking back to the server and the Perforce broker — for **no additional
demonstrated capability** beyond what the scripted disposable already shows (spin up → auto-auth →
build → dispose). Knowing the production path and *deliberately* choosing the bundled-tooling-only
local demo is the point; standing up K8s would be motion, not progress.

---

## Local demo → production map

| Capstone (local, bundled tooling) | Production (AAA scale) |
|---|---|
| `cook.py` CAS + `.cookindex.json` incremental skip | **Zen Storage Server** — content-addressed DDC, default *Local* backend since UE 5.4 |
| `cook_key` / `output_hash` / `COOKER_VERSION` | DDC cache key / cached derived data / format-version invalidation |
| warm cache `cached=8` on one machine | **shared Zen DDC** across the farm — cross-machine shader-compile reuse (pay the cold cook once) |
| `--rm` disposable agent reusing a licensed identity | **Kubernetes cloud profile** — pods as agents, min/max, `terminateIdleMinutes`, auto-auth |
| 3-agent license cap (`agentsLeft=0`) | licensed/cloud capacity the cloud profile manages |

---

## References

- Code: `pipeline/cooker/hashing.py`, `pipeline/cooker/cache.py`, `pipeline/README.md`,
  `capstone/demo-disposable-agent.ps1`.
- Lessons: `unreal/lessons-learned.md` #4 (cold cook = shader-compile time; DDC is multi-node) and
  #5 (Local hits don't back-propagate → the shared-DDC speedup is cross-machine).
- Epic docs — [Using the Derived Data Cache](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-derived-data-cache-in-unreal-engine),
  [Zen Storage Server](https://dev.epicgames.com/documentation/en-us/unreal-engine/zen-storage-server-for-unreal-engine),
  [Zen as Shared DDC](https://dev.epicgames.com/documentation/en-us/unreal-engine/set-up-zen-storage-server-as-shared-ddc-for-unreal-engine).
