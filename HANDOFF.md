# Handoff - aaa-build-engineering

## Resume from
Branch: main   |   Last commit: d7975e2 - docs(capstone): Slice 3 - Zen/DDC writeup (Capstone complete)

## What was just built
- **Capstone Slice 3 (`d7975e2`)** - Zen/DDC + production-ephemeral writeup
  (`capstone/ddc-and-ephemeral-ci.md`): cooker-as-mini-DDC (cook_key/output_hash/CAS + incremental
  skip), the cross-machine shared-DDC story (unreal lessons #4-5), and the K8s cloud-profile as the
  production disposable-agent path. Zen facts verified (default Local DDC since UE 5.4).
- **Capstone Slice 2 (`fcaa12f`)** - ephemeral disposable-agent demo
  (`capstone/demo-disposable-agent.ps1`): a `docker run --rm` container reusing a standing agent's
  licensed identity auto-authorizes, runs a build, and is disposed; try/finally guarantees restore.
  Verified green live (Cook Assets #9 ran on the disposable). Surfaced the 3-agent license cap.
- **Capstone Slice 1 (`8697637`)** - two-part demo runbook (`capstone/demo-capstone.ps1` + README):
  policy-gated submit through broker :1667 -> hoops chain -> CL-stamped artifact + provenance -> real
  content-addressed cook -> dashboard. Verified green; hardened from a 14-finding adversarial review;
  fixed a silent REST-fields detection bug.

## Live edge
The **Capstone (Phase 2 Step 4) is COMPLETE** - all three slices shipped + verified, every spec
done-criterion met plus the disposable-agent stretch. The stack is **down** (TeamCity removed; p4d +
broker stopped). The capstone spine (Tracks 1,2,5 + observability) is fully exercised on disposable
infra; accel (Track 3) and unreal/Horde (Track 4) are surfaced on the dashboard, not re-run.

## Next
Decide the **post-Capstone fork** the spec set up: **Verse/UE6 exploration vs the PySide6 cooker GUI
tool** (Track 5's deferred artist tool - PySide6/Qt over WPF). Then scope its first runnable slice.
To re-demo the Capstone: start p4d + broker (`perforce/scripts/start-p4d.ps1`,
`perforce/broker/start-broker.ps1`) + `docker compose -f ci/docker-compose.yml up -d`, wait for the
agents to connect, then `pwsh -File capstone/demo-capstone.ps1` (and `demo-disposable-agent.ps1`).
