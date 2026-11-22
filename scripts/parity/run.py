#!/usr/bin/env python3
"""Differential test harness for the BusyBox 1.39.0 parity program.

For every case the harness materializes two identical sandboxes, runs the
reference binary in one and the Zig binary in the other, then compares stdout,
stderr, exit status and the resulting filesystem snapshot.  A case may also
carry explicit ``expect`` assertions that are checked against the Zig side.

Modes:
  differential (default)  run both binaries and compare them
  --update-golden         run the reference and record its output as golden
  --golden DIR            compare the Zig binary against recorded goldens

Exit status: 0 = pass, 1 = mismatch, 2 = harness error.
"""

from __future__ import annotations

import argparse
import base64
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Any

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    # Support both ``python3 scripts/parity/run.py`` and ``-m unittest`` import.
    sys.path.insert(0, REPO_ROOT)

from scripts.parity import normalize
from scripts.parity.sandbox import Tree, materialize, snapshot

SCRATCH_DIR = "/tmp/opencode/parity"
os.makedirs(SCRATCH_DIR, exist_ok=True)

DEFAULT_CASES = os.path.join(REPO_ROOT, "tests", "parity", "cases")
DEFAULT_GOLDEN = os.path.join(REPO_ROOT, "tests", "parity", "golden")
DEFAULT_KNOWN_FAILURES = os.path.join(REPO_ROOT, "tests", "parity", "known-failures.txt")


# ---------------------------------------------------------------------------
# Result types and primitive comparison
# ---------------------------------------------------------------------------


@dataclass
class Result:
    """Outcome of one check.  ``status`` is pass | fail | skip | error."""

    status: str
    diff: str = ""
    name: str = ""
    reason: str = ""


@dataclass
class Observation:
    """Everything a single binary run produces for one case."""

    stdout: str = ""
    stderr: str = ""
    exit: int = 0
    tree: Tree = field(default_factory=dict)


class CapabilityUnavailable(Exception):
    """A helper (pty/ns) could not run because a required capability is absent."""

    def __init__(self, token: str, reason: str):
        super().__init__(reason)
        self.token = token
        self.reason = reason


class HarnessTimeout(Exception):
    """A case exceeded its declared timeout."""


def compare(expected: Any, actual: Any, label: str = "stdout") -> Result:
    """Compare two scalar/tree values, returning a labeled pass/fail Result."""
    if expected == actual:
        return Result("pass")
    return Result(
        "fail",
        "%s:\n  expected: %r\n  actual:   %r" % (label, expected, actual),
    )


def compare_observations(expected: Observation, actual: Observation, name: str = "") -> Result:
    """Compare two full observations, reporting every differing field."""
    parts: list[str] = []
    for field_name in ("stdout", "stderr", "exit", "tree"):
        part = compare(
            getattr(expected, field_name),
            getattr(actual, field_name),
            label=field_name,
        )
        if part.status == "fail":
            parts.append(part.diff)
    if parts:
        return Result("fail", "\n".join(parts), name=name)
    return Result("pass", name=name)


def skip_decision(requires: list[str] | None, reason: str) -> Result:
    """Turn an unmet capability into SKIP, or into an error when undeclared.

    A silent skip is always a harness error: a case that needs a capability
    must declare it in its ``requires`` list.  This is the single enforcement
    point for that policy.
    """
    if not requires:
        return Result("error", "SKIP without requires: " + reason, reason=reason)
    return Result(
        "skip",
        "SKIP (requires %s): %s" % (",".join(requires), reason),
        reason=reason,
    )


# ---------------------------------------------------------------------------
# Single-binary observation
# ---------------------------------------------------------------------------


def _environment(case: dict, root: str, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LC_ALL": "C",
        "LANG": "C",
        "TZ": "UTC",
        "HOME": root,
        "TMPDIR": root,
    }
    for key, value in (case.get("env") or {}).items():
        # A case can refer to its sandbox with the portable <TMP> placeholder.
        env[key] = str(value).replace("<TMP>", root)
    if extra:
        env.update(extra)
    return env


def _case_cwd(case: dict, root: str) -> str:
    cwd = case.get("cwd") or "."
    if os.path.isabs(cwd):
        raise ValueError("case cwd must be relative to the sandbox: " + cwd)
    target = os.path.realpath(os.path.join(root, cwd))
    root_real = os.path.realpath(root)
    if os.path.commonpath([root_real, target]) != root_real:
        raise ValueError("case cwd escapes sandbox: " + cwd)
    return target


