"""Stale changelist janitor.

Reports on (and optionally cleans up) pending changelists that have been
sitting around for more than --days days.

Usage:
    # Report only (default; safe; mutates nothing):
    python stale_cl_janitor.py --days 7

    # Apply cleanup — shelve the work for later recovery, then revert
    # the open files so they're free for others. The shelved CL retains
    # the work and can be unshelved by the original owner.
    python stale_cl_janitor.py --days 7 --apply

    # Filter to one user:
    python stale_cl_janitor.py --days 30 --user some.engineer

    # Verbose: print full description + file list for each match
    python stale_cl_janitor.py --days 7 --verbose

Why this exists:
    In a real studio, pending changelists pile up. Engineers go on leave,
    machines die, branches get abandoned. Files stay open against those
    pending CLs which means: (1) artists can't take exclusive locks on
    those files, (2) the depot UI gets noisy, (3) submit-to-revert
    debugging gets harder because the noise hides real signal.

    A nightly janitor that flags > N-day pending CLs and shelves+reverts
    the truly stale ones is a classic build-engineer chore. This is the
    sandbox version.

Safety:
    - Default mode is dry-run; mutating actions require explicit --apply.
    - Shelve preserves work. Revert frees files but the shelf retains
      every change. The original engineer can `p4 unshelve -s <CL>`
      to recover.
    - --user filter prevents accidentally janitoring the whole studio
      while testing.
"""

from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Iterable
from typing import Any

from P4 import P4, P4Exception


# ---------- core helpers ----------

def connect(port: str, user: str) -> P4:
    p4 = P4()
    p4.port = port
    p4.user = user
    p4.exception_level = 1  # raise on errors, not on warnings
    p4.connect()
    return p4


def pending_changes(p4: P4, user_filter: str | None) -> list[dict[str, Any]]:
    """All pending changes, optionally narrowed to one user."""
    args = ["-s", "pending", "-l"]
    if user_filter:
        args += ["-u", user_filter]
    return p4.run_changes(*args)


def files_in_change(p4: P4, change: str) -> list[str]:
    """List depot paths attached to a pending change. Returns [] for empty CLs."""
    try:
        opened = p4.run_opened("-c", change)
    except P4Exception:
        return []
    return [row["depotFile"] for row in opened if "depotFile" in row]


def age_days(change_record: dict[str, Any]) -> float:
    epoch_str = change_record.get("time", "0")
    epoch = int(epoch_str) if epoch_str.isdigit() else 0
    if epoch == 0:
        return 0.0
    return (time.time() - epoch) / 86400.0


# ---------- actions ----------

def report(records: Iterable[dict[str, Any]], verbose: bool) -> None:
    rows = list(records)
    if not rows:
        print("No stale pending changelists found.")
        return

    print(f"{'CL':>6}  {'AGE':>6}  {'OWNER':<24}  {'FILES':>5}  DESCRIPTION")
    print("-" * 80)
    for r in rows:
        cl = r["change"]
        age = r["_age_days"]
        owner = r.get("user", "?")
        files = r["_files"]
        desc_line = (r.get("desc") or "").splitlines()[0] if r.get("desc") else "(no description)"
        desc_line = desc_line.strip()[:60]
        print(f"{cl:>6}  {age:>5.1f}d  {owner:<24}  {len(files):>5}  {desc_line}")
        if verbose:
            for f in files:
                print(f"            {f}")
            print()


def shelve_and_revert(p4: P4, change: str) -> None:
    """Shelve the CL (preserves work) then revert open files (frees them)."""
    p4.run_shelve("-c", change)
    p4.run_revert("-c", change, "//...")


# ---------- entry point ----------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", default="localhost:1666")
    ap.add_argument("--user", default="james", help="P4USER for the janitor session")
    ap.add_argument("--days", type=float, default=7.0, help="age threshold")
    ap.add_argument("--user-filter", default=None, help="only janitor CLs owned by this user")
    ap.add_argument("--apply", action="store_true", help="actually shelve+revert (default is dry-run)")
    ap.add_argument("--verbose", action="store_true", help="show files in each stale CL")
    args = ap.parse_args(argv)

    p4 = connect(args.port, args.user)
    try:
        all_pending = pending_changes(p4, args.user_filter)
        enriched: list[dict[str, Any]] = []
        for r in all_pending:
            r["_age_days"] = age_days(r)
            if r["_age_days"] < args.days:
                continue
            r["_files"] = files_in_change(p4, r["change"])
            enriched.append(r)

        # Sort oldest-first so the report leads with the worst offenders.
        enriched.sort(key=lambda r: r["_age_days"], reverse=True)

        report(enriched, verbose=args.verbose)

        if args.apply:
            print(f"\n--apply: shelving + reverting {len(enriched)} changelist(s)...")
            for r in enriched:
                cl = r["change"]
                # Only act if there's actual work to shelve.
                if not r["_files"]:
                    print(f"  CL {cl}: empty (no files) — skipping shelve")
                    continue
                try:
                    shelve_and_revert(p4, cl)
                    print(f"  CL {cl}: shelved + reverted")
                except P4Exception as e:
                    print(f"  CL {cl}: FAILED — {e}", file=sys.stderr)
        else:
            print(f"\n(dry-run — {len(enriched)} would be acted on with --apply)")

        return 0
    finally:
        p4.disconnect()


if __name__ == "__main__":
    sys.exit(main())
