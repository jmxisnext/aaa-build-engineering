# CI Cook Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the real content-addressed cooker (`pipeline/cook.py`) into CI as a standalone, warm-cacheable TeamCity "Cook Assets" stage, gate the cooker tests, and surface cook metrics on the dashboard.

**Architecture:** A new TeamCity build config `AAASandbox_CookAssets` runs `make-samples.py` then `cook.py --pack`, persisting the `pipeline/cooked/` CAS across builds via a self artifact-dependency (Approach A). It is standalone (no dependency on the hoops C++ chain). The 42 cooker unit tests gate every push via GitHub Actions, and cook stats feed a new dashboard `pipeline` panel through the existing local-metrics → snapshot → render pattern.

**Tech Stack:** Python 3 + Pillow (cooker), PowerShell 7 (TeamCity REST bootstrap + dashboard), TeamCity 2026.1, GitHub Actions, bash (agent steps + `run-tests.sh`).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-22-ci-cook-wiring-design.md` (commit `c1d03c8`). Every task traces to it.
- **Test convention:** every suite is "a runnable thing that exits nonzero on failure." Python = stdlib `unittest`; PowerShell = the repo's `dashboard/tests/_assert.ps1` harness (`Assert-Equal`/`Assert-True`/`Assert-Match`/`Assert-NotMatch`/`Assert-Summary`) — **NOT Pester**.
- **Determinism:** cooked outputs, the `.pak`, the `.toc`, and the dashboard HTML must be byte-identical for identical inputs. Dashboard date/number formatting MUST go through `Format-When` / `Format-Num` (locale-invariant) — never `.ToString(fmt)` or `-f` directly.
- **Warm-cache invariant (spec §6, decided):** keep `.cookindex.json` a dotfile; publish the CAS with the **directory-form** artifact rule `pipeline/cooked => cooked.zip` (archives dotfiles) and add a **`cached>0` guard** on warm builds so a silently-cold cache fails loudly. Do NOT de-dot the index.
- **De-identification:** scripts use the generic P4 user `devuser` (already in `bootstrap-builds.ps1`) — never a real username.
- **No new frameworks.** Follow existing file patterns. Each suite that a task adds must be wired into both `.github/workflows/tests.yml` and `run-tests.sh`.
- **Offline scope:** everything here is offline-authorable + locally verifiable. Creating the config against a live TeamCity server and validating the artifact round-trip is GATED (spec §8) — called out per-task, not executed here.

---

### Task 1: Harden `cook.py --stats-json` to create its parent dir

The CI step writes `--stats-json pipeline/.metrics/cook-N.json`; that dir won't exist on a fresh agent. Verified offline: it currently raises `FileNotFoundError` *after* a successful cook.

**Files:**
- Modify: `pipeline/cook.py` (the `if args.stats_json:` block, ~line 66)
- Test: `pipeline/tests/test_cook_cli.py` (create)

**Interfaces:**
- Consumes: `pipeline/cook.py` `main(argv)` — already returns `0` on success and accepts `--src/--out/--stats-json`.
- Produces: nothing new for later tasks (behavioral hardening only).

- [ ] **Step 1: Write the failing test**

Create `pipeline/tests/test_cook_cli.py`:

```python
"""cook.py CLI: --stats-json must create its parent dir (CI writes into a fresh pipeline/.metrics)."""
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))  # pipeline/ on path
import cook  # noqa: E402
from cooker import pipeline  # noqa: E402  (to build a tiny source tree)
from PIL import Image  # noqa: E402


def _tiny_src(d):
    os.makedirs(os.path.join(d, "textures"))
    os.makedirs(os.path.join(d, "audio"))
    os.makedirs(os.path.join(d, "characters"))
    Image.new("RGBA", (8, 8), (1, 2, 3, 255)).save(os.path.join(d, "textures", "t.png"))
    with open(os.path.join(d, "characters", "c.json"), "w") as f:
        json.dump({"name": "c", "textures": ["textures/t.png"], "audio": []}, f)


class TestStatsJsonParentDir(unittest.TestCase):
    def test_stats_json_into_missing_dir_succeeds(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as out:
            _tiny_src(src)
            stats = os.path.join(out, "does", "not", "exist", "cook.json")
            rc = cook.main(["--src", src, "--out", os.path.join(out, "cooked"),
                            "--stats-json", stats])
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(stats), "stats-json parent dir should be created")
            with open(stats) as f:
                self.assertIn("total_bytes", json.load(f))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m unittest pipeline.tests.test_cook_cli -v` (from repo root)
Expected: FAIL with `FileNotFoundError: ... does/not/exist/cook.json`

- [ ] **Step 3: Write minimal implementation**

In `pipeline/cook.py`, change the stats-json block (currently):

```python
    if args.stats_json:
        with open(args.stats_json, "w", encoding="utf-8") as f:
