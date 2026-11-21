"""Fixture test for the defconfig -> Zig config generator (Task 2)."""

import os
import unittest

from scripts.parity.gen_config import generate

FIXTURE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))),
    "scripts",
    "parity",
    "fixtures",
    "config.sample",
)


class GenConfigTest(unittest.TestCase):
    def test_generates_symbols_and_applet_aliases(self):
        with open(FIXTURE, encoding="utf-8") as fh:
            config_text = fh.read()
        entries = [
            {"name": "cat", "config": "CONFIG_CAT"},
            {"name": "ls", "config": "CONFIG_LS"},
        ]
        out = generate(config_text, entries)
        self.assertIn("pub const CONFIG_CAT = true;", out)
        self.assertIn("pub const CONFIG_LS = false;", out)
        self.assertIn('pub const CONFIG_DHCPC_DEFAULT_SCRIPT = "/usr/share/udhcpc/default.script";', out)
        self.assertIn("pub const CONFIG_FEATURE_SYSLOGD_READ_BUFFER_SIZE = 256;", out)
        self.assertIn("pub const APPLET_cat = CONFIG_CAT;", out)
        self.assertIn("pub const APPLET_ls = CONFIG_LS;", out)


if __name__ == "__main__":
    unittest.main()