def _normalize_tree(tree: Tree, rules: list[str], root: str) -> Tree:
    out: Tree = {}
    for path, node in tree.items():
        item = dict(node)
        if item.get("type") == "file" and isinstance(item.get("content"), bytes):
            text = item["content"].decode("utf-8", "replace")
            item["content"] = normalize.apply(text, rules, root=root).encode("utf-8", "replace")
        elif item.get("type") == "symlink":
            item["target"] = normalize.apply(item["target"], rules, root=root)
        out[path] = item
    return out


def observe(
    binary: str,
    argv: list[str],
    case: dict,
    root: str,
    *,
    timeout_ms: int | None = None,
    env: dict[str, str] | None = None,
) -> Observation:
    """Run one binary inside a fresh sandbox and return its observation."""
    materialize(case, root)
    rules = case.get("normalize") or []
    env_map = _environment(case, root, env)
    timeout = (timeout_ms if timeout_ms is not None else case.get("timeout_ms", 5000)) / 1000.0

    # Optional deterministic loopback server.  Each observation gets its own
    # server on an ephemeral port; <PORT> in argv/stdin is substituted with
    # that port and normalized back to <PORT> in the output so the two
    # observations (and later golden comparisons) stay comparable.
    srv = None
    if case.get("server"):
        from scripts.parity.server import LoopbackServer
        srv = LoopbackServer(case["server"])
    try:
        port_text = str(srv.port) if srv else None

        def sub(text):
            if port_text:
                text = text.replace("<PORT>", port_text)
            # <BB> expands to the binary under test. Cases for applets which
            # exec helper programs (ssl_client -e, ssl_server PROG) use it so
            # each side of a differential run execs its own build.
            return text.replace("<TMP>", root).replace("<BB>", binary)

        # Most cases run an applet of the multi-call binary. Applets which
        # need an external driver (an independent TLS client for ssl_server)
        # may provide ``exec_argv`` instead; <BB> expands to the binary under
        # test so each differential side drives its own build.
        if case.get("exec_argv"):
            full_argv = [sub(a) for a in case["exec_argv"]]
        else:
            full_argv = [binary, *(sub(a) for a in argv)]

        if case.get("tty") or case.get("use_pty"):
            from scripts.parity.pty_helper import (  # lazy: optional helper
                PtyTimeout,
                PtyUnavailable,
                run_pty,
            )

            if not _capability("tty"):
                raise CapabilityUnavailable("tty", "no usable pseudo-terminal")
            try:
                stdout, exit_code = run_pty(full_argv, case.get("script") or [], timeout)
            except PtyTimeout as exc:
                raise HarnessTimeout(str(exc)) from exc
            except PtyUnavailable as exc:
                raise CapabilityUnavailable("tty", str(exc)) from exc
            stderr = ""
        elif case.get("ns") or case.get("use_ns"):
            from scripts.parity.ns import NsTimeout, NsUnavailable, run_ns  # lazy: optional helper

            kind = case.get("ns") or case.get("use_ns")
            capability = _NS_CAPABILITY.get(kind, kind)
            if not _capability(capability):
                raise CapabilityUnavailable(capability, "namespace " + kind + " unavailable")
            try:
                proc = run_ns(kind, full_argv, timeout=timeout)
            except NsTimeout as exc:
                raise HarnessTimeout(str(exc)) from exc
            except NsUnavailable as exc:
                raise CapabilityUnavailable(capability, str(exc)) from exc
            stdout = proc.stdout.decode("utf-8", "replace")
            stderr = proc.stderr.decode("utf-8", "replace")
            exit_code = proc.returncode
        else:
            kwargs: dict[str, Any] = {
                "cwd": _case_cwd(case, root),
                "env": env_map,
                "stdout": subprocess.PIPE,
                "stderr": subprocess.PIPE,
                "timeout": timeout,
            }
            if case.get("stdin") is None:
                kwargs["stdin"] = subprocess.DEVNULL
            else:
                raw_stdin = str(case["stdin"])
                if port_text:
                    raw_stdin = raw_stdin.replace("<PORT>", port_text)
                raw_stdin = raw_stdin.replace("<TMP>", root).replace("<BB>", binary)
                kwargs["input"] = raw_stdin.encode("utf-8")
            try:
                proc = subprocess.run(full_argv, **kwargs)
            except subprocess.TimeoutExpired as exc:
                raise HarnessTimeout("timeout after %g s" % timeout) from exc
            stdout = proc.stdout.decode("utf-8", "replace")
            stderr = proc.stderr.decode("utf-8", "replace")
            exit_code = proc.returncode

        if port_text:
            stdout = stdout.replace(port_text, "<PORT>")
            stderr = stderr.replace(port_text, "<PORT>")
        tree = _normalize_tree(snapshot(root), rules, root)
        return Observation(
            stdout=normalize.apply(stdout, rules, root=root),
            stderr=normalize.apply(stderr, rules, root=root),
            exit=exit_code,
            tree=tree,
        )
    finally:
        if srv is not None:
            srv.stop()


