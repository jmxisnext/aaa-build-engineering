"""Shared test helpers for the perforce trigger/tool suites.

The triggers live in files with hyphens in their names (`validate-submit.py`,
`require-engine-tag.py`) which aren't importable as normal modules, and the
janitor imports the third-party `P4` module that isn't installed in CI. Both
problems are solved here: `load_module` execs a script by path under a clean
module name, and `install_fake_p4_module` injects a stub `P4` into sys.modules
*before* such a script is loaded.

Nothing here depends on a test framework — the suites use stdlib `unittest`
(the dependency-free Python analogue of the repo's throw-on-failure .ps1
convention).
"""

from __future__ import annotations

import importlib.util
import os
import sys
import types

_HERE = os.path.dirname(os.path.abspath(__file__))
TRIGGERS_DIR = os.path.normpath(os.path.join(_HERE, "..", "triggers"))
TOOLS_DIR = os.path.normpath(os.path.join(_HERE, "..", "tools"))


def load_module(path: str, name: str) -> types.ModuleType:
    """Load a Python file by path under an arbitrary module name.

    Used so hyphenated trigger filenames (not valid identifiers) can still be
    imported and exercised directly.
    """
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader, f"could not build import spec for {path}"
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


class FakeP4Exception(Exception):
    """Stand-in for P4Exception so trigger/tool code can `except` it in tests."""


def install_fake_p4_module() -> types.ModuleType:
    """Inject a stub `P4` module into sys.modules.

    `stale_cl_janitor.py` does `from P4 import P4, P4Exception` at import time;
    the real module ships with the P4Python bindings, which CI doesn't have.
    The stub provides just the two names the import binds. Tests drive the
    janitor through an injected fake connection rather than this class, so the
    class body can stay empty.
    """
    mod = types.ModuleType("P4")
    mod.P4 = type("P4", (), {})
    mod.P4Exception = FakeP4Exception
    sys.modules["P4"] = mod
    return mod
