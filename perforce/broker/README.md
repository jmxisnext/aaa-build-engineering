# broker/ — P4 Broker policy layer

The broker is the **policy / safety layer** that sits between Perforce clients and the actual `p4d` server. It accepts client connections, looks at every command, and decides per policy whether to **pass**, **reject**, **redirect** to a different server, or **filter** through an external script.

Why this matters for a build engineer: most "operational rules" a studio wants to enforce can't be cleanly expressed in `p4d` itself. Server-side protections gate *who can do what*; triggers gate *content*. The broker gates *behavior* — time-windows, command-level bans, routing for distributed teams, etc. It's the layer that encodes operational policy.

## Sandbox config

| Where | What |
|---|---|
| Binary | `C:\PerforceSandbox\bin\p4broker.exe` (downloaded from r25.2/bin.ntx64) |
| Config | `perforce/broker/p4broker.conf` (this dir, versioned in git) |
| Working dir | `C:\PerforceSandbox\broker\` (logs go here) |
| Listen | `:1667` |
| Forwards to | `localhost:1666` (the sandbox `p4d`) |

## Policies in this sandbox

| Rule | Behavior | Why this policy is realistic |
|---|---|---|
| Reject `obliterate` | Returns a custom rejection message | Obliterate permanently deletes file history. Real shops route it through an approval workflow and use a broker to enforce "no direct obliterates." |
| Reject `submit` | Returns a "code freeze" message | Simulates a maintenance window. Production usage: blocks submits during nightly build runs, release weeks, integration test windows. Real shops parameterize this with a service-account allowlist (e.g., `user` regex `^buildbot$` is the inverse) so automation can still progress. |

## Running it

```powershell
.\start-broker.ps1   # starts p4broker on :1667, backgrounded
.\stop-broker.ps1

# Connect through the broker:
$env:P4PORT = "localhost:1667"
p4 info                  # works — broker passes through reads
# `p4 info` will display BOTH "Server address" (the real p4d) and
# "Broker address" (this broker) — broker presence is visible to clients
```

## Demo trace from the build-out

The four checks that proved the broker is doing what it should:

| Demo | Command | Through broker (:1667) | Direct to p4d (:1666) |
|---|---|---|---|
| 1 | `p4 info` | passes; output shows both `Server address` and `Broker address` lines | passes; only `Server address` |
| 2 | `p4 obliterate -y //game/main/README.md` | rejected, with sandbox-specific message | would proceed (destructive!) |
| 3 | `p4 edit` (any file) | passes — only `submit` is gated | passes |
| 3 | `p4 submit -d "..."` | rejected with code-freeze message | succeeded as change 23 |
| 4 | `Get-Content broker.log -Tail` | each command above is logged with `Config: [PASS|REJECT]` and `Action: [PASS|REJECT]` | n/a |

Demo 4 is the critical observation: **the broker log is policy telemetry.** Postmortem question "who tried to obliterate //engine/Code/SafetySystem.cpp last Tuesday?" — answer is in this log.

## Real-world hardening (deferred)

| Hardening | Why |
|---|---|
| `policies.d/` directory of include files | Each policy lives in its own file, owned by a different team. CI validates them on PR. |
| Service-user allowlist on `submit` rule | The current rule blocks *everyone*. Production should allow `buildbot` so automation continues during freeze. |
| `redirection = pedantic` for replica-bound commands | Default `selective` is the right choice for interactive users; pedantic is the right choice for write-amplifying scripts running against read-only replicas. |
| Filter-mode handlers (action = filter) | Lets the broker invoke a Python script for complex policies — e.g., "submit allowed during freeze IF jira ticket in description IS in approved state." |
| Multiple brokers, load-balanced | A single broker is a single point of failure. Production typically runs 3+ brokers behind a TCP load balancer. |
| Broker → replica routing | Use `altserver` blocks to redirect read-mostly commands (`sync`, `print`) to a read-only replica close to the user, keeping the master free for writes. The interview-relevant phrase here is "edge servers vs replicas vs proxies vs brokers" — know the difference. |

## p4: proxy vs broker vs replica vs edge — vocabulary cheat sheet

This is the kind of thing an interview will probe. One-liners:

- **Proxy (`p4p`):** read-through *file-content cache*. Helps `p4 sync` for remote offices. Doesn't store metadata. Transparent.
- **Broker (`p4broker`):** programmable man-in-the-middle for *commands*. Filters, rejects, redirects, logs. What this dir builds.
- **Replica (`p4d -r ... -p ...`):** secondary server that mirrors part of the master. Read-only by default. Used for warm standby, geographic distribution.
- **Edge server:** specialized replica that can serve writes for *workspace-local* operations (open, edit, revert) while forwarding submits to the commit server. The thing studios with hundreds of engineers across continents stand up.

A real AAA studio usually runs all four.