def run_case(
    *,
    binary: str,
    argv: list[str],
    case: dict,
    root: str | None = None,
    timeout_ms: int | None = None,
    env: dict[str, str] | None = None,
) -> Result:
    """Run one binary and validate it against the case's explicit ``expect``.

    This is the primitive used by the harness self-test.  In production,
    ``execute_case`` combines two ``observe`` calls for the differential check
    and additionally applies the explicit expectations.
    """
    tmp: tempfile.TemporaryDirectory[str] | None = None
    if root is None:
        tmp = tempfile.TemporaryDirectory(dir=SCRATCH_DIR)
        root = tmp.name
    try:
        obs = observe(binary, argv, case, root, timeout_ms=timeout_ms, env=env)
        parts: list[str] = []
        for field_name in ("exit", "stdout", "stderr", "tree"):
            expect = case.get("expect") or {}
            if field_name in expect and expect[field_name] != getattr(obs, field_name):
                parts.append(
                    compare(expect[field_name], getattr(obs, field_name),
                            label="expect." + field_name).diff
                )
        if parts:
            return Result("fail", "\n".join(parts))
        return Result("pass")
    finally:
        if tmp is not None:
            tmp.cleanup()


# ---------------------------------------------------------------------------
# Capability / requires policy
# ---------------------------------------------------------------------------

# Namespace kinds used by the optional ``ns`` case field map to the requires
# tokens a wave must declare for the case to be runnable.
_NS_CAPABILITY = {
    "net": "netns",
    "mnt": "mountns",
    "mount": "mountns",
    "user": "userns",
    "uts": "root",
    "ipc": "root",
    "pid": "root",
    "cgroup": "root",
}

_REQUIRE_REASONS = {
    "tty": "no usable pseudo-terminal",
    "pty": "no usable pseudo-terminal",
    "root": "not running as root",
    "privileged": "no privileges available in sandbox",
    "netns": "network namespaces unavailable",
    "userns": "user namespaces unavailable",
    "mountns": "mount namespaces unavailable",
    "network": "no real network interfaces in sandbox",
    "disk": "no real block devices in sandbox",
    "service": "no system services in sandbox",
    "tc": "reference binary built with CONFIG_TC=n",
}