```

to:

```python
    if args.stats_json:
        stats_dir = os.path.dirname(args.stats_json)
        if stats_dir:
            os.makedirs(stats_dir, exist_ok=True)
        with open(args.stats_json, "w", encoding="utf-8") as f:
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m unittest pipeline.tests.test_cook_cli -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pipeline/cook.py pipeline/tests/test_cook_cli.py
git commit -m "fix(pipeline): cook.py --stats-json creates its parent dir"
```

---

### Task 2: Lock missing-blob→recook with a regression test

Spec §6: `cache.cook_or_reuse` already treats a missing blob as a miss (verified — line 47 checks the blob exists on disk). This is a **characterization test** that locks that behavior; it should pass on the first run (no production change).

**Files:**
- Test: `pipeline/tests/test_cache.py` (modify — add one method to `TestCache`)

**Interfaces:**
- Consumes: `cooker.cache.Cache(dir)`, `.cook_or_reuse(key, ext, fn)` → `CacheResult(output_hash, size, hit, ext)`, `.blob_path(hash, ext)`, `.would_hit(key)`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Write the test (locks existing behavior)**

Add to `pipeline/tests/test_cache.py` inside `class TestCache`, after `test_index_persists_across_instances`:

```python
    def test_missing_blob_is_a_miss_and_recooks(self):
        # The cache's warm-hit requires BOTH the index entry AND the backing blob on
        # disk. If the blob is gone (truncated/lost artifact) the key must MISS and
        # recook, never crash. This is the safety the warm-cache round-trip relies on.
        with tempfile.TemporaryDirectory() as d:
            c1 = cache.Cache(d)
            r1 = c1.cook_or_reuse("key1", "tex", Counter(b"data"))
            c1.save()
            os.remove(c1.blob_path(r1.output_hash, "tex"))   # blob vanishes; index remains
            c2 = cache.Cache(d)
            self.assertIsNone(c2.would_hit("key1"))           # read-only path: miss
            fn = Counter(b"data")
            r2 = c2.cook_or_reuse("key1", "tex", fn)
            self.assertFalse(r2.hit)                          # recooked, not crashed
            self.assertEqual(fn.calls, 1)
```

- [ ] **Step 2: Run test to verify it passes (characterization)**

Run: `python -m unittest pipeline.tests.test_cache -v`
Expected: PASS (all tests, including the new one). If it FAILS, the spec §6 assumption is wrong — STOP and report; do not "fix" cache.py without re-checking the spec.

- [ ] **Step 3: Commit**

```bash
git add pipeline/tests/test_cache.py
git commit -m "test(pipeline): lock missing-blob -> recook (warm-cache safety)"
```

---

### Task 3: Extract `$configs` into a dot-sourceable function (+ characterization test)

`bootstrap-builds.ps1` connects to TeamCity on load, so its `$configs` array can't be inspected offline. Extract it into a pure function in a new file, dot-sourced by the bootstrap script. Lock the existing 4 configs with a test BEFORE adding the 5th in Task 4.

**Files:**
- Create: `ci/scripts/build-configs.ps1`
- Create: `ci/tests/build-configs.Tests.ps1`
- Modify: `ci/scripts/bootstrap-builds.ps1` (replace the inline `$configs = @(...)` with a dot-source + call; keep `$versionStampScript` where it is)

**Interfaces:**
- Produces: `Get-SandboxBuildConfigs([string]$VersionStampScript)` → an array of config hashtables, each with keys `Id, Name, Steps (@{Name;Script}), SnapshotDeps (string[]), ArtifactDeps (@{UpstreamId;PathRules}), ArtifactRules (string)`. Task 4 adds an optional `WarmCacheArtifact (@{PathRules})` key to one entry.

- [ ] **Step 1: Write the failing test**

Create `ci/tests/build-configs.Tests.ps1`:

```powershell
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "..\..\dashboard\tests\_assert.ps1")   # shared assert harness
. (Join-Path $here "..\scripts\build-configs.ps1")          # defines Get-SandboxBuildConfigs

$configs = Get-SandboxBuildConfigs -VersionStampScript "echo stamp"
$byId = @{}; foreach ($c in $configs) { $byId[$c.Id] = $c }

Assert-True ($byId.ContainsKey('AAASandbox_Compile'))    'has Compile'
Assert-True ($byId.ContainsKey('AAASandbox_SmokeTest'))  'has Smoke Test'
Assert-True ($byId.ContainsKey('AAASandbox_CookData'))   'has Cook Data (toy cooker, unchanged)'
Assert-True ($byId.ContainsKey('AAASandbox_Package'))    'has Package'
Assert-Equal 'hoops_cooker Data Cooked.pak' `
    (($byId['AAASandbox_CookData'].Steps[0].Script) -replace '.*Cooker/','') `
    'Cook Data still runs the toy cooker'

Assert-Summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File ci/tests/build-configs.Tests.ps1`
Expected: FAIL — `build-configs.ps1` / `Get-SandboxBuildConfigs` not found.

- [ ] **Step 3: Create `ci/scripts/build-configs.ps1`**

Move the `$configs = @(...)` literal out of `bootstrap-builds.ps1` verbatim into this function (the `$versionStampScript` is passed in as a parameter so this file stays REST-free and side-effect-free):

```powershell
<#
.SYNOPSIS
  The declarative AAA Sandbox build-chain config (no REST, no side effects).
  Dot-sourced by bootstrap-builds.ps1 and unit-tested by ci/tests/build-configs.Tests.ps1.
