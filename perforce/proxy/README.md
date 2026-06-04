# proxy/ — Perforce Proxy (p4p)

The **proxy** is the third process in the Track 1 topology, alongside the server
and the broker. All three speak the Perforce protocol; they sit at different
layers and do different jobs:

```
client ──▶ p4p     :1668   caches file CONTENT near the consumer      (this dir)
client ──▶ p4broker:1667   enforces command POLICY                    (../broker/)
client ──▶ p4d     :1666   the source of truth                        (../scripts/)
```

## What a proxy is for

A `p4d` master holds every revision of every file. In a single office that's
fine; across a WAN it is not — pulling a 4 GB texture pack from a master three
timezones away, once per engineer, saturates the link and makes `p4 sync` slow.

A **Perforce Proxy** is a caching forward-proxy you place *in the remote office*.
It forwards **metadata** (which files, which revisions, who has what) to the
master, but serves **file content** from a **local cache**. The first person in
the office to sync a revision pulls it across the WAN and into the proxy cache;
everyone after them is served from the cache at LAN speed. The master never
re-sends that revision to that office again.

This is the single most common piece of "make Perforce fast for a distributed
studio" infrastructure, and the literal gap this directory closes in Track 1.

> Proxy vs broker vs replica vs edge — the full vocabulary cheat sheet lives in
> `../broker/README.md`. Short version: **proxy = content cache** (no policy, no
> metadata of its own), **broker = policy router** (no cache), **replica/edge =
> a real second server** with its own metadata. They compose: a remote office
> typically runs an edge server *and* a proxy.

## One-time setup: download p4p.exe

p4p is **not** bundled with P4V (which ships p4, P4V, P4Admin, P4Merge). Like
`p4d` and `p4broker` it is a standalone binary from the Perforce filehost. It is
kept **outside** the git repo (binaries don't belong in source; the repo holds
scripts only — same rule as `p4d.exe` in the main README).

Download it once, version-matched to the 2025.2 server (run with your approval —
fetching an executable is intentionally a human-gated step):

```powershell
Invoke-WebRequest `
  -Uri  https://filehost.perforce.com/perforce/r25.2/bin.ntx64/p4p.exe `
  -OutFile 'C:\PerforceSandbox\bin\p4p.exe'
```

`start-p4p.ps1` checks for the binary and prints this exact command if it's
missing, so you can't forget the step.

## Start / stop

```powershell
.\start-p4p.ps1     # launches p4p on :1668, cache at C:\PerforceSandbox\proxy\cache
.\stop-p4p.ps1      # kills the process; the on-disk cache is preserved + reused

# Point any client at the proxy instead of the server:
p4 -p localhost:1668 sync //game/main/...
```

`p4 -p localhost:1668 info` shows both the proxy address and, below it, the
upstream server it forwards to — the proxy is transparent to the client.

## Cache-hit demo

`demo-proxy.ps1` proves the cache empirically, with a signal that doesn't depend
on log-format guesswork — the **cache directory itself**:

1. (re)start p4p with an **empty** cache.
2. Client **A** force-syncs `//game/main/...` through the proxy → the cache
   **fills** (0 → N files).
3. Client **B** (a different workspace) force-syncs the **same revisions**
   through the proxy → the cache **does not grow** (delta 0): every file was
   served from cache, zero upstream fetches.

```powershell
.\demo-proxy.ps1                 # mechanism demo against the existing depot
.\demo-proxy.ps1 -SeedMB 50      # WAN-realistic: seed 50 MB of binary fixtures first
```

The assertion is `cacheFilesAfterB == cacheFilesAfterA`. The script is
self-contained — it creates throwaway stream clients and cleans them (and any
seeded fixtures) up afterward.

**Honest framing for an interview (single-box reality):** here the "WAN" is
localhost, so the *time* saved is tiny — the demo proves the cache *mechanism*
(content served locally, master not re-hit), not a dramatic latency win. The
`-SeedMB` knob (the Track 1 "workload tier") makes the **bytes** real; the
**latency** win only shows up with real network distance between proxy and
master. Same point the roadmap makes about overhead-bound parallelism on one
box: demonstrate the mechanism honestly, name the hardware limit.

## Status

- [x] Harness complete — `start-p4p.ps1`, `stop-p4p.ps1`, `demo-proxy.ps1`, this doc.
- [ ] **Download `p4p.exe`** (human-gated; command above) — the one step between
      here and a live proxy.
- [ ] Run `demo-proxy.ps1` to capture live cache-fill/hit numbers.
