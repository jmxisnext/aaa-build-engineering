"""Unit tests for the depot-hygiene submit trigger (validate-submit.py).

The trigger is pure policy logic wrapped around two `p4` shell-outs
(`describe -s` for the file list/description, `fstat` for file size). We stub
`module.p4` with a dispatcher keyed on the p4 subcommand, so every rule runs
without a live server. main() returns 0 to allow a submit, 1 to reject it.
"""

from __future__ import annotations

import io
import os
import unittest
from contextlib import redirect_stderr
from unittest import mock

import _triggerlib as tl

vs = tl.load_module(os.path.join(tl.TRIGGERS_DIR, "validate-submit.py"), "validate_submit")

MB = 1024 * 1024


def describe_output(files, desc="Routine change"):
    """Build realistic `p4 describe -s` text: header, tab-indented description
    block, the 'Affected files' marker, then '... //path#rev action' lines."""
    desc_block = "".join(f"\t{line}\n" for line in desc.splitlines())
    file_block = "".join(f"... {f}#1 add\n" for f in files)
    return (
        "Change 4242 by devuser@devuser-WS01 on 2026/06/19 12:00:00\n\n"
        f"{desc_block}\n"
        "Affected files ...\n\n"
        f"{file_block}"
    )


def make_fake_p4(describe_out, size_map=None):
    """Dispatcher for module.p4: answers `describe` and `fstat` calls."""
    size_map = size_map or {}

    def fake(*args):
        # describe is `p4 describe -s <cl>`; fstat is `p4 -ztag fstat ... <spec>`,
        # so match on membership rather than position.
        if "describe" in args:
            return describe_out
        if "fstat" in args:
            spec = args[-1]                      # "<depot>@=<change>"
            depot = spec.split("@=")[0]
            size = size_map.get(depot)
            return "" if size is None else f"... fileSize {size}\n"
        return ""

    return fake


def run_main(fake_p4, change="4242", max_mb=50):
    """Drive main() with a stubbed p4 and a known size limit; capture stderr."""
    err = io.StringIO()
    with mock.patch.object(vs, "p4", fake_p4), \
         mock.patch.object(vs, "MAX_FILE_MB", max_mb), \
         mock.patch.object(vs, "sys") as fake_sys:
        fake_sys.argv = ["validate-submit.py", change]
        fake_sys.stderr = err
        rc = vs.main()
    return rc, err.getvalue()


class FetchChangeParsing(unittest.TestCase):
    def test_parses_description_and_files(self):
        out = describe_output(
            ["//game/main/Code/Foo.cpp", "//game/main/Bin/Foo.obj"],
            desc="Add renderer feature\n[engine] bump",
        )
        with mock.patch.object(vs, "p4", lambda *a: out):
            desc, files = vs.fetch_change("4242")
        self.assertEqual(desc, "Add renderer feature\n[engine] bump")
        self.assertEqual(
            files, ["//game/main/Code/Foo.cpp", "//game/main/Bin/Foo.obj"]
        )


class ForbiddenExtensionRule(unittest.TestCase):
    def test_compiled_output_is_rejected(self):
        fake = make_fake_p4(describe_output(["//game/main/Bin/Foo.obj"]))
        rc, err = run_main(fake)
        self.assertEqual(rc, 1)
        self.assertIn("build-artifact", err)
        self.assertIn("Foo.obj", err)

    def test_extension_match_is_case_insensitive(self):
        fake = make_fake_p4(describe_output(["//game/main/Bin/Foo.PDB"]))
        rc, _ = run_main(fake)
        self.assertEqual(rc, 1)

    def test_thirdparty_prebuilt_binaries_are_exempt(self):
        # //thirdparty/ legitimately ships prebuilt vendor .lib/.dll — the
        # forbidden-extension rule must NOT fire there.
        fake = make_fake_p4(describe_output(["//thirdparty/physx/PhysX.lib"]))
        rc, _ = run_main(fake)
        self.assertEqual(rc, 0)

    def test_ordinary_source_passes(self):
        fake = make_fake_p4(describe_output(["//game/main/Code/Foo.cpp"]))
        rc, _ = run_main(fake)
        self.assertEqual(rc, 0)


class OversizedFileRule(unittest.TestCase):
    def test_oversized_file_without_token_is_rejected(self):
        depot = "//game/main/Art/huge.psd"
        fake = make_fake_p4(describe_output([depot]), size_map={depot: 60 * MB})
        rc, err = run_main(fake, max_mb=50)
        self.assertEqual(rc, 1)
        self.assertIn("oversized", err)

    def test_large_ok_token_overrides_the_size_rule(self):
        depot = "//game/main/Art/huge.psd"
        fake = make_fake_p4(
            describe_output([depot], desc="Import master art [large-ok]"),
            size_map={depot: 60 * MB},
        )
        rc, _ = run_main(fake, max_mb=50)
        self.assertEqual(rc, 0)

    def test_token_match_is_case_insensitive(self):
        depot = "//game/main/Art/huge.psd"
        fake = make_fake_p4(
            describe_output([depot], desc="Import [LARGE-OK]"),
            size_map={depot: 60 * MB},
        )
        rc, _ = run_main(fake, max_mb=50)
        self.assertEqual(rc, 0)

    def test_file_under_limit_passes(self):
        depot = "//game/main/Art/small.psd"
        fake = make_fake_p4(describe_output([depot]), size_map={depot: 10 * MB})
        rc, _ = run_main(fake, max_mb=50)
        self.assertEqual(rc, 0)

    def test_unknown_size_skips_the_rule_rather_than_blocking(self):
        # fstat returns no fileSize line -> file_size() is None -> the trigger
        # must not block on a metadata gap (documented fail-open for size only).
        depot = "//game/main/Art/mystery.psd"
        fake = make_fake_p4(describe_output([depot]), size_map=None)
        rc, _ = run_main(fake, max_mb=50)
        self.assertEqual(rc, 0)


class MainArgHandling(unittest.TestCase):
    def test_missing_changelist_arg_is_an_error(self):
        err = io.StringIO()
        with mock.patch.object(vs, "sys") as fake_sys:
            fake_sys.argv = ["validate-submit.py"]
            fake_sys.stderr = err
            rc = vs.main()
        self.assertEqual(rc, 1)
        self.assertIn("expected changelist number", err.getvalue())


if __name__ == "__main__":
    unittest.main()