#>
function Get-SandboxBuildConfigs {
    param([string]$VersionStampScript)
    @(
        @{
            Id            = "AAASandbox_Compile"
            Name          = "Compile"
            Steps         = @(
                @{ Name = "cmake configure"; Script = "cmake -B build -S . -DCMAKE_BUILD_TYPE=Release" }
                @{ Name = "cmake build";     Script = "cmake --build build --parallel" }
            )
            SnapshotDeps  = @()
            ArtifactDeps  = @()
            ArtifactRules = "+:build => build.zip"
        }
        @{
            Id            = "AAASandbox_SmokeTest"
            Name          = "Smoke Test"
            Steps         = @(
                @{ Name = "ctest"; Script = "ctest --test-dir build --output-on-failure" }
            )
            SnapshotDeps  = @("AAASandbox_Compile")
            ArtifactDeps  = @(
                @{ UpstreamId = "AAASandbox_Compile"; PathRules = "build.zip!** => build" }
            )
            ArtifactRules = ""
        }
        @{
            Id            = "AAASandbox_CookData"
            Name          = "Cook Data"
            Steps         = @(
                @{ Name = "cook"; Script = "build/Tools/Cooker/hoops_cooker Data Cooked.pak" }
            )
            SnapshotDeps  = @("AAASandbox_Compile")
            ArtifactDeps  = @(
                @{ UpstreamId = "AAASandbox_Compile"; PathRules = "build.zip!** => build" }
            )
            ArtifactRules = "+:Cooked.pak"
        }
        @{
            Id            = "AAASandbox_Package"
            Name          = "Package"
            Steps         = @(
                @{ Name = "stage";         Script = "cmake --install build --prefix dist" }
                @{ Name = "bundle pak";    Script = "cp Cooked.pak dist/Cooked.pak" }
                @{ Name = "version stamp"; Script = $VersionStampScript }
                @{ Name = "tarball";       Script = "rm -f hoops-brawl-cl*.tar.gz; tar czf hoops-brawl-cl%build.vcs.number%.tar.gz dist" }
            )
            SnapshotDeps  = @("AAASandbox_SmokeTest", "AAASandbox_CookData")
            ArtifactDeps  = @(
                @{ UpstreamId = "AAASandbox_Compile";  PathRules = "build.zip!** => build" }
                @{ UpstreamId = "AAASandbox_CookData"; PathRules = "Cooked.pak" }
            )
            ArtifactRules = "+:hoops-brawl-cl*.tar.gz"
        }
    )
}
```

- [ ] **Step 4: Rewire `bootstrap-builds.ps1` to use the function**

In `bootstrap-builds.ps1`, immediately after the `. (Join-Path $PSScriptRoot '_ci-common.ps1')` line (~line 45), add:

```powershell
. (Join-Path $PSScriptRoot 'build-configs.ps1')
```

Then DELETE the entire inline `$configs = @( ... )` literal (the block from `$configs = @(` through its closing `)`, ~lines 227-283) and replace it with:

```powershell
$configs = Get-SandboxBuildConfigs -VersionStampScript $versionStampScript
```

Leave the `$versionStampScript = @'...'@` here-string and everything else unchanged.

- [ ] **Step 5: Run the config test + verify the bootstrap script still parses**

Run: `pwsh -NoProfile -File ci/tests/build-configs.Tests.ps1`
Expected: PASS (all assertions).

Run: `pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ci/scripts/bootstrap-builds.ps1), [ref]$null, [ref]$null); 'parses ok'"`
Expected: prints `parses ok` (no parse errors after the edit).

- [ ] **Step 6: Commit**

```bash
git add ci/scripts/build-configs.ps1 ci/scripts/bootstrap-builds.ps1 ci/tests/build-configs.Tests.ps1
git commit -m "refactor(ci): extract build-chain configs into a testable function"
```

---

### Task 4: Add the `AAASandbox_CookAssets` config + self artifact-dep warm cache

The core wiring: a standalone config that cooks the real assets, with a self artifact-dependency (lastSuccessful) for the warm cache and a `cached>0` guard.

