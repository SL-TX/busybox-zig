#!/usr/bin/env python3
"""Capture exact per-applet ``APPLET --help`` usage text from the reference.

For every name in the generated applet manifest the script runs::

    busybox --help <applet>

and stores everything after the reference banner line in
``tests/parity/usage/<applet>.txt``.  The banner itself lives in the committed
meta golden (``src/generated/meta.zig``); only the body is duplicated here so a
new reference build with a different timestamp does not invalidate the usage
goldens.

A handful of applets are compiled out of the comparison reference build (for
example ``tc`` with ``CONFIG_TC=n``, ``unit``, SELinux helpers and old aliases).
For those the script falls back to the reference ``//usage:`` comments in the
BusyBox source tree, evaluates the Kconfig conditionals against our defconfig
and renders the same string ``bb_show_usage()`` would print.  Fallback names are
recorded in ``tests/parity/usage_fallback.json`` and in the generated Zig file.

When no usable ``--ref`` binary is available (or ``--ref`` is omitted entirely)
the script works offline: the committed ``tests/parity/usage/*.txt`` files become
the source of truth and only the generated Zig module and fallback metadata are
rebuilt.  ``--check`` works in both modes and never needs the binary.

Regenerate from a reference build::

    python3 scripts/parity/extract_usage.py \\
        --ref /tmp/opencode/bb-ref2/busybox \\
        --src /home/sl/OpenCodeProjects/busybox-zig/reference/busybox

Regenerate offline from the committed goldens::

    python3 scripts/parity/extract_usage.py
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# --ref deliberately has no default: omitting it selects the offline mode that
# reads the committed goldens instead of assuming a machine-specific binary path.
DEFAULT_SRC = "/home/sl/OpenCodeProjects/busybox-zig/reference/busybox"
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "tests", "parity", "manifest.json")
DEFAULT_DEFCONFIG = os.path.join(REPO_ROOT, "configs", "defconfig")
DEFAULT_GOLDEN_DIR = os.path.join(REPO_ROOT, "tests", "parity", "usage")
DEFAULT_FALLBACK = os.path.join(REPO_ROOT, "tests", "parity", "usage_fallback.json")
DEFAULT_ZIG = os.path.join(REPO_ROOT, "src", "generated", "usage.zig")

MULTI_CALL_SUFFIX = b" multi-call binary.\n"
NO_HELP = b"\nNo help available\n"


# --------------------------------------------------------------------------- #
# Inputs
# --------------------------------------------------------------------------- #

def load_manifest(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return sorted(e["name"] for e in data["entries"])


def load_config(path: str) -> dict[str, str]:
    """Return ``CONFIG_* -> 'y' | 'n' | value`` from a (def)config file."""
    cfg: dict[str, str] = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            m = re.match(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$", line)
            if m:
                cfg[m.group(1)] = m.group(2)
                continue
            m = re.match(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$", line)
            if m:
                cfg[m.group(1)] = "n"
    return cfg


def load_goldens(golden_dir: str, names: list[str]) -> dict[str, bytes]:
    """Read every committed usage body; this is the offline source of truth."""
    bodies: dict[str, bytes] = {}
    for name in names:
        path = os.path.join(golden_dir, name + ".txt")
        if not os.path.isfile(path):
            raise FileNotFoundError("missing committed usage golden: " + path)
        with open(path, "rb") as fh:
            bodies[name] = fh.read()
    return bodies


def load_fallback_names(fallback_path: str) -> list[str]:
    """Recover the recorded fallback list so offline regeneration stays stable."""
    with open(fallback_path, encoding="utf-8") as fh:
        return list(json.load(fh)["names"])


def c_sources(src: str) -> list[str]:
    return sorted(
        glob.glob(os.path.join(src, "*", "*.c"))
        + glob.glob(os.path.join(src, "*", "*", "*.c"))
    )


def alias_help_name(src: str) -> dict[str, str]:
    """Map an applet name to the ``help`` name of its ``APPLET_*`` macro.

    ``APPLET_ODDNAME(netcat, nc, ..., nc)`` and friends use another applet's
    ``*_usage`` macros while still printing their own name in ``Usage:``.
    """
    result: dict[str, str] = {}
    pat = re.compile(
        r"//applet:\s*(?:IF_\w+\()?APPLET"
        r"(_ODDNAME|_NOEXEC|_NOFORK|_SCRIPTED)?\(([^)]*)\)"
    )
    for path in c_sources(src):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = pat.search(line)
                if not m or not m.group(1):
                    continue
                parts = [p.strip() for p in m.group(2).split(",")]
                if len(parts) >= 5:
                    result[parts[0]] = parts[-1]
    return result


# --------------------------------------------------------------------------- #
# Reference-binary capture
# --------------------------------------------------------------------------- #

def reference_available(ref: str | None, src: str | None) -> bool:
    """True only when capture from the reference can be done faithfully.

    Both the binary and the usage-comment source tree are needed: the binary
    supplies the 411+ enabled applets, the source supplies the compiled-out
    ones.  If either is missing we use the committed goldens instead of writing
    degraded data (e.g. "No help available" for every fallback applet).
    """
    return bool(
        ref
        and os.path.isfile(ref)
        and os.access(ref, os.X_OK)
        and src
        and os.path.isdir(src)
    )


def run(ref: str, *args: str) -> bytes:
    return subprocess.run(
        [ref, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30
    ).stdout


def banner_prefix(ref: str) -> bytes:
    """The exact first line of ``bb_show_usage()`` for this reference build."""
    version = run(ref, "--version")
    return version.rstrip(b"\n") + MULTI_CALL_SUFFIX


def capture_body(ref: str, name: str, prefix: bytes) -> bytes | None:
    """Return the usage body, or ``None`` if the binary has no such applet."""
    proc = subprocess.run(
        [ref, "--help", name],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if proc.returncode != 0 or not proc.stdout.startswith(prefix):
        return None
    return proc.stdout[len(prefix):]


# --------------------------------------------------------------------------- #
# Source-comment fallback
# --------------------------------------------------------------------------- #

def usage_lines(src: str, name: str) -> list[str] | None:
    """Collect the raw ``//usage:`` lines that define ``name``'s usage macros."""
    define = re.compile(r"//usage:#define\s+" + re.escape(name) + r"_(trivial|full)_usage\b")
    for path in c_sources(src):
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
        matches = [i for i, line in enumerate(lines) if define.match(line)]
        if not matches:
            continue
        start = matches[0]
        # gen_build_files.sh keeps a preceding #if in the same usage block.
        while start > 0 and lines[start - 1].startswith("//usage:#if"):
            start -= 1
        out: list[str] = []
        for line in lines[start:]:
            if line.startswith("//usage:"):
                content = line[len("//usage:"):]
                # An empty //usage: line after the full macro ends the block
                # (it separates usage from *_example_usage in many files).
                if not content.strip() and any("full_usage" in x for x in out):
                    break
                out.append(content)
            elif "//usage:" in line:
                # Commented-out directives such as /* //usage: ... */ are
                # deliberately ignored, exactly like gen_build_files.sh.
                continue
            elif not line.strip():
                if out:
                    break
            else:
                if out:
                    break
        return out
    return None


