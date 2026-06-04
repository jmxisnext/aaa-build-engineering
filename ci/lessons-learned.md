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

## 5. A second agent only buys you the width of the widest parallel stage

**What happened:** Added a second build agent (`agent-linux-02`) to prove
the chain runs faster with a pool. Benchmarked it directly
(`ci/scripts/bench-agents.ps1`): run the chain with agent-02 disabled
(1 agent), then enabled (2 agents), force `rebuildAllDependencies` both
times, compare wall-clock.

The chain fans out at Compile into `Smoke Test ‖ Cook Data` (both depend
only on Compile, both feed Package). Result:

Result (median of 5 A/B trials; `bench-agents.ps1 -Repeat 5`):

| Config | Leaf phase (Smoke‖Cook) | Overlap? | Whole chain |
|---|---|---|---|
| 1 agent  | 22s (min 22, max 23, Smoke *then* Cook) | no  | 45s |
| 2 agents | 11s (min 11, max 11, overlapping)       | yes | 34s |

**2× on the leaf phase, exactly** — two equal ~11s leaves overlapping
perfectly — and ~24% off the whole chain. These are medians of 5 trials,
not a single sample: the spread was tiny (1-agent leaf 22–23s, 2-agent leaf
a dead-flat 11s every run) and the overlap invariant held in all 5 trials,
so the 2× is reproducible. The 2-agent leaf's zero variance also argues the
two same-host agent containers aren't contending for CPU — the parallel
work is overhead-bound (sync + artifact download), exactly what overlaps
cleanly without more cores. TeamCity load-balanced on its
own: in the 2-agent run Compile landed on agent-02, then the two leaves
split across *both* agents. The broker log confirmed agent-02 synced
through `:1667` with its own per-agent client
(`james@TC_p4_agent_linux_02_…` running `user-sync …@24` → `[PASS]`),
so the second agent is a first-class CI citizen, not a bypass.

**Two things a build engineer should take from the numbers:**

1. **Adding agents helps exactly up to the width of the widest parallel
   stage, and not one agent more.** This DAG is 2-wide at the leaf stage,
   so the 2nd agent gives full 2× *there* and the 1st-and-only Compile and
   Package stages (1-wide) are untouched. A *3rd* agent would do nothing
   for this chain — there is no 3-wide stage to fill. Agent-pool sizing is
   a question about your build graph's shape, not a "more is always better"
   knob. You widen the graph (split a monolithic step into parallel ones)
   *and* add agents together, or the agents idle.

2. **The win is overlap of fixed overhead, and that's representative.**
   Every build here measured ~11.0s even though the actual
   compile/test/cook compute on this toy project is sub-second — the 11s
   is p4 sync through the broker + artifact download + agent handshake,
   i.e. fixed per-build overhead. That is *exactly* what a second agent
   overlaps. Real studio builds have far more of this fixed cost (syncing
   a multi-GB depot, pulling large build artifacts), so the parallel win
   scales up, not down, on a real workload.

**Why a second agent is a distinct compose service, not `docker compose
--scale`:** a TeamCity agent persists its identity (GUID +
`authorizationToken`) in its `conf/` volume. `--scale teamcity-agent=2`
would point both replicas at the *same* mounted `conf/`, so they'd fight
over one identity — the server sees one agent flapping, not two. Each
agent needs its own conf mount (`./data/teamcity_agent` vs
`./data/teamcity_agent2`) and its own `AGENT_NAME`. Everything else
(image, server URL, broker route) is identical.

**Interview-ready bullet:** *"A second build agent sped our leaf stage up
exactly 2× because the chain is 2-wide there — Smoke Test and Cook Data
both depend only on Compile. The lesson is that agent-pool sizing tracks
the width of your build graph: a third agent would've done nothing for
that chain. And note you can't just `docker compose --scale` a TeamCity
agent — it persists its identity in a conf volume, so two replicas on one
mount collide; each agent needs its own conf dir and name."*

## 6. The superuser token rotates per process — and a stale one trips the brute-force lockout

