"""Unit tests for the require-engine-tag submit trigger.

Gate: any submit that touches //engine/ must carry an [engine] tag in its
description. Submits that touch nothing under //engine/ are exempt. The trigger
shells out once (`p4 describe -s`); we stub that to drive every branch.
"""

from __future__ import annotations

import io
import os
import unittest
from unittest import mock

import _triggerlib as tl

ret = tl.load_module(
    os.path.join(tl.TRIGGERS_DIR, "require-engine-tag.py"), "require_engine_tag"
)


def describe_output(files, desc="Routine change"):
    desc_block = "".join(f"\t{line}\n" for line in desc.splitlines())
    file_block = "".join(f"... {f}#1 edit\n" for f in files)
    return (
        "Change 77 by devuser@devuser-WS01 on 2026/06/19 12:00:00\n\n"
        f"{desc_block}\n"
        "Affected files ...\n\n"
        f"{file_block}"
    )


def run_main(describe_out, change="77"):
    err = io.StringIO()
    with mock.patch.object(ret, "p4", lambda *a: describe_out), \
         mock.patch.object(ret, "sys") as fake_sys:
        fake_sys.argv = ["require-engine-tag.py", change]
        fake_sys.stderr = err
        rc = ret.main()
    return rc, err.getvalue()


class EngineGate(unittest.TestCase):
    def test_engine_change_without_tag_is_rejected(self):
        out = describe_output(["//engine/Code/Renderer.cpp"], desc="fix a crash")
        rc, err = run_main(out)
        self.assertEqual(rc, 1)
        self.assertIn("[engine]", err)

    def test_engine_change_with_tag_is_allowed(self):
        out = describe_output(
            ["//engine/Code/Renderer.cpp"], desc="fix a crash [engine]"
        )
        rc, _ = run_main(out)
        self.assertEqual(rc, 0)

    def test_tag_match_is_case_insensitive(self):
        out = describe_output(["//engine/Code/Renderer.cpp"], desc="bump [ENGINE]")
        rc, _ = run_main(out)
        self.assertEqual(rc, 0)

    def test_non_engine_change_is_exempt_even_without_tag(self):
        out = describe_output(["//game/main/Code/Foo.cpp"], desc="gameplay tweak")
        rc, _ = run_main(out)
        self.assertEqual(rc, 0)

    def test_mixed_change_touching_engine_still_needs_the_tag(self):
        out = describe_output(
            ["//game/main/Code/Foo.cpp", "//engine/Code/Renderer.cpp"],
            desc="cross-cutting change",
        )
        rc, _ = run_main(out)
        self.assertEqual(rc, 1)


class FetchChangeParsing(unittest.TestCase):
    def test_parses_multiline_description_and_files(self):
        out = describe_output(
            ["//engine/Code/A.cpp", "//engine/Code/B.cpp"],
            desc="line one\nline two",
        )
        with mock.patch.object(ret, "p4", lambda *a: out):
            desc, files = ret.fetch_change("77")
        self.assertEqual(desc, "line one\nline two")
        self.assertEqual(files, ["//engine/Code/A.cpp", "//engine/Code/B.cpp"])


if __name__ == "__main__":
    unittest.main()