def eval_condition(expr: str, cfg: dict[str, str]) -> bool:
    """Evaluate a small ``#if`` expression such as ``ENABLE_A || ENABLE_B``."""
    env: dict[str, int] = {}
    for key, value in cfg.items():
        short = key[len("CONFIG_"):]
        on = 1 if value == "y" else 0
        env["CONFIG_" + short] = on
        env["ENABLE_" + short] = on
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    try:
        return bool(eval(expr, {"__builtins__": {}}, env))  # noqa: S307
    except Exception:
        return False


def resolve_conditionals(lines: list[str], cfg: dict[str, str]) -> list[str]:
    """Drop inactive ``#if``/``#else`` branches from a usage block."""
    out: list[str] = []
    stack: list[list[bool]] = []  # [parent_active, taken, current_active]

    def active() -> bool:
        return all(frame[2] for frame in stack)

    for line in lines:
        stripped = line.strip()
        if re.match(r"#if(ndef|def)?\s+", stripped):
            kind = "#ifndef" if stripped.startswith("#ifndef") else (
                "#ifdef" if stripped.startswith("#ifdef") else "#if"
            )
            expr = stripped.split(None, 1)[1]
            cond = not eval_condition(expr, cfg) if kind == "#ifndef" else eval_condition(expr, cfg)
            parent = active()
            stack.append([parent, cond, parent and cond])
            continue
        if stripped.startswith("#elif "):
            if stack:
                frame = stack[-1]
                cond = eval_condition(stripped.split(None, 1)[1], cfg)
                frame[2] = frame[0] and not frame[1] and cond
                frame[1] = frame[1] or frame[2]
            continue
        if stripped == "#else":
            if stack:
                frame = stack[-1]
                frame[2] = frame[0] and not frame[1]
                frame[1] = True
            continue
        if stripped == "#endif":
            if stack:
                stack.pop()
            continue
        if active():
            out.append(line)
    return out


