#!/usr/bin/env python3
"""Generate the Zig config module from a BusyBox defconfig.

The committed ``configs/defconfig`` is the authority. Every ``CONFIG_*``
assignment becomes a Zig constant (``y``/``n`` -> bool, integers -> integers,
quoted strings -> escaped Zig strings); ``# CONFIG_X is not set`` becomes
``false``. Applet aliases come from ``tests/parity/manifest.json`` and keep the
``@import("config").config`` namespace working for existing consumers.

``--check`` regenerates in memory and compares with the committed output; this
is the CI freshness gate. ``-Dconfig=path`` in build.zig selects the input.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import OrderedDict
from typing import Any

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

DEFAULT_CONFIG = os.path.join(REPO_ROOT, "configs", "defconfig")
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "tests", "parity", "manifest.json")
DEFAULT_APPLETS = os.path.join(REPO_ROOT, "src", "applets.zig")
DEFAULT_OUT = os.path.join(REPO_ROOT, "src", "config.zig")

REF_COMMIT = "6412da255d465be1f1860ae109ccbf2564810af2"

ASSIGN_RE = re.compile(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$")
UNSET_RE = re.compile(r"^# CONFIG_([A-Za-z0-9_]+) is not set$")
INTEGER_RE = re.compile(r"^-?[0-9]+$")
PUTIF_RE = re.compile(r'putIfEnabled\(\s*map\s*,\s*"([^"]+)"')
DIRECT_REF_RE = re.compile(r"\bconfig\.APPLET_([A-Za-z0-9_]+)")


def zig_string(value: str) -> str:
    """Render a quoted config value as a Zig string literal."""
    out = ['"']
    for ch in value:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif 32 <= ord(ch) < 127:
            out.append(ch)
        else:
            out.append("\\x%02x" % (ord(ch) & 0xFF))
    out.append('"')
    return "".join(out)


def value_literal(raw: str) -> str:
    """Convert the right-hand side of a CONFIG_ assignment to a Zig literal."""
    if raw == "y":
        return "true"
    if raw == "n":
        return "false"
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        return zig_string(raw[1:-1])
    if INTEGER_RE.match(raw):
        return raw
    # Kconfig can also use hex (0x...) and single-quoted values; be defensive
    # and emit a Zig string rather than failing on an exotic defconfig.
    return zig_string(raw)


def parse_config(text: str) -> "OrderedDict[str, str]":
    """Parse defconfig text into an ordered SYMBOL -> Zig literal mapping."""
    symbols: "OrderedDict[str, str]" = OrderedDict()
    for line in text.splitlines():
        m = ASSIGN_RE.match(line)
        if m:
            symbols[m.group(1)] = value_literal(m.group(2))
            continue
        m = UNSET_RE.match(line)
        if m:
            symbols[m.group(1)] = "false"
    return symbols


def applet_ident(name: str) -> str:
    """Map an applet name to a valid Zig identifier suffix.

    A few BusyBox names contain '-', '.' or '[' (e.g. 'ether-wake', '[',
    'fsck.minix'); those characters are replaced with '_' exactly as the
    existing registry does.
    """
    ident = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if not ident or ident[0].isdigit():
        ident = "_" + ident
    return ident


def registry_names(applets_path: str | None) -> list[str]:
    """Field names existing consumers look up via @field(config, ...)."""
    names: list[str] = []
    if applets_path and os.path.exists(applets_path):
        with open(applets_path, encoding="utf-8") as fh:
            text = fh.read()
        names.extend(PUTIF_RE.findall(text))
        if DIRECT_REF_RE.search(text):
            names.extend(DIRECT_REF_RE.findall(text))
    # Deduplicate deterministically.
    return list(OrderedDict.fromkeys(names))


def generate(
    config_text: str,
    entries: list[dict[str, Any]],
    applets_path: str | None = None,
) -> str:
    """Render the complete src/config.zig for the given defconfig and applets."""
    symbols = parse_config(config_text)

    aliases: list[tuple[str, str]] = []
    alias_by_ident: dict[str, str] = {}
    for entry in entries:
        ident = applet_ident(entry["name"])
        flag = entry["config"]
        if not flag.startswith("CONFIG_"):
            raise ValueError("applet %s has invalid config flag %s" % (entry["name"], flag))
        symbol = flag[len("CONFIG_") :]
        if symbol not in symbols:
            raise ValueError("config symbol %s (applet %s) missing from defconfig" % (flag, entry["name"]))
        if ident in alias_by_ident:
            raise ValueError("applet alias collision: %s" % ident)
        alias_by_ident[ident] = flag
        aliases.append((ident, flag))

    assigned = [m for line in config_text.splitlines() if (m := ASSIGN_RE.match(line))]
    unset_count = sum(1 for line in config_text.splitlines() if UNSET_RE.match(line))
    bool_count = sum(1 for m in assigned if m.group(2) in ("y", "n"))
    value_count = len(assigned) - bool_count

    lines = [
        "// Generated by scripts/parity/gen_config.py - DO NOT EDIT.",
        "// BusyBox reference commit " + REF_COMMIT + ".",
        "// Source: defconfig -- %d set symbols (%d boolean + %d value)" % (len(assigned), bool_count, value_count),
        "// plus %d \"is not set\" symbols emitted as false (%d constants total)." % (unset_count, len(symbols)),
        "// Regenerate with `zig build gen-config`.",
        "",
        "// === Config symbols ===",
    ]
    for symbol, literal in symbols.items():
        lines.append("pub const CONFIG_%s = %s;" % (symbol, literal))

    lines.extend(["", "// === Applet aliases ==="])
    for ident, flag in aliases:
        lines.append("pub const APPLET_%s = %s;" % (ident, flag))

    # Compatibility: existing code imports @import("config").config and reads
    # @field(config, "APPLET_" ++ name). Re-export the aliases there. Registry
    # names that predate the manifest (TLS internals, shell variants, etc.)
    # were unconditionally enabled in the old hand-written config; keep them on.
    lines.extend(
        [
            "",
            "// === Compatibility namespace for @import(\"config\").config ===",
            "pub const config = struct {",
        ]
    )
    needed = registry_names(applets_path) or sorted(alias_by_ident)
    for name in needed:
        if name in alias_by_ident:
            # Reference the CONFIG_ symbol directly: referring to the top-level
            # APPLET_ alias here would be ambiguous with the field name itself.
            lines.append("    pub const APPLET_%s = %s;" % (name, alias_by_ident[name]))
        else:
            lines.append("    pub const APPLET_%s = true;" % name)
    lines.extend(["};", ""])
    return "\n".join(lines)


def _write(path: str, text: str) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote " + path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="input defconfig")
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, help="applet manifest.json")
    parser.add_argument("--applets", default=DEFAULT_APPLETS, help="src/applets.zig (registry names)")
    parser.add_argument("--out", default=DEFAULT_OUT, help="generated Zig config")
    parser.add_argument("--check", action="store_true", help="fail if the committed output is stale")
    args = parser.parse_args(argv)

    with open(args.config, encoding="utf-8") as fh:
        config_text = fh.read()
    with open(args.manifest, encoding="utf-8") as fh:
        entries = json.load(fh)["entries"]

    text = generate(config_text, entries, args.applets)

    if args.check:
        if not os.path.exists(args.out):
            print("missing " + args.out, file=sys.stderr)
            return 1
        with open(args.out, encoding="utf-8") as fh:
            if fh.read() != text:
                print("%s is stale; run `zig build gen-config`" % args.out, file=sys.stderr)
                return 1
        print("config in sync: %d symbols, %d applets" % (len(parse_config(config_text)), len(entries)))
        return 0

    _write(args.out, text)
    print("generated %d config symbols and %d applet aliases" % (len(parse_config(config_text)), len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
