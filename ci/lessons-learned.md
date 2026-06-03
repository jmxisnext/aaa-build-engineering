# CI lessons learned (Track 2)

Real-world gotchas hit during the TeamCity + P4-broker bring-up. Same pattern
as `perforce/lessons-learned.md` — each entry is the kind of thing an
interviewer might phrase as *"tell me about a time you got bitten by CI."*

Entries are appended as they happen, not batched at the end of the track.

## 1. `jetbrains/teamcity-server:2026.1` ships without `wget` — healthcheck failed silently

**What happened:** First compose-up with a healthcheck of
`wget -q -O /dev/null http://localhost:8111/` reported `unhealthy` after the
full start-period elapsed. The agent never started because of
`depends_on: { teamcity-server: { condition: service_healthy } }`.
`docker compose up -d` exited 1 with no obvious server-side error.
TeamCity itself was actually fine — its log clearly printed
*"Server is running at http://localhost:8111"*.

**Root cause:** Inside the container, `which wget` returns nothing.
`sh: 1: wget: not found` was the real error, swallowed by the healthcheck's
`|| exit 1`. The image (Ubuntu-based) ships `curl` but not `wget`.

**Fix:** Switch the healthcheck to
`curl -sS http://localhost:8111/ -o /dev/null`. `curl` is at `/usr/bin/curl`
in the image. Note the deliberate **absence of `-f`**: during TeamCity's
first-run flow the server replies HTTP 503 to every URL until a human walks
the wizard, and `-f` would treat that as failure. We want the healthcheck
to mean "the server is responding to HTTP at all" — anything beyond that
(setup-complete vs. running-normally) is downstream concern.

That decision matters because of `depends_on: service_healthy` below: a
strict `-f` healthcheck would refuse to flip green until *after* the wizard,
which would block the agent from starting until *after* the wizard — but
the wizard is fastest to walk when the agent is already up and registering,
so you can authorize it in the same browser session.

**Why a build engineer cares:** Two distinct lessons here.

1. **Don't trust vendor-image tool inventories** — versions drift. The
   TeamCity Docker Hub page documents healthcheck examples that no longer
   work in current images. CI infra config should be re-validated against
   the *actual* image you're pulling, not the README, when you bump a
   version. This is a class of issue that hides during `latest`-tag rollouts.

2. **`depends_on: service_healthy` is a sharp tool.** It will silently block
   downstream services forever if the healthcheck is wrong. Always run the
   healthcheck command interactively before trusting it
   (`docker exec <svc> sh -c "<healthcheck>"`). An unhealthy container also
   propagates non-zero exit to `docker compose up`, which trips CI scripts
   that assume "up means good."

**Interview-ready bullet:** *"Healthchecks fail closed by design — if your
healthcheck uses a tool that isn't in the image, the container reports
unhealthy forever and anything depending on it via `service_healthy` blocks.
Validate the probe command via `docker exec` before trusting it."*

## 2. "Test connection passed" doesn't mean the agent can sync — they're different code paths

**What happened:** Created a Perforce VCS root in TeamCity pointed at
`host.docker.internal:1667` (the Track 1 broker). Clicked **Test connection**
in the UI. Got a green "Connection successful." Broker log confirmed three
commands had arrived from inside the TeamCity server container
(`james@f9fccfdc92cc`, program string `[p4/2025.2/LINUX26X86_64/...]`):
`user-changes`, `user-changes ... @23,@23`, `user-describe -s 23`. All
`[PASS]` at the broker.

But the VCS root XML that TeamCity persisted included:

```xml
<param name="p4-exe" value="p4" />
```

That means at *sync* time the **agent** is expected to invoke an external
`p4` binary from its `$PATH`. The Linux agent image (`jetbrains/teamcity-agent:latest`)
does not ship one. So the moment a build configuration actually tries to
sync the workspace, the agent will fail with "p4: command not found" —
despite Test Connection being green.

**Root cause / mental model:** TeamCity's Perforce plugin has two execution
paths that look identical from the outside:

| Path | Where it runs | What it does | Uses `p4-exe`? |
|---|---|---|---|
| Server-side Java client | Inside the TeamCity server JVM | Polls VCS, Test Connection, change discovery, displays changelist details in the UI | No |
| Agent-side external `p4` | On the build agent | `p4 sync`, `p4 client -i`, the actual workspace mutation that builds depend on | **Yes** |

Test connection only exercises the first path. A green checkmark there is
a strong signal that *server*-side network + auth + view spec work, but
says nothing about whether the agent will be able to sync.

**Fix (deferred):** Build a custom agent image:

```dockerfile
FROM jetbrains/teamcity-agent:latest
RUN curl -fsSL https://filehost.perforce.com/perforce/r25.2/bin.linux26x86_64/p4 \
      -o /usr/local/bin/p4 \
 && chmod +x /usr/local/bin/p4 \
 && /usr/local/bin/p4 -V
```

Reference it from compose with a `build:` block instead of pulling the
upstream agent image directly. Pin the p4 binary version to the same family
as the server for the same reason Track 1 pinned the broker.

**Why a build engineer cares:** This is a class of CI bug that hides past
the first sanity check. The first build configuration runs, the sync step
fires, and only then do you discover the missing binary. In a real shop
with hundreds of agents, the smoke-build expectations are:

1. *Server* Test Connection — proves the server can see Perforce at all.
2. *Agent* smoke build that does just `p4 sync ... && exit 0` — proves
   each agent in the pool has the binary and can reach the Perforce server.

Skipping #2 means the first real build to land on a fresh agent breaks at
sync, which looks like a flaky build and gets attributed to "Perforce being
weird" instead of the real issue (missing tool).