def _ref_has_applet(ref: str | None, applet: str) -> bool:
    if not ref or not os.path.exists(ref):
        return False
    try:
        out = subprocess.run(
            [ref, "--list"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10
        ).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return False
    return applet in out.splitlines()


def _can_unshare(kind: str) -> bool:
    if shutil.which("unshare") is None:
        return False
    return hasattr(os, "geteuid") and os.geteuid() == 0


def _capability(token: str, ref: str | None = None) -> bool:
    if token in ("tty", "pty"):
        return os.path.exists("/dev/ptmx")
    if token in ("root", "privileged"):
        return hasattr(os, "geteuid") and os.geteuid() == 0
    if token in ("netns", "userns", "mountns"):
        return _can_unshare(token)
    if token == "tc":
        return _ref_has_applet(ref, "tc")
    if token in ("network", "disk", "service"):
        return False
    raise ValueError("unknown requires token: " + token)


def _capabilities(ref: str | None = None) -> dict[str, bool]:
    tokens = ("tty", "pty", "root", "privileged", "netns", "userns", "mountns",
              "network", "disk", "service", "tc")
    return {token: _capability(token, ref) for token in tokens}


def unmet_requirements(requires: list[str] | None, ref: str | None = None) -> list[tuple[str, str]]:
    """Return ``(token, reason)`` pairs for requirements not met by this host."""
    unmet: list[tuple[str, str]] = []
    for token in requires or []:
        if not _capability(token, ref):
            unmet.append((token, _REQUIRE_REASONS.get(token, token + " unavailable")))
    return unmet


# ---------------------------------------------------------------------------
# Golden serialization
# ---------------------------------------------------------------------------


def _tree_to_json(tree: Tree) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for path, node in tree.items():
        item = dict(node)
        if isinstance(item.get("content"), bytes):
            item["content"] = {"__base64__": base64.b64encode(item["content"]).decode("ascii")}
        out[path] = item
    return out


def _tree_from_json(data: dict[str, Any]) -> Tree:
    out: Tree = {}
    for path, node in data.items():
        item = dict(node)
        content = item.get("content")
        if isinstance(content, dict) and "__base64__" in content:
            item["content"] = base64.b64decode(content["__base64__"])
        out[path] = item
    return out


def _golden_path(golden_dir: str, applet: str, name: str) -> str:
    return os.path.join(golden_dir, "cases", applet, name + ".json")


def _write_golden(golden_dir: str, applet: str, name: str, obs: Observation) -> str:
    path = _golden_path(golden_dir, applet, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    doc = {
        "applet": applet,
        "name": name,
        "stdout": obs.stdout,
        "stderr": obs.stderr,
        "exit": obs.exit,
        "tree": _tree_to_json(obs.tree),
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    return path


def _read_golden(golden_dir: str, applet: str, name: str) -> Observation | None:
    path = _golden_path(golden_dir, applet, name)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    return Observation(
        stdout=doc["stdout"],
        stderr=doc["stderr"],
        exit=doc["exit"],
        tree=_tree_from_json(doc.get("tree", {})),
    )


# ---------------------------------------------------------------------------
# Case files and execution
# ---------------------------------------------------------------------------


def load_cases(cases_dir: str, applet: str | None = None) -> list[tuple[str, dict]]:
    """Load and validate all case JSON files below ``cases_dir``."""
    if not os.path.isdir(cases_dir):
        raise ValueError("cases directory not found: " + cases_dir)
    selected: list[tuple[str, dict]] = []
    for path in sorted(glob.glob(os.path.join(cases_dir, "**", "*.json"), recursive=True)):
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict) or "applet" not in doc or not isinstance(doc.get("cases"), list):
            raise ValueError("invalid case file: " + path)
        stem = os.path.splitext(os.path.basename(path))[0]
        if stem != doc["applet"]:
            raise ValueError("%s: filename %r does not match applet %r" % (path, stem, doc["applet"]))
        if applet is not None and doc["applet"] != applet:
            continue
        selected.append((path, doc))
    if applet is not None and not selected:
        raise ValueError("no cases found for applet " + applet)
    return selected


def known_failures(path: str | None) -> set[str]:
    """Read ``applet/name`` keys from a known-failures file."""
    known: set[str] = set()
    if not path or not os.path.exists(path):
        return known
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key = line.split(":", 1)[0].strip()
            if key:
                known.add(key)
    return known


@dataclass
class Settings:
    ref: str | None
    zig: str | None
    golden_dir: str | None
    update_golden: bool
    verbose: bool


def execute_case(settings: Settings, applet: str, case: dict) -> Result:
    """Run one case in the configured mode."""
    name = case.get("name")
    if not name:
        return Result("error", "case without a name in applet " + applet)
    key = applet + "/" + name
    argv = [applet, *(case.get("argv") or [])]
    try:
        unmet = unmet_requirements(case.get("requires") or [], ref=settings.ref)
        if unmet:
            return skip_decision(
                case.get("requires") or [],
                "; ".join("%s: %s" % pair for pair in unmet),
            )

        with tempfile.TemporaryDirectory(dir=SCRATCH_DIR) as base:
            if settings.update_golden:
                assert settings.ref is not None
                obs = observe(settings.ref, argv, case, os.path.join(base, "ref"))
                assert settings.golden_dir is not None
                _write_golden(settings.golden_dir, applet, name, obs)
                return Result("pass", "golden recorded", name=key)

            expected: Observation | None = None
            if settings.golden_dir is not None:
                expected = _read_golden(settings.golden_dir, applet, name)
                if expected is None:
                    return Result("error", "missing golden for " + key, name=key)
            else:
                assert settings.ref is not None
                expected = observe(settings.ref, argv, case, os.path.join(base, "ref"))

            assert settings.zig is not None
            actual = observe(settings.zig, argv, case, os.path.join(base, "zig"))
            result = compare_observations(expected, actual, name=key)

            # Explicit expectations are assertions about the Zig side itself,
            # independent of the reference comparison.
            parts = [result.diff] if result.status == "fail" else []
            for field_name in ("exit", "stdout", "stderr", "tree"):
                expect = case.get("expect") or {}
                if field_name in expect and expect[field_name] != getattr(actual, field_name):
                    parts.append(
                        compare(expect[field_name], getattr(actual, field_name),
                                label="expect." + field_name).diff
                    )
            if parts:
                return Result("fail", "\n".join(parts), name=key)
            return Result("pass", name=key)
    except CapabilityUnavailable as exc:
        return skip_decision(case.get("requires") or [], exc.reason)
    except (HarnessTimeout, ValueError, OSError, subprocess.SubprocessError) as exc:
        return Result("error", "%s: %s" % (type(exc).__name__, exc), name=key)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="reference BusyBox binary")
    parser.add_argument("--zig", help="Zig BusyBox binary under test")
    parser.add_argument("--cases", default=DEFAULT_CASES, help="case directory")
    parser.add_argument("--applet", help="run cases for one applet only")
    parser.add_argument("--all", action="store_true", help="run all case files")
    parser.add_argument("--golden", nargs="?", const=DEFAULT_GOLDEN, default=None,
                        help="compare against (or, with --update-golden, write) goldens")
    parser.add_argument("--update-golden", action="store_true", help="record reference output")
    parser.add_argument("--known-failures", default=DEFAULT_KNOWN_FAILURES,
                        help="file listing known-failure applet/name keys")
    parser.add_argument("--verbose", action="store_true", help="print diffs for passing cases too")
    args = parser.parse_args(argv)

    # Child processes run with cwd inside a sandbox, so every path we pass
    # down must be absolute.
    for attr in ("ref", "zig", "cases", "golden", "known_failures"):
        value = getattr(args, attr)
        if value:
            setattr(args, attr, os.path.abspath(value))

    if not (args.applet or args.all):
        parser.error("pass --applet NAME or --all")
    if args.applet and args.all:
        parser.error("--applet and --all are mutually exclusive")
    if args.update_golden and not args.ref:
        parser.error("--update-golden requires --ref")
    golden_dir = args.golden
    if args.update_golden:
        golden_dir = golden_dir or DEFAULT_GOLDEN
        if not args.ref:
            parser.error("--update-golden requires --ref")
    elif args.golden is not None and not args.zig:
        parser.error("--golden requires --zig")
    if golden_dir is None and (not args.ref or not args.zig):
        parser.error("differential mode requires --ref and --zig")

    try:
        files = load_cases(args.cases, args.applet)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("harness error: %s" % exc, file=sys.stderr)
        return 2

    known = known_failures(args.known_failures)
    settings = Settings(
        ref=args.ref,
        zig=args.zig,
        golden_dir=golden_dir,
        update_golden=args.update_golden,
        verbose=args.verbose,
    )

    counts = {"pass": 0, "fail": 0, "knownfail": 0, "skip": 0, "error": 0}
    stale_known: list[str] = []
    for _path, doc in files:
        applet = doc["applet"]
        for case in doc["cases"]:
            result = execute_case(settings, applet, case)
            key = applet + "/" + str(case.get("name", ""))
            if settings.update_golden:
                # Recording goldens never exercises the Zig binary, so known
                # failures are irrelevant in this mode.
                label, status = result.status.upper(), result.status
            elif result.status == "fail" and key in known:
                label, status = "KNOWNFAIL", "knownfail"
            elif result.status == "pass" and key in known:
                label, status = "PASS", "pass"
                stale_known.append(key)
            else:
                label, status = result.status.upper(), result.status
            counts[status] = counts.get(status, 0) + 1
            if status in ("fail", "error", "knownfail") or args.verbose:
                print("%-11s %s" % (label, key))
                if result.diff:
                    print("  " + result.diff.replace("\n", "\n  "))
            else:
                print("%-11s %s" % (label, key))
    for key in stale_known:
        print("NOTE: %s is listed in known-failures.txt but now passes" % key)

    print(
        "\n%d passed, %d failed, %d known-failures, %d skipped, %d errors"
        % (
            counts.get("pass", 0), counts.get("fail", 0), counts.get("knownfail", 0),
            counts.get("skip", 0), counts.get("error", 0),
        )
    )
    if counts.get("error", 0):
        return 2
    if counts.get("fail", 0):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
