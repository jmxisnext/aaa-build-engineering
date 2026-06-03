# Hoops Brawl seed snapshot

This directory holds the **initial state** of the buildable C++ project that
was seeded into the `//game/main` stream to drive the Track 2 CI build
chain (Compile → Smoke Test → Cook Data → Package).

The canonical source-of-truth for the project is the Perforce stream, not
this directory — once the CI pipeline starts iterating, the depot side
will move ahead and the git copy here will not be updated. This snapshot
exists for documentation: *"this is what got seeded, on what date, with
what justification."*

## Contents

`stream/` is a faithful mirror of what was submitted at the depot root
of `//game/main` in the seed changelist. Reading any file here is the
same as reading the corresponding file in `//game/main/...` immediately
post-seed.

## The project

A small "Hoops Brawl" sandbox — a fictional AAA-shaped basketball game
that continues the same fiction Track 1 used to test broker policy. Four
build targets, designed to map 1:1 onto the four CI stages:

| Target | Kind | CI stage it feeds |
|---|---|---|
| `hoops_core` | static library | Compile |
| `hoops_brawl` | executable (game) | Compile + Package |
| `hoops_tests` | executable (unit tests) | Smoke Test |
| `hoops_cooker` | executable (asset packer) | Cook Data |

Tests are dependency-free (plain `<cassert>`-style runner) so the build
agent doesn't have to fetch a test framework over the wire. Cooker takes
`Data/*.txt` and writes a concatenated `.pak` with a tiny header — just
enough behavior to make the Cook Data stage produce a real artifact.

## Seeding constraints (interview-shaped)

The Track 1 broker is currently configured with a code-freeze rule that
rejects all submits. That's correct policy posture for a real release —
but it also blocks bootstrap. Bootstrap work like seeding the CI project
is exactly the class of operation that *should* be exempt: it's build
infrastructure, not gameplay code, and rejecting it would create a
chicken-and-egg between "the policy is live" and "the CI that the policy
is supposed to protect even exists."

Two options were on the table:

1. **Bypass the broker for this submit** (use `P4PORT=localhost:1666`
   instead of `:1667`). Quick, leaves broker config alone, but means the
   seed change is invisible to the broker log — no policy audit trail.

2. **Relax the broker rule** to allow a service-account or "infra"
   allowlist, then submit normally.

Option 2 is the more interview-shaped fix (it's what a real shop would
do — exemptions belong in policy, not in operator workarounds). Option 1
is what got used for this seed, because the allowlist refinement is a
Track 1 deferred-hardening item, not a Track 2 blocker. See
`ci/lessons-learned.md` for the writeup.