def parse_macros(lines: list[str]) -> dict[str, str]:
    """Turn ``#define NAME ...`` plus following literal lines into strings."""
    macros: dict[str, str] = {}
    i = 0
    while i < len(lines):
        m = re.match(r"#define\s+(\w+)\s*(.*)", lines[i].strip())
        if not m:
            i += 1
            continue
        name, value = m.group(1), m.group(2)
        i += 1
        while i < len(lines) and lines[i].strip() and not lines[i].strip().startswith("#"):
            value += lines[i].strip()
            i += 1
        macros[name] = value
    return macros


_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", "0": "\0", "a": "\a", "b": "\b",
    "f": "\f", "v": "\v", "?": "?", "\\": "\\", '"': '"', "'": "'",
}


def _c_string(expr: str, i: int) -> tuple[str, int]:
    i += 1  # opening quote
    out: list[str] = []
    while i < len(expr):
        ch = expr[i]
        if ch == '"':
            return "".join(out), i + 1
        if ch == "\\":
            i += 1
            if i >= len(expr):
                break
            nxt = expr[i]
            if nxt == "x":
                j = i + 1
                digits = ""
                while j < len(expr) and expr[j] in "0123456789abcdefABCDEF":
                    digits += expr[j]
                    j += 1
                out.append(chr(int(digits, 16)) if digits else "")
                i = j
                continue
            out.append(_ESCAPES.get(nxt, nxt))
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out), i


