"""Perforce change-submit trigger: require an [engine] tag in the description
for any submit that touches //engine/...

How p4d invokes this:
    python require-engine-tag.py <change_number>

Behavior:
    - exit 0 -> allow the submit
    - exit 1 + stderr message -> reject the submit; the message is shown
      to the user attempting the submit.

Registered via `p4 triggers`:
    Triggers:
        require-engine-tag change-submit //engine/... "python C:\\PerforceSandbox\\triggers\\require-engine-tag.py %change%"

Note: only the path-spec column (//engine/...) is treated as a match filter.
The script still re-checks the file list itself, both as defense-in-depth
and because the path-spec column does not always behave as expected with
stream depots.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys

# Tag we require to be present somewhere in the changelist description.
# Case-insensitive match; surrounded by [].
REQUIRED_TAG = "[engine]"

# Path prefix we gate. Submits that don't touch any file under this prefix
# are exempt.
GATED_PREFIX = "//engine/"

# Triggers run in p4d's environment which usually does not have a sensible
# PATH on Windows. Resolve p4.exe explicitly. Allow override via env.
P4_EXE = os.environ.get("P4_EXE") or shutil.which("p4") or r"C:\Program Files\Perforce\p4.exe"


def p4(*args: str) -> str:
    """Run a p4 command and return stdout as text. Surface failures clearly."""
    result = subprocess.run(
        (P4_EXE, *args),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(f"trigger: p4 {' '.join(args)} failed: {result.stderr}\n")
        sys.exit(1)
    return result.stdout


def fetch_change(change: str) -> tuple[str, list[str]]:
    """Return (description, list of depot paths in the change).

    Uses `p4 describe -s` which lists files without their diffs.
    """
    out = p4("describe", "-s", change)

    # `p4 describe -s` output begins with a header line then the description
    # block (indented), then "Affected files ...", then file lines.
    # Description starts after the blank line following the header and runs
    # until the "Affected files" marker.
    lines = out.splitlines()
    desc_lines: list[str] = []
    files: list[str] = []
    in_desc = False
    in_files = False
    for line in lines:
        if line.startswith("Affected files"):
            in_desc = False
            in_files = True
            continue
        if in_files:
            # Lines like: "... //engine/Code/Renderer.cpp#3 edit"
            m = re.match(r"^\.\.\. (//\S+?)#\d+\s+\w+", line)
            if m:
                files.append(m.group(1))
            continue
        # Description block: lines indented by a tab.
        if line.startswith("\t"):
            in_desc = True
            desc_lines.append(line[1:])
        elif in_desc and line.strip() == "":
            desc_lines.append("")
        elif in_desc:
            in_desc = False

    description = "\n".join(desc_lines).strip()
    return description, files


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("trigger: expected changelist number as first argument\n")
        return 1

    change = sys.argv[1]
    description, files = fetch_change(change)

    touches_engine = any(f.startswith(GATED_PREFIX) for f in files)
    if not touches_engine:
        return 0  # Exempt — not an engine change.

    if REQUIRED_TAG.lower() in description.lower():
        return 0  # Tag present — allow.

    # Reject. The message goes to stderr; p4d forwards it to the user.
    sys.stderr.write(
        f"\nSubmit rejected by require-engine-tag trigger.\n"
        f"\n"
        f"Changelist {change} modifies files under {GATED_PREFIX} but the\n"
        f"description does not contain the required tag {REQUIRED_TAG}.\n"
        f"\n"
        f"Edit the changelist description (p4 change {change}) and add\n"
        f"{REQUIRED_TAG} somewhere in the description, then resubmit.\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
