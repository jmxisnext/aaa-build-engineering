# tools/ — Track 1 client-side automation

Python utilities built against **P4Python** (Perforce's official Python module, distributed as a wheel from `https://filehost.perforce.com/perforce/r25.2/bin.ntx64/`).

## What's here

| File | Purpose |
|---|---|
| `stale_cl_janitor.py` | Lists pending changelists older than N days and (with `--apply`) shelves+reverts them |
| `janitor.ps1` | PowerShell wrapper — invokes the venv's python so callers don't need to know the venv path |
| `.venv/` | Local virtual env with P4Python installed (gitignored; recreate via the setup steps below) |
| `_p4python_wheels/` | Extracted P4Python wheel (gitignored; recreate via the setup steps below) |
| `p4python-3.13-x64-whl.zip` | The original Perforce-distributed zip (gitignored; re-download from the URL below) |

## One-time setup (already done in this sandbox)

```powershell
$tools = "J:\jammers-lab\aaa-build-engineering\perforce\tools"
$wheelZip = "$tools\p4python-3.13-x64-whl.zip"
Invoke-WebRequest -Uri "https://filehost.perforce.com/perforce/r25.2/bin.ntx64/p4python-3.13-x64-whl.zip" -OutFile $wheelZip

Expand-Archive -Path $wheelZip -DestinationPath "$tools\_p4python_wheels"
python -m venv "$tools\.venv"
& "$tools\.venv\Scripts\python.exe" -m pip install "$tools\_p4python_wheels\p4python-2025.2.2863679-cp313-cp313-win_amd64.whl"
```

Smoke-test:
```powershell
& "$tools\.venv\Scripts\python.exe" -c "from P4 import P4; print(P4.identify())"
```

## Running the janitor

```powershell
# Default: dry-run, days=7
.\janitor.ps1

# Catch everything pending (any age)
.\janitor.ps1 --days 0

# Show files in each stale CL
.\janitor.ps1 --days 0 --verbose

# ACTUALLY shelve+revert; this is the only mode that mutates state
.\janitor.ps1 --days 0 --apply

# Narrow to a single user
.\janitor.ps1 --days 30 --user-filter some.engineer

# Help
.\janitor.ps1 -h
```

## Design notes

- **Safe by default.** The script does nothing destructive without an explicit `--apply` flag. The report-only output is identical to what `--apply` would do.
- **Shelve, then revert.** Shelving preserves the engineer's work on the server side. After the revert, files are free for others — but the original engineer can recover by running `p4 unshelve -s <CL>` against their workspace.
- **P4Python over subprocess.** The trigger script in `../triggers/require-engine-tag.py` uses `subprocess.run("p4", ...)` because (a) it's a single trivial call and (b) it had to run in p4d's minimal env. This janitor uses P4Python because it makes many calls per pending CL, needs structured output, and has stable connection state.
- **`P4` instance lifecycle.** Always wrap `connect()` ... `disconnect()` in try/finally so a script crash doesn't leak server-side state.
- **Error model.** P4Python's `exception_level = 1` raises only on real errors, not warnings. Default level 2 also raises on "no files in changelist" which is noisy for batch tools.

## What a production version would add

- Output: machine-readable JSON for downstream tooling + human-readable table (the current script is human-only).
- Slack / email notification to CL owners *before* the apply step, with a grace-period link.
- Per-team policy: `//game/feature-*/...` CLs get 14d, `//game/main/...` CLs get 3d, etc.
- Lock around the apply step — multiple instances of the janitor must not stomp each other.
- Audit log: every shelve+revert appended to a long-term log so the team has a paper trail.
- Run nightly under a service account via Windows Scheduled Task or as a CI job. The job's identity owns the shelved CLs in the audit log.
