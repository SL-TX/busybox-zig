"""Unit tests for the reference usage extractor (Task 4).

These tests exercise the pure rendering helpers with tiny in-memory inputs so
they need neither the reference binary nor a C compiler.
"""

import os
import tempfile
import textwrap
import unittest

from scripts.parity.extract_usage import (
    compose_body,
    eval_condition,
    eval_usage_expr,
    load_config,
    load_manifest,
    parse_macros,
    render_source_usage,
    resolve_conditionals,
    usage_lines,
    zig_string,
)


class ExtractUsageTest(unittest.TestCase):
    def test_load_manifest_and_config(self):
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
        names = load_manifest(os.path.join(root, "tests", "parity", "manifest.json"))
        self.assertEqual(len(names), 443)
        self.assertTrue(names[0] < names[1])
        self.assertIn("cat", names)
        self.assertIn("[", names)
        cfg = load_config(os.path.join(root, "configs", "defconfig"))
        self.assertEqual(cfg["CONFIG_CAT"], "y")
        self.assertEqual(cfg["CONFIG_AR"], "n")
        self.assertEqual(cfg["CONFIG_TC"], "y")

    def test_eval_condition(self):
        cfg = {"CONFIG_A": "y", "CONFIG_B": "n"}
        self.assertTrue(eval_condition("ENABLE_A", cfg))
        self.assertFalse(eval_condition("ENABLE_B", cfg))
        self.assertTrue(eval_condition("ENABLE_A || ENABLE_B", cfg))
        self.assertFalse(eval_condition("ENABLE_A && ENABLE_B", cfg))
        self.assertTrue(eval_condition("!ENABLE_B", cfg))

    def test_eval_usage_expr_expands_if_and_escapes(self):
        cfg = {"CONFIG_FEATURE_X": "y", "CONFIG_FEATURE_Y": "n"}
        expr = '"A\\n" IF_FEATURE_X("x|")IF_NOT_FEATURE_Y("y") "Z\\t"'
        self.assertEqual(eval_usage_expr(expr, cfg), "A\nx|yZ\t")
        self.assertEqual(eval_usage_expr("NOUSAGE_STR", cfg), "\b")

    def test_resolve_conditionals_and_macros(self):
        cfg = {"CONFIG_FEATURE_X": "y"}
        block = [
            "#if ENABLE_FEATURE_X",
            '#define foo_trivial_usage "x|"',
            "#else",
            '#define foo_trivial_usage "plain"',
            "#endif",
            '#define foo_full_usage "\\n\\nDesc"',
            '  " line"',
        ]
        macros = parse_macros(resolve_conditionals(block, cfg))
        self.assertEqual(macros["foo_trivial_usage"], '"x|"')
        self.assertEqual(macros["foo_full_usage"], '"\\n\\nDesc"" line"')

    def test_compose_body_matches_show_usage(self):
        self.assertEqual(compose_body("cat", "[-n] FILE\n\nDesc"), b"\nUsage: cat [-n] FILE\n\nDesc\n")
        # A leading newline suppresses the space after the applet name.
        self.assertEqual(compose_body("bbconfig", "\n\nPrint config"), b"\nUsage: bbconfig\n\nPrint config\n")
        self.assertEqual(compose_body("test", "\b"), b"\nNo help available\n")

    def test_source_fallback_renders_alias_and_conditionals(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "net"))
            src = os.path.join(tmp, "net", "nc.c")
            with open(src, "w", encoding="utf-8") as fh:
                fh.write(textwrap.dedent(
                    """\
                    //applet:IF_NETCAT(APPLET_ODDNAME(netcat, nc, BB_DIR_USR_BIN, BB_SUID_DROP, nc))
                    //usage:#define nc_trivial_usage
                    //usage:       "[-v] HOST PORT"
                    //usage:#define nc_full_usage "\\n\\n"
                    //usage:       "Netcat "\\ IF_LONG_OPTS("long ") "clone"
                    //usage:
                    //usage:#define nc_example_usage
                    //usage:       "$ nc localhost 80"
                    """
                ))
            cfg = {"CONFIG_LONG_OPTS": "y"}
            self.assertEqual(render_source_usage(tmp, cfg, "netcat"), "[-v] HOST PORT\n\nNetcat long clone")
            cfg["CONFIG_LONG_OPTS"] = "n"
            self.assertEqual(render_source_usage(tmp, cfg, "netcat"), "[-v] HOST PORT\n\nNetcat clone")
            self.assertIsNotNone(usage_lines(tmp, "nc"))

    def test_zig_string_escapes(self):
        self.assertEqual(zig_string(b'a"b\\c\n\t\x01'), '"a\\"b\\\\c\\n\\t\\x01"')


if __name__ == "__main__":
    unittest.main()
