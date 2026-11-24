"""Fixture test for the applet manifest extractor (Task 1)."""

import os
import unittest

from scripts.parity.extract_manifest import extract

FIXTURES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))),
    "scripts",
    "parity",
    "fixtures",
)


class ExtractManifestTest(unittest.TestCase):
    def test_parses_all_applet_kinds(self):
        entries = extract(
            os.path.join(FIXTURES, "applets.h"),
            os.path.join(FIXTURES, ".config"),
        )
        assert [e["name"] for e in entries] == ["cat", "bzcat", "ls", "clear", "sh", "busybox"]
        assert entries[1]["main"] == "bunzip2"
        assert entries[2]["noexec"] is True
        assert entries[3]["nofork"] is True
        assert entries[4]["scripted"] is True
        assert entries[5]["suid"] == "maybe"
        assert "e2label" not in [e["name"] for e in entries]


if __name__ == "__main__":
    unittest.main()