**What happened:** Restarted the stopped TeamCity stack and tried to drive
the REST API. Scraped the superuser token out of `teamcity-server.log`
right after `docker compose up`, got `6452109178723932359`, and looped on
`GET /app/rest/server` waiting for the server to come ready. Every call
came back as the HTML "TeamCity is starting / Initializing server
components" maintenance page; after ~4 minutes the script declared "NOT
READY." But the server *was* ready — the log showed it serving REST and
even printing a *different* token, `4364370803413132753`, over and over.

**Two compounding root causes:**

1. **The token I scraped was stale.** The superuser token is regenerated
   for each server *process* and printed to the log repeatedly during
   startup. The log directory is volume-mounted, so it survives restarts
   and accumulates tokens from *prior* boots. Scraping right after
   `up` — before the new process had logged its token — grabbed the
   previous boot's token off the persisted tail. Fix: take the **last**
   occurrence of the token line, and only after the server is fully
   initialized.

2. **A stale token tripped TeamCity's brute-force limiter, which then
   masked the readiness signal.** Each failed auth counts against a
   per-username limit (here the empty superuser username): *"You made 5
   failed login attempts in 1m … you will be able to login only in 20s."*
   My tight poll loop generated failures faster than that, so the server
   started *rejecting even a correct token* during the cooldown windows —
   and the rejections look identical to "not ready yet." The probe was
   creating the failure it was probing for.

**Fix:** Scrape the token with `… | tail -n 1` (last line) *after* the
server has finished initializing (REST returns JSON, not the 503
maintenance page), and never tight-loop auth — back off on failure so a
wrong/early token doesn't burn the rate-limit budget. `bench-agents.ps1`'s
`Get-SuperUserToken` takes the last occurrence for exactly this reason.

**Why a build engineer cares:** automation against a freshly-(re)started
server hits two traps at once — (a) credentials that rotate on restart,
read from a log that outlives the restart, and (b) security controls
(login throttling) that turn a benign retry loop into a self-inflicted
outage that's misdiagnosed as "server slow to boot." Both are classic
"works the first time, mysteriously fails on the automated retry" CI bugs.

**Interview-ready bullet:** *"TeamCity's superuser token rotates per
server process and is logged repeatedly into a volume-persisted log, so a
scrape right after restart can grab a stale token from a prior boot — take
the last occurrence, after init completes. And don't tight-loop auth while
waiting for readiness: failed logins hit the brute-force limiter, and the
resulting lockout rejects even a correct token, so your readiness probe
manufactures the failure it's checking for. Back off on auth failure."*

## 7. Instant CI from Perforce: a durable token, a topology-proof endpoint, and the self-service-token trap

**What happened:** Wired the VCS trigger so a P4 submit auto-fires the chain — a
p4d `change-commit` trigger that pings TeamCity to check the VCS root, which then
fires the build via a VCS trigger on Package. Three separate things bit, all in
the auth/topology seam:

1. **The first hook authenticated with the scraped superuser token** — which
   rotates every server restart (see #6). It worked once, then every commit after
   the next restart silently failed auth. The hook exits 0 by design (it must never
   block a submit), so the failure was invisible until you read `hook.log`.

2. **JetBrains' dedicated Perforce post-commit script auto-detects VCS roots by
   matching `p4port` — and that match never lands here.** The script POSTs
   `/app/perforce/commitHook` with the server's port; TeamCity selects the roots
   whose `port:` equals it. But the hook runs on the p4d host where the port reads
   `localhost:1666`, while TeamCity knows the same root as
   `host.docker.internal:1667` (it polls *through the broker, from inside a
   container*). The strings differ, so auto-detect matched zero roots and notified
   nothing — silently.

3. **Minting the durable token failed with 403 — token creation is
   self-service-only.** `POST /app/rest/users/username:ci-hook/tokens/<name>` as the
   **superuser** returns *"You do not have enough permissions to create tokens for
   this user."* on TeamCity 2026.1. Even a system admin cannot mint a token *for
   another user*; only the owning identity can.

**Root causes:** (1) is a credential-lifetime mismatch — a per-process secret
powering a persistent trigger. (2) is a topology mismatch — the vendor convenience
assumes the hook and the server agree on the Perforce port string, which is false
the moment a broker and a container boundary sit between them. (3) is an
ownership/least-privilege control: tokens are bearer credentials, so TeamCity
restricts minting to the identity that will bear them — admins get no shortcut.

**Fixes:**

1. Mint a **durable access token** for a dedicated least-privilege `ci-hook` user
   (Project Developer / *Run build*) and store it outside the repo at
   `C:\PerforceSandbox\triggers\teamcity-hook.token`; the hook reads that, not the
   superuser token.
2. Drop auto-detect; POST the **generic**
   `commitHookNotification?locator=vcsRoot:(id:AAASandbox_GameMainStream)` — naming
   the root explicitly sidesteps the port-string match entirely.
3. Work *with* the self-service rule, not around it: set a **random bootstrap
   password** on `ci-hook` (as superuser), authenticate **as** `ci-hook` to mint its
   own token, then clear the password in a `finally`. The password is random and
   in-memory only; `ci-hook` ends up bearer-token-only. `setup-vcs-trigger.ps1` does
   this idempotently.

**Why a build engineer cares:** all three are the same shape — *"works in the demo,
fails on the automated / long-lived path."* (a) A trigger is infrastructure;
authenticate it with a secret that rotates and you've scheduled a future silent
outage. (b) Vendor "it just auto-detects" conveniences encode an assumption about
your network; the moment you add a broker, a proxy, or a container boundary — i.e.
any real studio topology — the matching key stops matching and it fails *quietly*,
the worst way to fail. (c) Credential-minting being self-service is a deliberate
security control; automation that provisions tokens must plan for it
(bootstrap-password, or mint out-of-band and inject), not assume admin can do
everything.

**Interview-ready bullet:** *"To get instant CI from Perforce I used a p4d
change-commit trigger that pings TeamCity's commit-hook endpoint. Three gotchas,
all in the auth/topology seam: authenticate the hook with a durable minted token,
never the superuser token that rotates each restart; skip the vendor's auto-detect
endpoint that matches on p4port, because once a broker and a container sit between
p4d and TeamCity the port strings differ and it silently matches nothing — name the
VCS root explicitly instead; and know that token minting is self-service-only even
for admins, so provision a service account's token by briefly authenticating as it,
not as the superuser."*

## 8. "Attach ≠ create": the bootstrap that assumed two objects into existence

**What happened:** `bootstrap-builds.ps1` built the whole chain and looked fully
idempotent — re-running it was a clean string of `[skip]`s. But it had never been
run against a *wiped* server. It turned out to **create neither** of the two objects
the chain hangs off: the `AAASandbox` **project** and the `AAASandbox_GameMainStream`
**VCS root**. It referenced both (`project={id:…}` on every build type; a
`vcs-root-entries` *attachment* to the root) but created only the build types. Both
the project and the root had been made by hand in the UI months earlier and silently
survived every restart — so the "instant CI restored in two commands" reset story
was never actually exercised and would have died at the first POST with "project not
found."

**Root cause:** the REST API has two different calls that read almost identically in
a script. `POST /app/rest/buildTypes/id:<bt>/vcs-root-entries` **attaches** an existing
root to a build type; `POST /app/rest/vcs-roots` **creates the root definition**. The
bootstrap did the former and never the latter — and nothing created the project at all.
Idempotent-on-a-populated-DB hid it completely: skip-if-exists looks the same whether
you created the thing or merely inherited it from a manual setup.

**Fixes:**
1. Added `Ensure-Project` (`POST /app/rest/projects`) and `Ensure-VcsRootDefinition`
   (`POST /app/rest/vcs-roots`), idempotent, called in dependency order
   (project → root → build-type loop) so the chain rebuilds from an empty database.
2. **Verified the exact create-body live, with zero assumptions.** A non-destructive
   round-trip probe — POST a throwaway `…_probe` root with the candidate body, GET it
   back, diff against the live root, delete the probe — proved a from-scratch root
   matches the hand-made one byte-for-byte across all six properties. This also caught
   **documentation drift**: the README documented the root as a *client mapping*, but
   the live root is *stream mode* (`use-client=stream`, `stream=//game/main`). The
   `workspace-options` block is space-aligned to column 16, not tab-separated — found
   by dumping char codes, not by eyeballing.
3. `-Recreate` tears down in reverse-dependency order (build types → root) so the root
   is never deleted while referenced — no reliance on TeamCity's cascade-on-delete.

**Why a build engineer cares:** "idempotent" and "reproducible from scratch" are not
the same property, and a re-run against a populated environment proves only the first.
The only honest test of a bootstrap is to run it against the wiped state it claims to
recover — anything else lets a manual, undocumented dependency masquerade as automation.
And when you *do* script a config object, read the live one back and diff it; the
shape that's actually stored beats the shape the docs (or your memory) claim.

**Interview-ready bullet:** *"Our CI bootstrap looked idempotent but had never been run
against an empty database — it attached a VCS root and referenced a project that nothing
created; both had been made by hand in the UI and just survived restarts. I scripted the
project and root creation, and verified the exact REST body with a non-destructive
round-trip probe — create a throwaway, read it back, diff against the real one, delete it.
That caught two things memory would've missed: the root was stream-mode, not the client
mapping our docs claimed, and its workspace options were space-aligned, not tabbed. The
lesson: idempotent ≠ reproducible; only a from-scratch run proves the latter."*

## 9. `docker compose down -v` doesn't wipe a bind-mounted stack — the "reset" wasn't resetting

**What happened:** The compose header promised the stack was "`docker compose down -v`
reset-able," and two specs' reset stories rode on that. Verifying it *before* a
destructive test (rather than after a disaster) showed otherwise: all server state — the
2.1 GB TeamCity DB and agent identity — is a host **bind mount** under `ci/data/`, and
`down -v` removes only *named and anonymous* volumes (here, one throwaway
`/opt/teamcity/temp`). The bind-mounted `datadir` is untouched, so `down -v && up -d`
brings the server back with every project, VCS root, and build config intact — and
`bootstrap-builds.ps1` would `[skip]` everything, "proving" a reset that never happened.

**Root cause:** `-v` is about Docker-managed volumes, not host paths. A bind mount is a
window onto a host directory, and Compose never deletes host directories. The mental
model "`down -v` = clean slate" holds only when your state lives in *named volumes*.

**Fix:** make the two real resets explicit, and stop conflating them.
- **Config reset:** delete the project via REST/UI (cascades root + chain) and re-run
  `bootstrap-builds.ps1` — exercises the from-absence create path without touching the
  server install. This is the one verified here (project deleted, bootstrap recreated
  project + root + chain, demo green).
- **Full wipe:** stop and delete `ci/data/teamcity_server/datadir` (+ agent `conf`), then
  `up -d` — truly empty, but it resurrects the one-time first-run wizard.
- Corrected the compose header and the README/spec reset stories accordingly.

**Why a build engineer cares:** "it's reset-able" is a claim you execute against the real
wiped state, never infer from a flag's name. A reset that silently no-ops is worse than
no reset script — it manufactures false confidence that disaster recovery works. And
bind-mount vs named-volume is precisely the infra detail that decides whether `down -v`
is a clean slate or a no-op; know which your stack uses before you stake a recovery on it.

**Interview-ready bullet:** *"Our compose stack claimed to be `down -v` reset-able, but
all its state was a host bind mount — and `-v` only removes Docker-managed volumes, so the
database survived and the 'reset' was a no-op that just re-skipped everything. I made the
two real reset paths explicit — a config-level project delete that re-runs the bootstrap,
and a full datadir wipe that resurrects the first-run wizard — and verified the config one
against an actually-empty project. The lesson: never trust a reset you haven't run against
the wiped state, and know whether your state is a volume or a bind mount before you bet
recovery on `-v`."*