**Files:**
- Modify: `ci/scripts/build-configs.ps1` (append the 5th config)
- Modify: `ci/scripts/bootstrap-builds.ps1` (add `Add-SelfArtifactDep`; handle `WarmCacheArtifact` in the apply loop)
- Modify: `ci/tests/build-configs.Tests.ps1` (assert the new config's shape)

**Interfaces:**
- Consumes: `Get-SandboxBuildConfigs` (Task 3); `Invoke-TC` (from `_ci-common.ps1`).
- Produces: a config entry with `Id='AAASandbox_CookAssets'`, one step, `SnapshotDeps=@()`, `ArtifactDeps=@()`, `WarmCacheArtifact=@{PathRules='cooked.zip!** => pipeline/cooked'}`, and the directory-form `ArtifactRules`.

- [ ] **Step 1: Write the failing test (extend the config test)**

Append to `ci/tests/build-configs.Tests.ps1` BEFORE the final `Assert-Summary`:

```powershell
# --- Cook Assets (real cooker, warm-cacheable) ---
$ca = $byId['AAASandbox_CookAssets']
Assert-True  ($null -ne $ca)                         'has Cook Assets'
Assert-Equal 'Cook Assets' $ca.Name                  'Cook Assets display name'
Assert-Equal 0 @($ca.SnapshotDeps).Count             'Cook Assets is standalone (no snapshot deps on the C++ chain)'
Assert-Match 'make-samples\.py'  $ca.Steps[0].Script 'step regenerates synthetic assets'
Assert-Match 'cook\.py --pack'   $ca.Steps[0].Script 'step runs the real cooker with --pack'
Assert-Match 'cached'            $ca.Steps[0].Script 'step carries the warm-cache guard'
Assert-Match 'pipeline/cooked => cooked\.zip' $ca.ArtifactRules 'publishes the CAS dir-form (dotfiles included)'
Assert-Match 'Cooked-assets\.pak'             $ca.ArtifactRules 'publishes the real .pak'
Assert-Equal 'cooked.zip!** => pipeline/cooked' $ca.WarmCacheArtifact.PathRules 'self artifact-dep restores the CAS'
```

Run: `pwsh -NoProfile -File ci/tests/build-configs.Tests.ps1`
Expected: FAIL — `AAASandbox_CookAssets` is null.

- [ ] **Step 2: Add the config**

In `ci/scripts/build-configs.ps1`, add this entry to the array returned by `Get-SandboxBuildConfigs`, after the `AAASandbox_Package` entry (still inside the `@( ... )`):

```powershell
        @{
            Id            = "AAASandbox_CookAssets"
            Name          = "Cook Assets"
            # Standalone: the real cooker is pure Python+Pillow (in the agent image),
            # so it needs no C++ Compile. The self artifact-dep (WarmCacheArtifact)
            # restores the prior build's CAS into pipeline/cooked before this runs.
            Steps         = @(
                @{ Name = "cook (warm-cacheable)"; Script = @'
set -e
# WARM=1 iff a prior CAS was restored by the artifact dependency (index present + non-empty).
WARM=0; [ -s pipeline/cooked/.cookindex.json ] && WARM=1
python3 pipeline/scripts/make-samples.py
python3 pipeline/cook.py --pack Cooked-assets.pak --stats-json pipeline/.metrics/cook-%build.number%.json
if [ "$WARM" = "1" ]; then
  CACHED=$(python3 -c "import json;d=json.load(open('pipeline/.metrics/cook-%build.number%.json'));print(d['textures_cached']+d['audio_cached']+d['characters_cached'])")
  echo "warm build: cached=$CACHED"
  [ "$CACHED" -gt 0 ] || { echo 'FAIL: warm build recooked everything - the cache index did not survive the artifact round-trip'; exit 1; }
else
  echo "cold build (no prior CAS restored) - warm-cache guard skipped"
fi
'@ }
            )
            SnapshotDeps  = @()
            ArtifactDeps  = @()
            # Self artifact-dependency: restore THIS config's last successful CAS.
            WarmCacheArtifact = @{ PathRules = "cooked.zip!** => pipeline/cooked" }
            # Directory-form publish so the .cookindex.json DOTFILE is archived (spec §6).
            ArtifactRules = "+:pipeline/cooked => cooked.zip`n+:Cooked-assets.pak`n+:pipeline/.metrics/cook-*.json => cook-stats"
        }
```

- [ ] **Step 3: Add the self artifact-dep helper + apply-loop handling**

In `ci/scripts/bootstrap-builds.ps1`, add this function after `Add-ArtifactDep` (~line 191):

```powershell
# Self artifact-dependency for the warm cache: restore THIS build config's own
# last-successful artifact (the CAS) before it runs. revisionName=lastSuccessful so
# it does NOT require a same-chain build; cleanDestinationDirectory=false so the
# restored CAS is overlaid, not wiped. On the first-ever build no successful build
# exists yet -> TeamCity resolves nothing and the cook runs cold (validated in the
# gated run; the cached>0 guard covers a misconfigured round-trip).
function Add-SelfArtifactDep {
    param([string]$BuildTypeId, [string]$PathRules)
    $body = @{
        type               = "artifact_dependency"
        "source-buildType" = @{ id = $BuildTypeId }   # self
        properties         = @{
            property = @(
                @{ name = "pathRules";                 value = $PathRules },
                @{ name = "revisionName";              value = "lastSuccessful" },
                @{ name = "revisionValue";             value = "latest.lastSuccessful" },
                @{ name = "cleanDestinationDirectory"; value = "false" }
            )
        }
    }
    Invoke-TC POST "/app/rest/buildTypes/id:$BuildTypeId/artifact-dependencies" -Body $body | Out-Null
}
```

Then in the apply loop, after the `foreach ($ad in $cfg.ArtifactDeps) { ... }` block (~line 333), add:

```powershell
    if ($cfg.WarmCacheArtifact) {
        Add-SelfArtifactDep -BuildTypeId $id -PathRules $cfg.WarmCacheArtifact.PathRules
    }
```

- [ ] **Step 4: Run the config test to verify it passes**

Run: `pwsh -NoProfile -File ci/tests/build-configs.Tests.ps1`
Expected: PASS (all assertions, incl. the new Cook Assets block).

Run: `pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ci/scripts/bootstrap-builds.ps1), [ref]$null, [ref]$null); 'parses ok'"`
Expected: `parses ok`.

- [ ] **Step 5: Commit**

```bash
git add ci/scripts/build-configs.ps1 ci/scripts/bootstrap-builds.ps1 ci/tests/build-configs.Tests.ps1
git commit -m "feat(ci): Cook Assets stage - real cooker + self artifact-dep warm cache"
```

> **GATED (spec §8, not in this task):** running `bootstrap-builds.ps1` against a live server, and confirming the `cooked.zip` round-trip (in-archive path layout may need the pull rule adjusted) so build #2 reports `cached>0`. The guard step fails the build loudly if the round-trip is misconfigured — that is the intended safety net.

---

### Task 5: Gate the cooker tests (GitHub Actions job + `run-tests.sh`)

The 42 cooker tests run nowhere in CI today. Add a job and a local-runner block.

**Files:**
- Modify: `.github/workflows/tests.yml` (add a `pipeline-cooker` job)
- Modify: `run-tests.sh` (add a Python cooker block)

**Interfaces:**
- Consumes: `pipeline/tests/*` (unittest), `pipeline/scripts/make-samples.py`, `pipeline/cook.py`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Add the GitHub Actions job**

In `.github/workflows/tests.yml`, add under `jobs:` (sibling of `perforce-triggers`):

```yaml
  pipeline-cooker:
    name: pipeline cooker (python)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install Pillow
        run: pip install pillow
      - name: Cooker unit tests
        run: python -m unittest discover -s pipeline/tests -t pipeline/tests -v
      - name: Cook smoke (make-samples -> cook --pack)
        run: |
          python pipeline/scripts/make-samples.py
          python pipeline/cook.py --pack /tmp/Cooked-assets.pak --stats-json /tmp/m/cook.json
          test -f /tmp/Cooked-assets.pak
```

- [ ] **Step 2: Verify the job's commands locally (the runner isn't reproducible offline, the commands are)**

