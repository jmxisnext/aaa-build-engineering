"""Perforce change-content trigger: depot-hygiene validation.

Rejects two classes of bad submit, regardless of which depot they target:

  1. Forbidden build-output / junk file types (compiled artifacts that must
     never be versioned): .obj .pdb .exp .ilk .lib .pch .idb .exe .dll .o .a ...
     EXEMPTION: //thirdparty/ — vendor SDKs legitimately ship *prebuilt*
     binaries (.lib/.dll/.exe), so the "no compiled output" rule does not
     apply there. This mirrors the depot split in depot-layout.md.

  2. Oversized files (> MAX_FILE_MB) submitted without an explicit
     [large-ok] override token in the changelist description. Guards against
     the accidental 2 GB temp/blob that bloats the depot forever — and
     "forever" is literal here, because `p4 obliterate` (the only clean way
     to remove it) is broker-blocked in this environment (see
     broker/p4broker.conf). Cheaper to stop the file at submit than to file a
     ticket to rewrite history.

WHY change-content (not change-submit) — the load-bearing design choice:
  - The extension check only needs the file *list*, which is available as
    early as the change-SUBMIT phase.
  - The size check needs the file *content/size*, which is only guaranteed to
    be on the server at the change-CONTENT phase (after file transfer, before
    commit). Pending-change content is read with the `@=<change>` revision
    specifier.
  Using change-content for *both* keeps a single trigger authoritative for all
  hygiene rules. The submit trigger sequence is
  change-submit -> change-content -> change-commit; pick the earliest phase at
  which all the data you need exists. For content/size rules that is
  change-content. (See ../lessons-learned.md.)

How p4d invokes this:
    python validate-submit.py <change_number>

Behavior:
    - exit 0 -> allow the submit
    - exit 1 + stderr message -> reject; the message is shown to the submitter.

Registered via `p4 triggers`:
    Triggers:
        validate-submit change-content //... "python C:\\PerforceSandbox\\triggers\\validate-submit.py %change%"
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys

# --- Policy knobs ------------------------------------------------------------

# Compiled build output / editor junk that must never be versioned. Lower-case;
# matched case-insensitively against each file's extension.
FORBIDDEN_EXTS = {
    ".obj", ".o", ".a", ".lib", ".exp", ".ilk", ".pdb", ".idb", ".pch",
    ".exe", ".dll", ".so", ".dylib", ".tlog", ".ob60", ".ipdb", ".iobj",
}

# Depots/paths exempt from the forbidden-extension rule. //thirdparty/ holds
# *prebuilt* vendor SDKs whose whole purpose is to be checked-in binaries.
EXT_EXEMPT_PREFIXES = ("//thirdparty/",)

# Files larger than this need an explicit [large-ok] override token in the
# changelist description. Override via env P4_MAX_FILE_MB.
MAX_FILE_MB = int(os.environ.get("P4_MAX_FILE_MB") or "50")
SIZE_OVERRIDE_TOKEN = "[large-ok]"

# Triggers run in p4d's environment, which usually lacks a useful PATH on
# Windows (lesson #2 from require-engine-tag). Resolve p4.exe explicitly.
P4_EXE = os.environ.get("P4_EXE") or shutil.which("p4") or r"C:\Program Files\Perforce\p4.exe"


def p4(*args: str) -> str:
    """Run a p4 command, return stdout. Surface failures clearly (and fail
    closed: a trigger that cannot inspect the change must not silently pass)."""
    result = subprocess.run((P4_EXE, *args), capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.stderr.write(f"validate-submit: p4 {' '.join(args)} failed: {result.stderr}\n")
        sys.exit(1)
    return result.stdout


def fetch_change(change: str) -> tuple[str, list[str]]:
    """Return (description, list of depot paths) for the pending change.

    Reuses the `p4 describe -s` parsing proven by require-engine-tag.py: a
    header line, a tab-indented description block, then 'Affected files ...'
    followed by '... //path#rev action' lines.
    """
    out = p4("describe", "-s", change)
    desc_lines: list[str] = []
    files: list[str] = []
    in_desc = False
    in_files = False
    for line in out.splitlines():
        if line.startswith("Affected files"):
            in_desc = False
            in_files = True
            continue
        if in_files:
            m = re.match(r"^\.\.\. (//\S+?)#\d+\s+\w+", line)
            if m:
                files.append(m.group(1))
            continue
        if line.startswith("\t"):
            in_desc = True
            desc_lines.append(line[1:])
        elif in_desc and line.strip() == "":
            desc_lines.append("")
        elif in_desc:
            in_desc = False
    return "\n".join(desc_lines).strip(), files


def file_size(depot_path: str, change: str) -> int | None:
    """Size in bytes of the file *as it exists in this pending change*.

    The `@=<change>` revision specifier resolves to the content shelved/
    transferred for the in-flight change — which is exactly why this trigger
    must run at change-content and not change-submit. Returns None if the
    size can't be determined (we then skip the size rule for that file rather
    than block on a metadata gap)."""
    out = p4("-ztag", "fstat", "-Ol", "-T", "fileSize", f"{depot_path}@={change}")
    m = re.search(r"^\.\.\. fileSize (\d+)", out, re.MULTILINE)
    return int(m.group(1)) if m else None


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("validate-submit: expected changelist number as first argument\n")
        return 1

    change = sys.argv[1]
    description, files = fetch_change(change)
    desc_lower = description.lower()

    violations: list[str] = []

    # --- Rule 1: no compiled build output (except //thirdparty/) -------------
    for f in files:
        if any(f.startswith(p) for p in EXT_EXEMPT_PREFIXES):
            continue
        _, ext = os.path.splitext(f)
        if ext.lower() in FORBIDDEN_EXTS:
            violations.append(
                f"  [build-artifact] {f}\n"
                f"      '{ext}' is compiled build output and must not be versioned. "
                f"Build it from source in CI instead."
            )

    # --- Rule 2: no oversized files without [large-ok] -----------------------
    if SIZE_OVERRIDE_TOKEN.lower() not in desc_lower:
        limit_bytes = MAX_FILE_MB * 1024 * 1024
        for f in files:
            size = file_size(f, change)
            if size is not None and size > limit_bytes:
                violations.append(
                    f"  [oversized] {f}\n"
                    f"      {size / 1024 / 1024:.1f} MB exceeds the {MAX_FILE_MB} MB limit. "
                    f"If this is intentional, add {SIZE_OVERRIDE_TOKEN} to the description."
                )

    if not violations:
        return 0

    sys.stderr.write(
        f"\nSubmit rejected by validate-submit (depot-hygiene) trigger.\n"
        f"\nChangelist {change} has {len(violations)} policy violation(s):\n\n"
        + "\n".join(violations)
        + "\n\nFix the files above (or add the noted override) and resubmit "
          f"with `p4 submit -c {change}`.\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