def _closing_paren(expr: str, i: int) -> int:
    depth = 0
    in_string = False
    while i < len(expr):
        ch = expr[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def eval_usage_expr(expr: str, cfg: dict[str, str]) -> str:
    """Concatenate C literals, expanding ``IF_FEATURE_X(...)`` and ``NOUSAGE_STR``."""
    enabled = {k[len("CONFIG_"):]: (v == "y") for k, v in cfg.items() if k.startswith("CONFIG_")}
    out: list[str] = []
    i = 0
    while i < len(expr):
        ch = expr[i]
        if ch.isspace():
            i += 1
            continue
        if ch == '"':
            text, i = _c_string(expr, i)
            out.append(text)
            continue
        m = re.match(r"(IF_NOT_|IF_)[A-Za-z0-9_]+", expr[i:])
        if m and i + m.end() < len(expr) and expr[i + m.end()] == "(":
            name = m.group(0)
            opening = i + m.end()
            closing = _closing_paren(expr, opening)
            if closing < 0:
                break
            inner = eval_usage_expr(expr[opening + 1:closing], cfg)
            if name.startswith("IF_NOT_"):
                flag = not enabled.get(name[len("IF_NOT_"):], False)
            else:
                flag = enabled.get(name[len("IF_"):], False)
            if flag:
                out.append(inner)
            i = closing + 1
            continue
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", expr[i:])
        if m:
            name = m.group(0)
            if name == "NOUSAGE_STR":
                out.append("\b")
            # Any other bare identifier belongs to usage.src.h helpers; none
            # of the fallback applets reference them.
            i += m.end()
            continue
        i += 1
    return "".join(out)


def render_source_usage(src: str, cfg: dict[str, str], name: str) -> str | None:
    """Render ``trivial_usage ++ full_usage`` for ``name`` from //usage: lines."""
    help_name = alias_help_name(src).get(name, name)
    lines = usage_lines(src, help_name)
    if lines is None:
        return None
    macros = parse_macros(resolve_conditionals(lines, cfg))
    trivial = eval_usage_expr(macros.get(help_name + "_trivial_usage", ""), cfg)
    full = eval_usage_expr(macros.get(help_name + "_full_usage", ""), cfg)
    return trivial + full


def compose_body(name: str, usage_string: str) -> bytes:
    """Reproduce bb_show_usage()'s bytes after the banner line."""
    if usage_string.startswith("\b"):
        return NO_HELP
    sep = "" if usage_string.startswith("\n") else " "
    text = "\nUsage: " + name + sep + usage_string + "\n"
    return text.encode("ascii")


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

def zig_string(data: bytes) -> str:
    out = ['"']
    for ch in data:
        if ch == 0x5C:
            out.append("\\\\")
        elif ch == 0x22:
            out.append('\\"')
        elif ch == 0x0A:
            out.append("\\n")
        elif ch == 0x0D:
            out.append("\\r")
        elif ch == 0x09:
            out.append("\\t")
        elif 0x20 <= ch < 0x7F:
            out.append(chr(ch))
        else:
            out.append("\\x%02x" % ch)
    out.append('"')
    return "".join(out)


def fallback_document(fallback: list[str]) -> str:
    """Fallback metadata with normalized, path-independent provenance.

    Absolute toolchain paths would make ``--check`` fail whenever the reference
    is provisioned elsewhere, so the provenance fields name the committed
    artifacts rather than the machine-specific inputs.
    """
    return json.dumps(
        {
            "reference": "tests/parity/usage/*.txt",
            "source": "reference/busybox/**/*.c",
            "count": len(fallback),
            "names": fallback,
            "reason": "applet compiled out of the comparison reference build; "
                      "usage rendered from reference //usage: comments",
        },
        indent=2,
        ensure_ascii=False,
    ) + "\n"


def zig_text(names: list[str], bodies: dict[str, bytes], fallback: list[str]) -> str:
    lines = [
        "// Generated by scripts/parity/extract_usage.py - DO NOT EDIT.",
        "// Source: reference BusyBox 1.39.0.git `busybox --help <applet>` output.",
        "// Bodies exclude the banner line; main.zig prepends meta.first_line.",
        "// Regenerate with:",
        "//   python3 scripts/parity/extract_usage.py --ref <reference-busybox> --src <source-tree>",
        "",
        "const std = @import(\"std\");",
        "",
        "const Entry = struct { name: []const u8, text: []const u8 };",
        "",
        "const entries = [_]Entry{",
    ]
    for name in names:
        lines.append("    .{ .name = %s, .text = %s }," % (zig_string(name.encode()), zig_string(bodies[name])))
    lines += [
        "};",
        "",
        "/// Applets whose reference binary omitted usage; rendered from //usage: comments.",
        "pub const source_fallback = [_][]const u8{",
    ]
    for name in fallback:
        lines.append("    " + zig_string(name.encode()) + ",")
    lines += [
        "};",
        "",
        "pub fn usageFor(name: []const u8) ?[]const u8 {",
        "    for (entries) |entry| {",
        "        if (std.mem.eql(u8, name, entry.name)) return entry.text;",
        "    }",
        "    return null;",
        "}",
        "",
        'test "usage table is complete and sorted" {',
        "    try std.testing.expectEqual(@as(usize, %d), entries.len);" % len(names),
        "    for (entries, 0..) |entry, i| {",
        "        try std.testing.expect(entry.text.len > 0);",
        "        if (i > 0) try std.testing.expect(std.mem.order(u8, entries[i - 1].name, entry.name) == .lt);",
        "    }",
        "    for (source_fallback) |name| try std.testing.expect(usageFor(name) != null);",
        "}",
        "",
    ]
    return "\n".join(lines)


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print("wrote " + path)


def write_bytes(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def generate_capture(ref: str, src: str, manifest: str, defconfig: str) -> tuple[dict[str, bytes], list[str]]:
    """Capture enabled applets from the binary; render compiled-out ones from source."""
    names = load_manifest(manifest)
    cfg = load_config(defconfig)
    prefix = banner_prefix(ref)
    bodies: dict[str, bytes] = {}
    fallback: list[str] = []
    for name in names:
        body = capture_body(ref, name, prefix)
        if body is None:
            usage_string = render_source_usage(src, cfg, name)
            if usage_string is None:
                print("no usage source for " + name, file=sys.stderr)
                body = NO_HELP
            else:
                body = compose_body(name, usage_string)
            fallback.append(name)
        bodies[name] = body
    return bodies, fallback


def generate_offline(
    golden_dir: str, manifest: str, fallback_path: str
) -> tuple[dict[str, bytes], list[str]]:
    """Rebuild the derived artifacts from committed goldens, no reference needed."""
    names = load_manifest(manifest)
    bodies = load_goldens(golden_dir, names)
    fallback = load_fallback_names(fallback_path)
    unknown = [name for name in fallback if name not in bodies]
    if unknown:
        raise ValueError("fallback metadata lists non-manifest applets: " + ", ".join(unknown))
    return bodies, fallback


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ref", default=None, help="reference busybox binary (omit to use committed goldens)"
    )
    parser.add_argument("--src", default=DEFAULT_SRC, help="BusyBox source tree for fallback")
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, help="applet manifest JSON")
    parser.add_argument("--defconfig", default=DEFAULT_DEFCONFIG, help="config for //usage: conditionals")
    parser.add_argument("--golden-dir", default=DEFAULT_GOLDEN_DIR, help="usage golden directory")
    parser.add_argument("--fallback", default=DEFAULT_FALLBACK, help="fallback metadata JSON")
    parser.add_argument("--zig", default=DEFAULT_ZIG, help="generated Zig module output")
    parser.add_argument(
        "--check", action="store_true", help="fail if committed goldens / Zig module are stale"
    )
    args = parser.parse_args(argv)

    if reference_available(args.ref, args.src):
        mode = "reference"
        bodies, fallback = generate_capture(args.ref, args.src, args.manifest, args.defconfig)
    else:
        mode = "goldens"
        if args.ref:
            print(
                "reference binary or source tree unavailable; using committed goldens",
                file=sys.stderr,
            )
        bodies, fallback = generate_offline(args.golden_dir, args.manifest, args.fallback)

    zig = zig_text(sorted(bodies), bodies, fallback)
    fallback_text = fallback_document(fallback)

    if args.check:
        ok = True
        # In goldens mode the .txt files are the input; in reference mode they
        # must match the freshly captured bytes. The comparison is the same.
        for name, body in bodies.items():
            path = os.path.join(args.golden_dir, name + ".txt")
            if not os.path.isfile(path) or open(path, "rb").read() != body:
                print("stale or missing golden: " + path, file=sys.stderr)
                ok = False
        for path, text in ((args.zig, zig), (args.fallback, fallback_text)):
            if not os.path.exists(path) or open(path, encoding="utf-8", newline="").read() != text:
                print("stale or missing: " + path, file=sys.stderr)
                ok = False
        if ok:
            print(
                "usage golden in sync (%d applets, %d fallback, %s)"
                % (len(bodies), len(fallback), mode)
            )
        return 0 if ok else 1

    # Goldens are never rewritten in offline mode: they are the source of truth.
    if mode == "reference":
        for name, body in bodies.items():
            write_bytes(os.path.join(args.golden_dir, name + ".txt"), body)
    write(args.fallback, fallback_text)
    write(args.zig, zig)
    print("regenerated from %s: %d applets (%d fallback)" % (mode, len(bodies), len(fallback)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