Run (from repo root):
```bash
python -m unittest discover -s pipeline/tests -t pipeline/tests
python pipeline/scripts/make-samples.py && python pipeline/cook.py --pack /tmp/Cooked-assets.pak --stats-json /tmp/m/cook.json && test -f /tmp/Cooked-assets.pak && echo SMOKE-OK
```
Expected: unittest reports OK (all cooker tests incl. Tasks 1-2); then `SMOKE-OK`. Clean up: `rm -rf /tmp/Cooked-assets.pak /tmp/m pipeline/assets pipeline/cooked`.

- [ ] **Step 3: Add the `run-tests.sh` cooker block**

In `run-tests.sh`, after the perforce block (ends ~line 39, before the `# ---- 2. hoops_tests` header) insert:

```bash
# ---- 1b. Pipeline cooker (Python) ------------------------------------------
hr; echo "[pipeline] Python cooker tests"
if command -v python3 >/dev/null 2>&1; then
    if python3 -m unittest discover -s pipeline/tests -t pipeline/tests; then
        record PASS "pipeline cooker (python)"
    else
        record FAIL "pipeline cooker (python)"
    fi
else
    echo "  python3 not found — skipping"; record SKIP "pipeline cooker (python)"
fi
```

- [ ] **Step 4: Run the aggregate runner**

