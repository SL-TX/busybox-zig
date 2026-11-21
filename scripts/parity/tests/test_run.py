"""Self-tests for the differential parity harness (Task 5).

These tests exercise the harness itself, independently of any applet wave.
The production entry point is ``scripts/parity/run.py``; the small helpers it
exports (``run_case``, ``compare``, ``skip_decision``) are imported directly so
a regression in the comparison logic is caught without the reference binary.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

from scripts.parity.normalize import apply as normalize_apply
from scripts.parity.run import compare, compare_observations, run_case, skip_decision
from scripts.parity.sandbox import materialize, snapshot

# The CI image pre-creates this scratch directory; creating it here keeps the
# tests runnable on a fresh checkout as well.
SCRATCH = "/tmp/opencode"
os.makedirs(SCRATCH, exist_ok=True)


def make_case(**overrides):
    """Return a minimal, schema-valid single case with optional overrides."""
    case = {
        "name": "basic",
        "argv": [],
        "stdin": None,
        "files": {},
        "dirs": [],
        "symlinks": {},
        "env": {},
        "cwd": ".",
        "timeout_ms": 5000,
        "normalize": [],
        "requires": [],
        "expect": {},
    }
    case.update(overrides)
    return case


class HarnessSelfTest(unittest.TestCase):
    def test_same_binary_passes(self):
        # Running one binary and checking it against its own declared expect
        # must be a pass — this is the primitive every differential case builds
        # on.  sys.executable prints "x\n" for the argv below.
        result = run_case(
            binary=sys.executable,
            argv=["-c", "print('x')"],
            case=make_case(expect={"exit": 0, "stdout": "x\n", "stderr": ""}),
        )
        self.assertEqual(result.status, "pass", result.diff)

    def test_different_output_fails(self):
        result = compare(expected="a\n", actual="b\n")
        self.assertEqual(result.status, "fail")
        self.assertIn("stdout", result.diff)

    def test_compare_equal_passes(self):
        result = compare(expected="a\n", actual="a\n")
        self.assertEqual(result.status, "pass")
        self.assertEqual(result.diff, "")

    def test_compare_observations_reports_each_field(self):
        from scripts.parity.run import Observation

        expected = Observation(stdout="a\n", stderr="", exit=0, tree={})
        actual = Observation(stdout="b\n", stderr="oops\n", exit=1, tree={})
        result = compare_observations(expected, actual, name="demo")
        self.assertEqual(result.status, "fail")
        for field in ("stdout", "stderr", "exit"):
            self.assertIn(field, result.diff)
        self.assertEqual(result.name, "demo")

    def test_expect_mismatch_fails(self):
        result = run_case(
            binary=sys.executable,
            argv=["-c", "print('x')"],
            case=make_case(expect={"exit": 0, "stdout": "wrong\n"}),
        )
        self.assertEqual(result.status, "fail")
        self.assertIn("expect.stdout", result.diff)

    def test_sandbox_materialize_and_snapshot(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            root = os.path.join(tmp, "sandbox")
            materialize(
                {
                    "files": {"file.txt": "content\n", "sub/inner": "x"},
                    "dirs": ["empty"],
                    "symlinks": {"link": "file.txt"},
                },
                root,
            )
            tree = snapshot(root)
            self.assertEqual(tree["file.txt"]["type"], "file")
            self.assertEqual(tree["file.txt"]["content"], b"content\n")
            self.assertEqual(tree["sub"]["type"], "dir")
            self.assertEqual(tree["sub/inner"]["content"], b"x")
            self.assertEqual(tree["empty"]["type"], "dir")
            self.assertEqual(tree["link"]["type"], "symlink")
            self.assertEqual(tree["link"]["target"], "file.txt")

    def test_sandbox_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            with self.assertRaises(ValueError):
                materialize({"files": {"../escape": "x"}}, os.path.join(tmp, "sandbox"))
            with self.assertRaises(ValueError):
                materialize({"files": {"/etc/passwd": "x"}}, os.path.join(tmp, "sandbox"))

    def test_sandbox_rejects_symlink_parent(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            root = os.path.join(tmp, "sandbox")
            materialize({"symlinks": {"escape": "/tmp"}}, root)
            with self.assertRaises(ValueError):
                materialize({"files": {"escape/pwned": "x"}}, root)

    def test_tmp_path_is_normalized_globally(self):
        root = os.path.join(SCRATCH, "example-sandbox")
        text = "cwd=" + root + "/sub/file\n"
        # tmp_path is applied even though it is not in the rules list.
        self.assertEqual(normalize_apply(text, [], root=root), "cwd=<TMP>/sub/file\n")

    def test_pid_and_timestamp_rules(self):
        text = "pid=1234 at 2026-11-21 12:00:00"
        self.assertEqual(
            normalize_apply(text, ["pid", "timestamp"], root="/x"),
            "pid=<PID> at <TIMESTAMP>",
        )

    def test_sort_lines_rule(self):
        self.assertEqual(normalize_apply("b\na\n", ["sort_lines"], root="/x"), "a\nb\n")

    def test_skip_without_requires_is_error(self):
        self.assertEqual(skip_decision([], "no tty").status, "error")
        skipped = skip_decision(["tty"], "no tty")
        self.assertEqual(skipped.status, "skip")
        self.assertIn("tty", skipped.diff)
        self.assertIn("no tty", skipped.reason)

    @unittest.skipUnless(os.path.exists("/dev/ptmx"), "no pseudo-terminal available")
    def test_pty_helper(self):
        from scripts.parity.pty import run_pty

        out, code = run_pty(
            [sys.executable, "-u", "-c", "print('pty-ok')"],
            [],
            timeout=5.0,
        )
        self.assertEqual(code, 0, out)
        self.assertIn("pty-ok", out)

    def test_ns_helper_contract(self):
        from scripts.parity.ns import NsUnavailable, run_ns

        # The helper either returns a CompletedProcess or raises a well-formed
        # capability error.  It must never silently skip.
        try:
            proc = run_ns("uts", [sys.executable, "-c", "pass"], timeout=10)
        except NsUnavailable as exc:
            self.assertTrue(str(exc))
            return
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_unknown_normalization_is_harness_error(self):
        with self.assertRaises(ValueError):
            normalize_apply("x", ["bogus"], root="/x")

    def test_unmet_capability_becomes_skip_when_declared(self):
        # "disk"/"service" are never available, like a reference built with
        # CONFIG_TC=n.  A case must declare the requirement to get a SKIP.
        from scripts.parity.run import unmet_requirements

        unmet = unmet_requirements(["disk", "service"], ref=None)
        self.assertEqual([token for token, _ in unmet], ["disk", "service"])
        skipped = skip_decision(["disk"], "; ".join(reason for _, reason in unmet))
        self.assertEqual(skipped.status, "skip")


if __name__ == "__main__":
    unittest.main()
