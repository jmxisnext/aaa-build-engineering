#!/usr/bin/env bash
# run-tests.sh — one entry point for every test suite in the repo.
#
# The repo's testing convention is "a runnable thing that exits nonzero on
# failure, so CI / a human can gate on exit code" (see dashboard/tests/_assert.ps1
# and ci/.../ShotmeterTests.cpp). Those suites existed but had to be invoked one
# at a time, by hand, on the right toolchain. This aggregates them:
#
#   * perforce triggers/tools  — Python (stdlib unittest)
#   * hoops_tests (ShotMeter)  — C++ (cmake + ctest)
#   * dashboard render/collect — PowerShell (the repo's .ps1 assert harness)
#
# A suite whose toolchain is missing is SKIPPED (not failed), so this is useful
# on a dev box that only has some of the toolchains. Exit code is nonzero iff a
# suite that actually ran failed. CI (.github/workflows/tests.yml) runs each
# suite in its own job with the toolchain guaranteed present.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

pass=0 fail=0 skip=0
declare -a results

record() { results+=("$1 $2"); case "$1" in PASS) ((pass++));; FAIL) ((fail++));; SKIP) ((skip++));; esac; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# ---- 1. Perforce triggers/tools (Python) -----------------------------------
hr; echo "[perforce] Python trigger/tool tests"
if command -v python3 >/dev/null 2>&1; then
    if python3 -m unittest discover -s perforce/tests -t perforce/tests; then
        record PASS "perforce (python)"
    else
        record FAIL "perforce (python)"
    fi
else
    echo "  python3 not found — skipping"; record SKIP "perforce (python)"
fi

# ---- 2. hoops_tests / ShotMeter (C++) --------------------------------------
hr; echo "[ci] hoops_tests (C++ ShotMeter)"
HOOPS_DIR="ci/samples/hoops-brawl-seed/stream"
if command -v cmake >/dev/null 2>&1; then
    BUILD="$HOOPS_DIR/_build"   # _build/ is gitignored
    if cmake -S "$HOOPS_DIR" -B "$BUILD" >/dev/null 2>&1 \
       && cmake --build "$BUILD" --target hoops_tests >/dev/null 2>&1 \
       && ctest --test-dir "$BUILD" --output-on-failure; then
        record PASS "ci/hoops_tests (c++)"
    else
        record FAIL "ci/hoops_tests (c++)"
    fi
else
    echo "  cmake not found — skipping"; record SKIP "ci/hoops_tests (c++)"
fi

# ---- 3. Dashboard render/collect (PowerShell) ------------------------------
hr; echo "[dashboard] PowerShell render/collect tests"
if command -v pwsh >/dev/null 2>&1; then
    db_ok=1
    for t in dashboard/tests/build-dashboard.Tests.ps1 dashboard/tests/collect-metrics.Tests.ps1; do
        echo "  -> $t"
        pwsh -NoProfile -File "$t" || db_ok=0
    done
    [ "$db_ok" -eq 1 ] && record PASS "dashboard (powershell)" || record FAIL "dashboard (powershell)"
else
    echo "  pwsh not found — skipping (CI runs this on a pwsh-equipped runner)"
    record SKIP "dashboard (powershell)"
fi

# ---- summary ----------------------------------------------------------------
hr; echo "Summary:"
for r in "${results[@]}"; do echo "  $r"; done
hr; echo "PASS=$pass  FAIL=$fail  SKIP=$skip"

[ "$fail" -eq 0 ]