**Interview-ready bullet:** *"TeamCity's Perforce plugin runs the
server-side Java client for VCS polling and connection testing, but the
agent shells out to an external `p4` binary for actual sync. The two are
different code paths — a green Test Connection guarantees the server can
talk to Perforce, but says nothing about whether the agent has a `p4`
binary on its PATH. Always smoke-test sync on a fresh agent before claiming
the pool is healthy."*

## 3. Bypassing the broker for the seed submit — policy vs. bootstrap

**What happened:** The Track 1 broker is configured with a code-freeze rule
that rejects all submits. That's intentional and correct for a release
posture. But when it came time to seed `//game/main` with a buildable C++
project so the Track 2 CI chain has something to compile, the freeze rule
also rejected the seed changelist — there is no in-broker exemption for
"this is infrastructure, not gameplay."

The seed went in via `P4PORT=localhost:1666` (direct to p4d) instead of
`:1667` (broker). Change `24` landed in the depot; `p4 -p :1667 describe -s 24`
returns it fine, but `broker.log` shows only the post-hoc verification reads
(`user-changes`, `user-describe`) — no record of the submit itself.

**Root cause:** The broker is a connection-time policy router, not a
journal. Writes that go around it leave no audit trail on the broker side.
A read-only broker can route reads back to the server it forwards to and
the server transparently includes any committed change — even one the
broker never saw — because the depot is the source of truth.

**Fix (deferred to Track 1 hardening):** Add a service-account allowlist
to the broker config — something like:

```
command: submit
{
  user = build-svc, infra-svc;
  action = pass;
}
command: submit
{
  action = reject;
  message = "Code freeze in effect.";
}
```

Then run bootstrap submits as `build-svc`. The exemption then lives in
*policy*, not in operator workarounds, and every submit (allowed or
rejected) shows up in `broker.log` for audit.

**Why a build engineer cares:** Two distinct lessons.

1. **Bypass is a power tool with a cost.** It works, it's fast, but it
   silences the audit signal you put the broker in front of the server to
   capture. If you bypass routinely, you've effectively removed the broker.
   Bypass should be a *known, logged-elsewhere* operator action — not the
   default escape valve.

2. **Policy needs to model bootstrap.** A code-freeze rule that doesn't
   recognize infrastructure-class commits creates exactly the chicken-and-egg
   we hit here: "the policy is live, therefore the CI it protects cannot
   exist yet." Real shops solve this with service-account allowlists,
   not by telling people to bypass. The fact that the right fix lives in
   broker config makes it durable across operators and shifts.

**Interview-ready bullet:** *"The broker is a connection-time router, not
a journal — anything that bypasses it (e.g. submitting directly to p4d
on the alternate port) succeeds at the depot level but vanishes from
broker logs. That's fine as a one-off bootstrap move, but it argues for
modeling 'infrastructure submit' as a first-class policy exemption rather
than relying on operators to remember when to bypass. Allowlists in
broker config keep the audit trail intact."*

## 4. TeamCity REST API: Accept header must match per-endpoint response type

**What happened:** Building the build-chain bootstrap script
(`ci/scripts/bootstrap-builds.ps1`), POSTs to `/app/rest/buildTypes`,
`/steps`, `/snapshot-dependencies`, and `/artifact-dependencies` all
worked fine with `Accept: application/json` + JSON request bodies.

Then the PUT to `/app/rest/buildTypes/{id}/settings/artifactRules`
returned **HTTP 406 Not Acceptable** with the body:

```json
{"errors":[{"additionalMessage":"javax.ws.rs.NotAcceptableException:
HTTP 406 Not Acceptable.","message":"Make sure you have supplied correct
'Accept' header."}]}
```

…even though Accept was clearly being sent.

**Root cause:** TeamCity's REST API does per-endpoint content negotiation,
not whole-API. `artifactRules` is a textual setting — the endpoint returns
the new value as `text/plain`. With `Accept: application/json` on the
request, the server (correctly) refused to lie about the response type and
returned 406. Every other endpoint we hit either returned JSON or didn't
mind, so the problem only surfaced on this one PUT.

**Fix:** Parameterize the Accept header in the REST helper so each call
can declare what response it expects. PUT artifactRules sends
`Accept: text/plain`; everything else stays on JSON.

```powershell
function Invoke-TC {
    param([string]$Method, [string]$Path, $Body,
          [string]$ContentType = "application/json",
          [string]$Accept      = "application/json")
    ...
}

function Set-ArtifactRules {
    Invoke-TC PUT ".../settings/artifactRules" `
        -Body $Rules -ContentType "text/plain" -Accept "text/plain"
}
```

**Why a build engineer cares:** Two adjacent lessons.

1. **REST API libraries that hand out a single client with a single set
   of default headers are an antipattern for APIs that mix content
   types.** Any non-trivial REST surface eventually has endpoints with
   different response shapes; the helper has to support per-call
   negotiation from day one or it'll bite on a random endpoint at the
   worst time.

2. **Half-state on partial failure is real.** The first failed run created
   three of four build types before erroring (the error was a
   *post*-create call). Re-running without a wipe path left those three
   in a half-configured state — Compile existed but had no artifact
   rules, etc. The fix was a `-Recreate` switch that deletes + recreates
   so the script always converges to a clean state. Convergence > clever
   patching.

**Interview-ready bullet:** *"TeamCity's REST API does per-endpoint
content negotiation — most endpoints serve JSON but a few (like
`/settings/artifactRules`) serve `text/plain` and reject a JSON Accept
with 406. Build the REST helper to accept per-call Accept from the start,
and pair it with a `-Recreate` mode for idempotency, because the first
partial-failure run will create half the resources and the second run
won't know how to patch them up."*


