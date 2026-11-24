#!/usr/bin/env python3
"""Extract the single source of truth for BusyBox applets.

Inputs are the generated ``include/applets.h`` and ``.config`` of the pinned
BusyBox 1.39.0 reference, plus ``tests/parity/categories.json`` (built from the
committed parity matrix). Outputs are the Zig manifest, its JSON mirror and the
regenerated parity matrix.

``--check`` validates a reference tree; ``--check-json`` validates that the
committed Zig manifest still matches the committed JSON without needing the
reference tree (this is the CI freshness gate).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

DEFAULT_MATRIX = os.path.join(
    REPO_ROOT, "docs", "superpowers", "specs", "2026-11-21-busybox-parity-matrix.md"
)
DEFAULT_CATEGORIES = os.path.join(REPO_ROOT, "tests", "parity", "categories.json")
DEFAULT_JSON = os.path.join(REPO_ROOT, "tests", "parity", "manifest.json")
DEFAULT_ZIG = os.path.join(REPO_ROOT, "src", "generated", "applet_manifest.zig")

REF_COMMIT = "6412da255d465be1f1860ae109ccbf2564810af2"
EXPECTED_APPLETS = 443
# Binding ruling (Task 3 / ledger): the reference `busybox` applet is wrapped
# in IF_FEATURE_SH_STANDALONE(IF_FEATURE_TAB_COMPLETION(...)) and defconfig has
# FEATURE_SH_STANDALONE=n. Counting only outer APPLET_* flags gives 412; the
# true default-enabled registry (and reference --list) is 411.  The manifest's
# `default_enabled` field intentionally keeps the outer-flag count (412);
# check_reference() applies the extra gate before comparing against 411.
EXPECTED_DEFAULT_ENABLED = 411
EXPECTED_CONFIG_SYMBOLS = 946

APPLET_RE = re.compile(r"\b(APPLET(?:_ODDNAME|_NOEXEC|_NOFORK|_SCRIPTED)?)\s*\(")
IF_RE = re.compile(r"\bIF_([A-Z0-9_]+)\s*\(")
CONFIG_Y_RE = re.compile(r"^CONFIG_([A-Z0-9_]+)=y\s*$")
CONFIG_N_RE = re.compile(r"^# CONFIG_([A-Z0-9_]+) is not set\s*$")
MATRIX_ROW_RE = re.compile(
    r"^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|\s*`([^`]+)`\s*\|\s*"
    # The busybox row documents its extra gate as
    # "CONFIG_BUSYBOX (+FEATURE_SH_STANDALONE)"; read_matrix strips it.
    r"(CONFIG_[A-Z0-9_]+(?:\s*\([^)]*\))?)\s*\|\s*(yes|no)\s*\|\s*([^|]+?)\s*\|\s*"
    r"([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$"
)

LOCATIONS = {
    "BB_DIR_ROOT": "root",
    "BB_DIR_BIN": "bin",
    "BB_DIR_SBIN": "sbin",
    "BB_DIR_USR_BIN": "usr/bin",
    "BB_DIR_USR_SBIN": "usr/sbin",
}
SUIDS = {"BB_SUID_DROP": "drop", "BB_SUID_REQUIRE": "require", "BB_SUID_MAYBE": "maybe"}


def read_config(path: str) -> dict[str, bool]:
    """Return the set of config symbols explicitly set to y or explicitly unset."""
    config: dict[str, bool] = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = CONFIG_Y_RE.match(line)
            if m:
                config[m.group(1)] = True
                continue
            m = CONFIG_N_RE.match(line)
            if m:
                config[m.group(1)] = False
    return config


def _satisfied(flag: str, config: dict[str, bool]) -> bool:
    """Evaluate an IF_ flag; IF_NOT_X is the negation of CONFIG_X."""
    if flag.startswith("NOT_"):
        return not config.get(flag[4:], False)
    return config.get(flag, False)


def _resolve_conditionals(text: str, config: dict[str, bool]) -> str:
    """Collapse IF_X(...) / IF_NOT_X(...) wrappers inside a macro argument."""
    for _ in range(16):
        m = IF_RE.search(text)
        if not m:
            break
        depth = 1
        i = m.end()
        while i < len(text) and depth:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
            i += 1
        if depth:
            raise ValueError("unbalanced IF_ expression: " + text)
        inner = text[m.end() : i - 1]
        replacement = inner if _satisfied(m.group(1), config) else ""
        text = text[: m.start()] + replacement + text[i:]
    text = re.sub(r"\s+", " ", text).strip()
    if IF_RE.search(text):
        raise ValueError("too many nested IF_ expressions: " + text)
    return text


def _split_args(text: str) -> list[str]:
    """Split a macro argument list on top-level commas."""
    args: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in text:
        if ch == "(":
            depth += 1
            cur.append(ch)
        elif ch == ")":
            if depth == 0:
                args.append("".join(cur).strip())
                break
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    return args


def _load_categories(path: str | None) -> dict[str, str]:
    if path is None or not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("categories file must be a JSON object")
    return data


def extract(
    applets_path: str,
    config_path: str,
    categories_path: str | None = None,
) -> list[dict[str, Any]]:
    """Parse generated applets.h into one entry per applet name.

    Mutually exclusive variants (sh/modprobe/bash aliases) share a name: the
    variant enabled by the defconfig wins, otherwise the first one is kept.
    Entries are returned in applets.h order.
    """
    config = read_config(config_path)
    categories = _load_categories(categories_path)

    found: dict[str, dict[str, Any]] = {}
    active: dict[str, bool] = {}
    order: list[str] = []
    with open(applets_path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            # Comments, macro definitions and //TODO / //applet: lines are inert.
            if not line or line.startswith(("#", "/*", "*", "*/", "//")):
                continue
            line = line.split("//", 1)[0].strip()
            m = APPLET_RE.search(line)
            if not m:
                continue
            macro = m.group(1)
            flags = [f.group(1) for f in IF_RE.finditer(line[: m.start()])]
            args = _split_args(line[m.end() :])
            if len(args) < (3 if macro == "APPLET" else 4):
                raise ValueError("malformed applet line: " + raw.rstrip())

            if macro == "APPLET":
                name, main, location, suid = args[0], args[0], args[1], args[2]
            else:
                name, main, location, suid = args[0], args[1], args[2], args[3]

            name = _resolve_conditionals(name, config)
            main = _resolve_conditionals(main, config)
            location = LOCATIONS[_resolve_conditionals(location, config)]
            suid = SUIDS[_resolve_conditionals(suid, config)]

            outer = flags[0] if flags else ""
            entry: dict[str, Any] = {
                "name": name,
                "main": main,
                "category": categories.get(name, categories.get(main, "")),
                "config": "CONFIG_" + outer,
                "default_enabled": outer in config and config[outer],
                "location": location,
                "suid": suid,
                "noexec": macro == "APPLET_NOEXEC",
                "nofork": macro == "APPLET_NOFORK",
                "scripted": macro == "APPLET_SCRIPTED",
            }
            is_active = bool(flags) and all(_satisfied(f, config) for f in flags)
            if name not in found:
                found[name] = entry
                active[name] = is_active
                order.append(name)
            elif is_active and not active[name]:
                found[name] = entry
                active[name] = True
    return [found[name] for name in order]


def _sorted(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(entries, key=lambda e: (e["category"], e["name"]))


def read_matrix(path: str) -> list[dict[str, str]]:
    """Read the committed matrix rows, preserving status and our-flag columns."""
    rows: list[dict[str, str]] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = MATRIX_ROW_RE.match(line)
            if m:
                rows.append(
                    {
                        "num": m.group(1),
                        "category": m.group(2),
                        "name": m.group(3),
                        # Strip the human-readable extra-gate annotation so
                        # cross-checking compares the bare CONFIG symbol.
                        "config": m.group(4).split("(", 1)[0].strip(),
                        "default": m.group(5),
                        "location": m.group(6),
                        "suid": m.group(7),
                        "status": m.group(8),
                        "our_flag": m.group(9),
                    }
                )
    return rows


def categories_from_matrix(rows: list[dict[str, str]]) -> dict[str, str]:
    return {row["name"]: row["category"] for row in rows}


def _cross_check(
    entries: list[dict[str, Any]],
    rows: list[dict[str, str]],
    config: dict[str, bool] | None = None,
) -> list[str]:
    """Compare reference-derived fields with the authoritative committed matrix."""
    problems: list[str] = []
    by_name = {row["name"]: row for row in rows}
    config = config or {}
    gate_open = bool(config.get("FEATURE_SH_STANDALONE")) and bool(
        config.get("FEATURE_TAB_COMPLETION")
    )
    if len(rows) != len(entries):
        problems.append("matrix has %d rows, reference has %d" % (len(rows), len(entries)))
    for e in entries:
        row = by_name.get(e["name"])
        if row is None:
            problems.append("matrix is missing " + e["name"])
            continue
        expected = (
            row["category"],
            row["config"],
            row["default"],
            row["location"],
            row["suid"],
        )
        default = "yes" if e["default_enabled"] else "no"
        if e["name"] == "busybox" and default == "yes" and not gate_open:
            # The matrix records the registry-visible default (no), not the
            # outer APPLET_BUSYBOX flag (yes).  See EXPECTED_DEFAULT_ENABLED.
            default = "no"
        actual = (
            e["category"],
            e["config"],
            default,
            e["location"],
            e["suid"],
        )
        if expected != actual:
            problems.append("%s: matrix=%s reference=%s" % (e["name"], expected, actual))
    return problems


def _counts(entries: list[dict[str, Any]]) -> dict[str, int]:
    return {
        "applets": len(entries),
        "default_enabled": sum(1 for e in entries if e["default_enabled"]),
    }


def _zig_string(value: str) -> str:
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
            out.append("\\x%02x" % ord(ch))
    out.append('"')
    return "".join(out)


def render_zig(entries: list[dict[str, Any]], counts: dict[str, int]) -> str:
    lines = [
        "// Generated by scripts/parity/extract_manifest.py - do not edit.",
        "// BusyBox reference commit " + REF_COMMIT + ".",
        "",
        "const std = @import(\"std\");",
        "",
        "pub const Suid = enum { drop, require, maybe };",
        "",
        "pub const Entry = struct {",
        "    name: []const u8,",
        "    main: []const u8,",
        "    category: []const u8,",
        "    config: []const u8,",
        "    default_enabled: bool,",
        "    location: []const u8,",
        "    suid: Suid,",
        "    noexec: bool = false,",
        "    nofork: bool = false,",
        "    scripted: bool = false,",
        "};",
        "",
        "pub const entries = [_]Entry{",
    ]
    for e in _sorted(entries):
        lines.extend(
            [
                "    .{",
                "        .name = %s," % _zig_string(e["name"]),
                "        .main = %s," % _zig_string(e["main"]),
                "        .category = %s," % _zig_string(e["category"]),
                "        .config = %s," % _zig_string(e["config"]),
                "        .default_enabled = %s," % ("true" if e["default_enabled"] else "false"),
                "        .location = %s," % _zig_string(e["location"]),
                "        .suid = .%s," % e["suid"],
            ]
        )
        for flag in ("noexec", "nofork", "scripted"):
            if e[flag]:
                lines.append("        .%s = true," % flag)
        lines.append("    },")
    lines.extend(
        [
            "};",
            "",
            "test \"applet manifest is complete\" {",
            "    try std.testing.expectEqual(@as(usize, %d), entries.len);" % counts["applets"],
            "    var enabled: usize = 0;",
            "    for (entries) |entry| {",
            "        if (entry.default_enabled) enabled += 1;",
            "    }",
            "    try std.testing.expectEqual(@as(usize, %d), enabled);" % counts["default_enabled"],
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def _json_document(entries: list[dict[str, Any]], counts: dict[str, int]) -> dict[str, Any]:
    return {
        "reference_commit": REF_COMMIT,
        "counts": {
            "applets": counts["applets"],
            "default_enabled": counts["default_enabled"],
            "config_symbols": counts.get("config_symbols", EXPECTED_CONFIG_SYMBOLS),
        },
        "entries": _sorted(entries),
    }


def render_matrix(
    entries: list[dict[str, Any]], old_rows: list[dict[str, str]], old_text: str
) -> str:
    old_by_name = {row["name"]: row for row in old_rows}
    totals_tail: list[str] = []
    seen_totals = False
    for line in old_text.splitlines():
        if seen_totals and line.startswith("- ") and "Zig registry" in line:
            totals_tail.append(line)
        if line.strip() == "## Totals":
            seen_totals = True

    lines = [
        "# BusyBox 1.39.0 — Parity Matrix",
        "",
        "Generated from `reference/busybox` at commit `%s` (`1.39.0.git`) and its generated `include/applets.h`."
        % REF_COMMIT,
        "Status: `missing` = not in the Zig registry; `stub` = registered but returns \"not implemented\"; `partial` = has an implementation that has not passed the parity audit.",
        "",
        "| # | Category | Applet | Config flag | Default | Location | SUID | Zig status | Our flag |",
        "|---:|---|---|---|---|---|---|---|---|",
    ]
    counts = _counts(entries)
    for i, e in enumerate(_sorted(entries), 1):
        old = old_by_name.get(e["name"], {})
        lines.append(
            "| %d | %s | `%s` | %s | %s | %s | %s | %s | %s |"
            % (
                i,
                e["category"],
                e["name"],
                e["config"],
                "yes" if e["default_enabled"] else "no",
                e["location"],
                e["suid"],
                old.get("status", "missing"),
                old.get("our_flag", "—"),
            )
        )
    lines.extend(
        [
            "",
            "## Totals",
            "",
            "- Reference applet names: **%d**" % counts["applets"],
            "- Default-enabled in reference defconfig: **%d**" % counts["default_enabled"],
            *totals_tail,
            "",
        ]
    )
    return "\n".join(lines)


def _write(path: str, text: str) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote " + path)


def _ref_paths(ref: str) -> tuple[str, str]:
    return os.path.join(ref, "include", "applets.h"), os.path.join(ref, ".config")


def _ref_entries(ref: str) -> tuple[list[dict[str, Any]], dict[str, bool], int]:
    applets_h, config_path = _ref_paths(ref)
    if not os.path.exists(applets_h) or not os.path.exists(config_path):
        raise FileNotFoundError("reference not present at " + ref)
    with open(config_path, encoding="utf-8") as fh:
        symbols = sum(1 for line in fh if line.startswith("CONFIG_"))
    return (
        extract(applets_h, config_path, DEFAULT_CATEGORIES),
        read_config(config_path),
        symbols,
    )


def check_reference(ref: str) -> int:
    applets_h, config_path = _ref_paths(ref)
    if not os.path.exists(applets_h) or not os.path.exists(config_path):
        print("SKIP: reference not present")
        return 0
    entries, _, symbols = _ref_entries(ref)
    counts = _counts(entries)
    config = read_config(config_path)
    rows = read_matrix(DEFAULT_MATRIX)
    problems = _cross_check(entries, rows, config)
    if counts["applets"] != EXPECTED_APPLETS:
        problems.append("expected %d applets, got %d" % (EXPECTED_APPLETS, counts["applets"]))
    # `default_enabled` counts outer APPLET_* flags.  The registry additionally
    # gates `busybox` behind FEATURE_SH_STANDALONE && FEATURE_TAB_COMPLETION.
    registry_default = counts["default_enabled"]
    busybox_enabled = any(
        e["name"] == "busybox" and e["default_enabled"] for e in entries
    )
    gate_open = bool(config.get("FEATURE_SH_STANDALONE")) and bool(
        config.get("FEATURE_TAB_COMPLETION")
    )
    if busybox_enabled and not gate_open:
        registry_default -= 1
    if registry_default != EXPECTED_DEFAULT_ENABLED:
        problems.append(
            "expected %d default-enabled in the registry, got %d (outer flags: %d)"
            % (EXPECTED_DEFAULT_ENABLED, registry_default, counts["default_enabled"])
        )
    if symbols != EXPECTED_CONFIG_SYMBOLS:
        problems.append("expected %d config symbols, got %d" % (EXPECTED_CONFIG_SYMBOLS, symbols))
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    print("%d applets, %d default-enabled in registry (%d outer flags)" % (
        counts["applets"], registry_default, counts["default_enabled"]))
    return 0


def check_json() -> int:
    with open(DEFAULT_JSON, encoding="utf-8") as fh:
        doc = json.load(fh)
    entries = doc["entries"]
    counts = _counts(entries)
    expected = doc.get("counts", {})
    problems: list[str] = []
    for key in ("applets", "default_enabled"):
        if expected.get(key) != counts[key]:
            problems.append("counts.%s: got %d, declared %s" % (key, counts[key], expected.get(key)))
    if expected.get("config_symbols") != EXPECTED_CONFIG_SYMBOLS:
        problems.append(
            "counts.config_symbols: declared %s, expected %d"
            % (expected.get("config_symbols"), EXPECTED_CONFIG_SYMBOLS)
        )
    if counts["applets"] != EXPECTED_APPLETS:
        problems.append("expected %d entries, got %d" % (EXPECTED_APPLETS, counts["applets"]))
    with open(DEFAULT_ZIG, encoding="utf-8") as fh:
        committed = fh.read()
    if committed != render_zig(entries, counts):
        problems.append("src/generated/applet_manifest.zig is stale; run the manifest generator")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    print("manifest.json and applet_manifest.zig are in sync (%d entries)" % counts["applets"])
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="reference build dir containing .config and include/applets.h")
    parser.add_argument("--out-src", help="write the generated Zig manifest")
    parser.add_argument("--out-json", help="write the JSON mirror of the manifest")
    parser.add_argument("--out-matrix", help="regenerate the parity matrix")
    parser.add_argument("--out-categories", help="write categories.json from the committed matrix")
    parser.add_argument("--check", action="store_true", help="validate the reference tree")
    parser.add_argument("--check-json", action="store_true", help="validate committed artifacts")
    args = parser.parse_args(argv)

    actions = (
        args.out_src,
        args.out_json,
        args.out_matrix,
        args.out_categories,
        args.check,
        args.check_json,
    )
    if not any(actions):
        parser.error("nothing to do: pass an output path or a check flag")
    if (args.out_src or args.out_json or args.out_matrix) and not args.ref:
        parser.error("--ref is required when generating the manifest")

    if args.check_json and check_json() != 0:
        return 1

    if args.check:
        # The brief's default reference location is absent in this worktree;
        # check_reference prints an explicit SKIP rather than failing there.
        if check_reference(args.ref or os.path.join(REPO_ROOT, "reference", "busybox")) != 0:
            return 1

    if args.out_categories:
        _write(
            args.out_categories,
            json.dumps(
                categories_from_matrix(read_matrix(DEFAULT_MATRIX)),
                indent=2,
                sort_keys=True,
                ensure_ascii=False,
            )
            + "\n",
        )

    if args.out_src or args.out_json or args.out_matrix:
        entries, _, symbols = _ref_entries(args.ref)
        rows = read_matrix(DEFAULT_MATRIX)
        config = read_config(os.path.join(args.ref, ".config"))
        problems = _cross_check(entries, rows, config)
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 1
        counts = _counts(entries)
        counts["config_symbols"] = symbols
        if args.out_json:
            _write(args.out_json, json.dumps(_json_document(entries, counts), indent=2, ensure_ascii=False) + "\n")
        if args.out_src:
            _write(args.out_src, render_zig(entries, counts))
        if args.out_matrix:
            with open(DEFAULT_MATRIX, encoding="utf-8") as fh:
                old_text = fh.read()
            _write(args.out_matrix, render_matrix(entries, rows, old_text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