Run: `bash run-tests.sh`
Expected: summary includes `PASS pipeline cooker (python)` (other suites PASS or SKIP per local toolchains); overall exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/tests.yml run-tests.sh
git commit -m "ci: gate the pipeline cooker tests (GH Actions job + run-tests.sh)"
```

---

### Task 6: Dashboard `pipeline` feed (collect-metrics) + gitignore

Add a `pipeline` snapshot section fed from `pipeline/.metrics/*.json`, mirroring the `unreal` feed.

**Files:**
- Modify: `dashboard/scripts/collect-metrics.ps1` (add `ConvertFrom-PipelineMetrics`, `Get-PipelineFeed`; wire into `Invoke-Main`; add a `$PipelineMetricsDir` param)
- Modify: `dashboard/tests/collect-metrics.Tests.ps1` (add transform cases)
- Modify: `.gitignore` (add `pipeline/.metrics/`)

**Interfaces:**
- Consumes: `Merge-Feed` (existing). Cook stats JSON shape (from `cook.py --stats-json`): `{textures_cooked,textures_cached,audio_cooked,audio_cached,characters_cooked,characters_cached,total_bytes,elapsed_sec,toc_path}`.
- Produces: `ConvertFrom-PipelineMetrics([object[]]$Metrics)` → `[pscustomobject]@{ stale=$false; cooked=<int>; cached=<int>; totalBytes=<int>; elapsedSec=<double>; warm=<bool>; utc=<string> }` (latest record by `utc`), or `$null` if none. Snapshot gains a `pipeline` section.

- [ ] **Step 1: Write the failing test**

Add to `dashboard/tests/collect-metrics.Tests.ps1` before `Assert-Summary`:

```powershell
# ConvertFrom-PipelineMetrics: latest cook-stats record -> the dashboard 'pipeline' section
$pm = @(
  [pscustomobject]@{ textures_cooked=4; textures_cached=0; audio_cooked=2; audio_cached=0; characters_cooked=2; characters_cached=0; total_bytes=144428; elapsed_sec=0.05; utc='2026-06-22T10:00:00Z' }  # cold
  [pscustomobject]@{ textures_cooked=0; textures_cached=4; audio_cooked=0; audio_cached=2; characters_cooked=0; characters_cached=2; total_bytes=144428; elapsed_sec=0.006; utc='2026-06-22T10:05:00Z' } # warm (newer)
)
$pf = ConvertFrom-PipelineMetrics -Metrics $pm
Assert-Equal 0   $pf.cooked     'latest record wins: warm run cooked 0'
Assert-Equal 8   $pf.cached     'warm run cached all 8 (4+2+2)'
Assert-True  $pf.warm           'warm flag set when cooked==0 and cached>0'
Assert-Equal 144428 $pf.totalBytes 'carries total bytes'

$pfCold = ConvertFrom-PipelineMetrics -Metrics @($pm[0])
Assert-True  (-not $pfCold.warm) 'cold run (cached 0) is not warm'

Assert-True  ($null -eq (ConvertFrom-PipelineMetrics -Metrics @())) 'no metrics -> null section'
```

Run: `pwsh -NoProfile -File dashboard/tests/collect-metrics.Tests.ps1`
Expected: FAIL — `ConvertFrom-PipelineMetrics` not defined.

- [ ] **Step 2: Implement the transform + feed**

In `dashboard/scripts/collect-metrics.ps1`, add after `ConvertFrom-UnrealMetrics` / `Get-UnrealFeed` (~line 126):

```powershell
function ConvertFrom-PipelineMetrics {
    # Pure transform: parsed pipeline/.metrics cook-stats records -> the 'pipeline' section.
    # Latest record by utc. 'warm' = a run that recooked nothing but reused something.
    param([object[]]$Metrics)
    if (-not $Metrics) { return $null }
    $latest = $Metrics | Sort-Object { [datetime]$_.utc } | Select-Object -Last 1
    if (-not $latest) { return $null }
    $cooked = [int]$latest.textures_cooked + [int]$latest.audio_cooked + [int]$latest.characters_cooked
    $cached = [int]$latest.textures_cached + [int]$latest.audio_cached + [int]$latest.characters_cached
    [pscustomobject]@{
        stale      = $false
        cooked     = $cooked
        cached     = $cached
        totalBytes = [int]$latest.total_bytes
        elapsedSec = [double]$latest.elapsed_sec
        warm       = ($cooked -eq 0 -and $cached -gt 0)
        utc        = $latest.utc
    }
}

function Get-PipelineFeed {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $metrics = foreach ($f in Get-ChildItem $Dir -Filter *.json -ErrorAction SilentlyContinue) {
        try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { }
    }
    if (-not $metrics) { return $null }
    ConvertFrom-PipelineMetrics -Metrics @($metrics)
}
```

Add a param to the `param(...)` block (after `$UnrealMetricsDir`, ~line 16):

```powershell
    [string]$PipelineMetricsDir = (Join-Path $PSScriptRoot "..\..\pipeline\.metrics"),
```

In `Invoke-Main`'s `param(...)` add `$PipelineMetricsDir`; compute the feed (after the `$unreal = Get-UnrealFeed ...` line, ~line 167):

```powershell
    $pipeline = Get-PipelineFeed -Dir $PipelineMetricsDir   # local files, no infra
```

Add it to the `$snap` ordered hashtable (after the `unreal = ...` line):

```powershell
        pipeline = Merge-Feed -New $pipeline -Prior $prior.pipeline
```

And pass it at the bottom call site (~line 181): add `-PipelineMetricsDir $PipelineMetricsDir` to the `Invoke-Main` invocation.

- [ ] **Step 3: Run test to verify it passes**

Run: `pwsh -NoProfile -File dashboard/tests/collect-metrics.Tests.ps1`
Expected: PASS.

- [ ] **Step 4: Add the gitignore entry**

Append to `.gitignore` (under the Track 5 block, after `pipeline/cooked/`):

```gitignore
# Track 5 cook metrics (re-generatable; fed to the dashboard like accel/unreal .metrics)
pipeline/.metrics/
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/scripts/collect-metrics.ps1 dashboard/tests/collect-metrics.Tests.ps1 .gitignore
git commit -m "feat(dashboard): pipeline cook-metrics feed (collect-metrics)"
```

---

### Task 7: Dashboard render — "Cook (Track 5)" panel

Render the `pipeline` section when present; add a fixture section so the full-render test asserts it.

**Files:**
- Modify: `dashboard/scripts/build-dashboard.ps1` (`Get-DashboardHtml`: build a conditional panel, insert into the layout)
- Modify: `dashboard/data/snapshot.fixture.json` (add a `pipeline` section)
- Modify: `dashboard/tests/build-dashboard.Tests.ps1` (assert the panel)

**Interfaces:**
- Consumes: `$Snapshot.pipeline` (Task 6 shape: `cooked, cached, totalBytes, elapsedSec, warm, stale, utc`); helpers `ConvertTo-HtmlText`, `Format-When`, `Format-Num`.
- Produces: dashboard HTML containing a "Cook (Track 5)" panel when `pipeline` is present; nothing when absent.

- [ ] **Step 1: Write the failing test**

In `dashboard/tests/build-dashboard.Tests.ps1`, after the Track-4 assertions block (~line 44), add:

```powershell
# ---- Track-5 cook panel ----
Assert-Match 'Cook \(Track 5\)' $html 'has the Track-5 cook panel'
Assert-Match 'cached'           $html 'cook panel shows cache hits'
```

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1`
Expected: FAIL — fixture has no `pipeline` section / panel not rendered.

- [ ] **Step 2: Add a `pipeline` section to the fixture**

In `dashboard/data/snapshot.fixture.json`, add a top-level `"pipeline"` key (sibling of `"unreal"`). Insert before the closing `}` of the root object (mind the trailing comma on the preceding section):

```json
  "pipeline": {
    "stale": false,
    "cooked": 0,
    "cached": 8,
    "totalBytes": 144428,
    "elapsedSec": 0.006,
    "warm": true,
    "utc": "2026-06-22T10:05:00Z"
  }
```

- [ ] **Step 3: Implement the panel**

In `dashboard/scripts/build-dashboard.ps1`, inside `Get-DashboardHtml`, after the unreal/orchestrator block and before `$gen = ...` (~line 158), add:

```powershell
    # cook / Track 5 panel (content-addressed cooker warm-cache)
    $pl = $Snapshot.pipeline
    $plPanel = if ($pl) {
        $plStale = if ($pl.stale) { " <span class='stale'>(stale)</span>" } else { "" }
        $total   = [int]$pl.cooked + [int]$pl.cached
        $warmTxt = if ($pl.warm) { "warm (reused $($pl.cached)/$total)" } else { "cold (cooked $($pl.cooked)/$total)" }
        $mb      = Format-Num ([double]$pl.totalBytes / 1MB) 'N2'
        $when    = Format-When $pl.utc
        "<div class='panel'>" +
        "<h2>Cook (Track 5)$plStale</h2>" +
        "<div class='chips'>last cook: <b>$warmTxt</b> &middot; cooked <b>$($pl.cooked)</b> &middot; cached <b>$($pl.cached)</b> &middot; <b>$mb</b> MB &middot; $(Format-Num ([double]$pl.elapsedSec) 'N3')s &middot; $when</div>" +
        "<p class='note'>Content-addressed cooker: a warm build reuses unchanged assets from the persisted CAS (cache hits), recooking only what changed. Sub-second at sample scale &mdash; the signal is the hit count, not wall-clock.</p>" +
        "</div>"
    } else { "" }
```

Then insert `$plPanel` into the returned HTML — add a line after the unreal panel's closing `</div>` and before the `<div class='cols'>` line (~line 202):

```
$plPanel
```

(i.e. the here-string gets `...</div>\n$plPanel\n\n<div class='cols'>...`).

- [ ] **Step 4: Run the render tests**

Run: `pwsh -NoProfile -File dashboard/tests/build-dashboard.Tests.ps1`
Expected: PASS — including the new Track-5 assertions AND the existing determinism + locale-invariance checks (the panel uses only `Format-When`/`Format-Num`, so it stays locale-invariant).

- [ ] **Step 5: Regenerate the committed dashboard + commit**

Run: `pwsh -NoProfile -File dashboard/scripts/build-dashboard.ps1`
(Regenerates `dashboard/dashboard.html` from `snapshot.json`; since live `snapshot.json` has no `pipeline` section yet, the panel simply won't appear there — that's expected.)

```bash
git add dashboard/scripts/build-dashboard.ps1 dashboard/data/snapshot.fixture.json dashboard/tests/build-dashboard.Tests.ps1 dashboard/dashboard.html
git commit -m "feat(dashboard): render the Cook (Track 5) warm-cache panel"
```

> **Conflict note (spec §4):** the open `codex/aaa-build-engineering` branch (`7a8702a`) also edits `dashboard.html` + `build-dashboard.ps1`. If that branch is merged later, expect a conflict here; resolve by re-applying this additive panel.

---

### Task 8: Documentation

Document the new stage, the warm-cache, and local-reproduce commands.

**Files:**
- Modify: `ci/README.md` (add a Cook Assets row/section)
- Modify: `pipeline/README.md` (add a "CI integration" section)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `ci/README.md`**

Add a row to the scripts/configs table documenting `build-configs.ps1` and a short "Cook Assets (warm cache)" paragraph. Exact text to add (place under the existing scripts table / chain description):

```markdown
### Cook Assets — real cooker, warm-cached

`AAASandbox_CookAssets` is a standalone config (no dependency on the C++ Compile
chain) that regenerates the synthetic Track-5 assets and runs the real
content-addressed cooker (`pipeline/cook.py --pack`). It persists its `pipeline/cooked/`
CAS across builds via a **self artifact-dependency** (last successful build →
`cooked.zip` → `pipeline/cooked`), so a build that changes nothing reuses every
asset (cache hit). A guard fails the build if a warm run recooks everything (the
cache index `.cookindex.json` must survive the `cooked.zip` round-trip — it is a
dotfile, hence the directory-form artifact rule `pipeline/cooked => cooked.zip`).

The chain config now lives in `ci/scripts/build-configs.ps1` (`Get-SandboxBuildConfigs`,
unit-tested by `ci/tests/build-configs.Tests.ps1`); `bootstrap-builds.ps1` consumes it.
```

- [ ] **Step 2: Update `pipeline/README.md`**

Add:

```markdown
## CI integration

The cooker runs in CI as the TeamCity **Cook Assets** stage (`AAASandbox_CookAssets`,
see `ci/`). It is also gated on every push by GitHub Actions
(`.github/workflows/tests.yml` → `pipeline-cooker`) and by `run-tests.sh`.

Reproduce the CI cook locally:

```bash
python pipeline/scripts/make-samples.py
python pipeline/cook.py --pack Cooked-assets.pak --stats-json pipeline/.metrics/cook-local.json
# run again: warm cache -> "cooked 0 / cached 8"
python pipeline/cook.py --pack Cooked-assets.pak --stats-json pipeline/.metrics/cook-local.json
```

Cook stats in `pipeline/.metrics/` feed the dashboard "Cook (Track 5)" panel via
`dashboard/scripts/collect-metrics.ps1`.
```

- [ ] **Step 3: Verify the local-reproduce commands from the docs actually work**

Run the four commands from the `pipeline/README.md` snippet. Expected: first cook `cooked 8`, second cook `cached 8`. Clean up: `rm -rf pipeline/assets pipeline/cooked pipeline/.metrics Cooked-assets.pak`.

- [ ] **Step 4: Commit**

```bash
git add ci/README.md pipeline/README.md
git commit -m "docs: document the Cook Assets stage + cooker CI integration"
```

---

## Self-Review

**1. Spec coverage:**
- §3/§4 new standalone stage → Tasks 3, 4. ✔
- §4 `cook.py` makedirs hardening → Task 1. ✔
- §4 GH Actions `pipeline-cooker` + `run-tests.sh` → Task 5. ✔
- §4 collect-metrics `pipeline` feed → Task 6. ✔
- §4 dashboard render panel → Task 7. ✔
- §4 `.gitignore pipeline/.metrics/` → Task 6 (Step 4). ✔
- §4 docs → Task 8. ✔
- §6 warm-cache invariant (dir-form rule + `cached>0` guard, no de-dot) → Task 4 (config + guard step). ✔
- §6 missing-blob recook (test-only) → Task 2. ✔
- §6 first-build empty cache (cook.py makes out_dir; non-fatal dep) → Task 4 (helper comment) + GATED note. ✔
- §7 determinism + cold-start tests → already exist (`test_pipeline.py`); not duplicated (noted). ✔
- §7 stage-shape assertion → Tasks 3-4 (`build-configs.Tests.ps1`). ✔
- §8 gated items → flagged in Task 4, not executed. ✔
- §9 non-goals (no hoops-pipeline change, no GC, no REST auto-pull, no shared volume, no new flags) → honored. ✔

**2. Placeholder scan:** No TBD/TODO; every code step shows actual code; commands have expected output. ✔

**3. Type consistency:**
- `Get-SandboxBuildConfigs -VersionStampScript` — defined Task 3, called Task 3 (bootstrap) + Tasks 3/4 (tests). ✔
- Config keys `Id/Name/Steps/SnapshotDeps/ArtifactDeps/ArtifactRules/WarmCacheArtifact` — consistent across Tasks 3-4 and the apply loop. ✔
- `WarmCacheArtifact.PathRules` — produced Task 4 config, consumed by `Add-SelfArtifactDep` + asserted in test. ✔
- `ConvertFrom-PipelineMetrics` output (`cooked/cached/totalBytes/elapsedSec/warm/stale/utc`) — produced Task 6, consumed by Task 7 render + asserted in both tests. ✔
- Cook-stats JSON field names (`textures_cooked` etc.) match `cooker/pipeline.py` `Stats` dataclass (`dataclasses.asdict`). ✔
