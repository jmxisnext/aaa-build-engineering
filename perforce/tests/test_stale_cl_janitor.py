"""Unit tests for the stale-changelist janitor.

The janitor imports the third-party `P4` bindings at module load, so we inject
a stub `P4` module first. The real connection is replaced with a FakeP4 that
records the mutating calls (`run_shelve`/`run_revert`), letting us assert the
safety contract: dry-run mutates NOTHING; --apply shelves+reverts non-empty CLs
and skips empty ones.
"""

from __future__ import annotations

import io
import os
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock

import _triggerlib as tl

_fake_p4_mod = tl.install_fake_p4_module()
P4Exception = _fake_p4_mod.P4Exception

jan = tl.load_module(
    os.path.join(tl.TOOLS_DIR, "stale_cl_janitor.py"), "stale_cl_janitor"
)


class FakeP4:
    """Records mutations; serves canned `changes`/`opened` results."""

    def __init__(self, changes, opened_by_cl, opened_raises=()):
        self._changes = changes
        self._opened = opened_by_cl
        self._opened_raises = set(opened_raises)
        self.shelved = []
        self.reverted = []
        self.disconnected = False

    def run_changes(self, *args):
        return self._changes

    def run_opened(self, _flag, change):
        if change in self._opened_raises:
            raise P4Exception(f"no such change {change}")
        return self._opened.get(change, [])

    def run_shelve(self, _flag, change):
        self.shelved.append(change)

    def run_revert(self, _flag, change, _path):
        self.reverted.append(change)

    def disconnect(self):
        self.disconnected = True


def cl(change, days_old, user="devuser", desc="wip"):
    epoch = int(time.time() - days_old * 86400)
    return {"change": change, "time": str(epoch), "user": user, "desc": desc}


class AgeDays(unittest.TestCase):
    def test_computes_age_from_epoch(self):
        rec = cl("100", days_old=10)
        self.assertAlmostEqual(jan.age_days(rec), 10.0, places=1)

    def test_zero_epoch_is_zero_age(self):
        self.assertEqual(jan.age_days({"time": "0"}), 0.0)

    def test_non_numeric_time_is_zero_age(self):
        self.assertEqual(jan.age_days({"time": "not-a-number"}), 0.0)

    def test_missing_time_field_is_zero_age(self):
        self.assertEqual(jan.age_days({}), 0.0)


class FilesInChange(unittest.TestCase):
    def test_returns_depot_paths(self):
        p4 = FakeP4(
            changes=[],
            opened_by_cl={"100": [{"depotFile": "//game/main/A.cpp"},
                                  {"depotFile": "//game/main/B.cpp"}]},
        )
        self.assertEqual(
            jan.files_in_change(p4, "100"),
            ["//game/main/A.cpp", "//game/main/B.cpp"],
        )

    def test_empty_change_returns_empty_list_on_exception(self):
        p4 = FakeP4(changes=[], opened_by_cl={}, opened_raises=["999"])
        self.assertEqual(jan.files_in_change(p4, "999"), [])


class MainSafetyContract(unittest.TestCase):
    def _fake(self):
        # CL 100: 10 days old, has files (stale).  CL 101: 1 day old (fresh).
        # CL 102: 30 days old but empty (stale-but-nothing-to-shelve).
        changes = [cl("100", 10), cl("101", 1), cl("102", 30)]
        opened = {
            "100": [{"depotFile": "//game/main/A.cpp"}],
            "102": [],
        }
        return FakeP4(changes=changes, opened_by_cl=opened)

    def test_dry_run_mutates_nothing(self):
        p4 = self._fake()
        with mock.patch.object(jan, "connect", lambda *a, **k: p4):
            out = io.StringIO()
            with redirect_stdout(out):
                rc = jan.main(["--days", "7"])
        self.assertEqual(rc, 0)
        self.assertEqual(p4.shelved, [])
        self.assertEqual(p4.reverted, [])
        self.assertIn("dry-run", out.getvalue())
        self.assertTrue(p4.disconnected)

    def test_apply_shelves_and_reverts_only_nonempty_stale_cls(self):
        p4 = self._fake()
        with mock.patch.object(jan, "connect", lambda *a, **k: p4):
            out = io.StringIO()
            with redirect_stdout(out):
                rc = jan.main(["--days", "7", "--apply"])
        self.assertEqual(rc, 0)
        # CL 100 is stale + non-empty -> acted on. 101 is fresh, 102 is empty.
        self.assertEqual(p4.shelved, ["100"])
        self.assertEqual(p4.reverted, ["100"])
        self.assertIn("empty", out.getvalue())  # CL 102 skip is reported

    def test_threshold_filters_out_fresh_changes(self):
        p4 = self._fake()
        with mock.patch.object(jan, "connect", lambda *a, **k: p4):
            with redirect_stdout(io.StringIO()):
                jan.main(["--days", "20", "--apply"])
        # Only CL 102 (30d) clears a 20-day bar, and it's empty -> no mutation.
        self.assertEqual(p4.shelved, [])


class Report(unittest.TestCase):
    def test_empty_report_is_friendly(self):
        out = io.StringIO()
        with redirect_stdout(out):
            jan.report([], verbose=False)
        self.assertIn("No stale pending changelists", out.getvalue())

    def test_report_lists_cl_owner_and_filecount(self):
        rows = [{"change": "100", "_age_days": 12.3, "user": "alice",
                 "_files": ["//x/a.cpp", "//x/b.cpp"], "desc": "fix thing"}]
        out = io.StringIO()
        with redirect_stdout(out):
            jan.report(rows, verbose=False)
        text = out.getvalue()
        self.assertIn("100", text)
        self.assertIn("alice", text)
        self.assertIn("fix thing", text)


if __name__ == "__main__":
    unittest.main()
