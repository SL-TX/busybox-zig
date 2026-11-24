#!/usr/bin/env python3
"""Deterministic fuzz/smoke harness for parity parsers and formats.

The harness feeds seeded, bounded random inputs to the reference BusyBox and
the Zig binary under test through the same applet entry points.  It classifies
each run as:

  pass        both binaries agree (exit status + stdout + stderr)
  divergence  both ran to completion but produced different output
  crash       a process died from a signal or returned a shell-style >=128 code
  hang        a process exceeded the per-case timeout
  oom         a process was killed for exceeding its address-space limit

Only crashes, hangs and OOMs are hard failures.  Divergences are recorded as
bugs in the JSON report for later triage — the parity program does not treat
a fuzz-found difference as an automatically accepted gap.

Targets (per the Task 27 brief): getopt32, regex, sed, awk, shell, tar, cpio,
gzip, bzip2, xz, lzop, DNS, DHCP, HTTP, TLS.  All inputs are generated locally;
no target opens a listening socket or writes outside a private temp directory.

When no usable ``--ref`` binary is available (for example in the CI image,
which ships no reference), the harness emits a clean SKIP: it writes a report
with ``status: "skip"`` and exits 0 instead of turning every case into an
``error:``.  This lets the fuzz-smoke stage pass in reference-less pipelines.

Usage:
  python3 scripts/parity/fuzz.py --ref REF --zig ZIG [--iterations N] \
      [--seed S] [--out REPORT.json] [--smoke]
"""

from __future__ import annotations

import argparse
import json
import os
import random
import resource
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

TARGETS = (
    "getopt32", "regex", "sed", "awk", "shell", "tar", "cpio", "gzip",
    "bzip2", "xz", "lzop", "dns", "dhcp", "http", "tls",
)

# Cap each child at 256 MiB so an unbounded allocation is reported as OOM
# rather than swapping the host to a standstill.
_AS_LIMIT = 256 * 1024 * 1024


def _alphabet(rng, extra=""):
    base = "abcXYZ0123 \t\n\r\\/'\"[]{}()*+?^$.|-_:=,;#&<>!~%@"
    return base + extra


def _rand_bytes(rng, n, alphabet):
    return "".join(rng.choice(alphabet) for _ in range(n)).encode()


def _set_limits():
    resource.setrlimit(resource.RLIMIT_AS, (_AS_LIMIT, _AS_LIMIT))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


# Each generator returns (argv_after_applet, stdin_bytes).  argv[0] is the
# applet name supplied by the harness.  Inputs stay short and bounded so a
# full sweep finishes in bounded time.
def _gen(rng, target):
    a = _alphabet(rng)
    if target == "getopt32":
        opts = ["-", "--", "-z", "-q", "--bogus", "-vv", "-n", "value", "a=b"]
        return ["getopt"] + [rng.choice(opts) for _ in range(rng.randint(1, 8))], b""
    if target == "regex":
        # Exercise grep's ERE parser through -e with malformed patterns.
        pat = _rand_bytes(rng, rng.randint(0, 18), a + "()[]{}|*+?^$\\")
        return ["grep", "-e", pat.decode("latin1"), "-"], \
            _rand_bytes(rng, rng.randint(0, 40), "abc\n")
    if target == "sed":
        expr = _rand_bytes(rng, rng.randint(0, 20), a + "/s(){}")
        return ["sed", expr.decode("latin1")], _rand_bytes(rng, rng.randint(0, 40), "ab\n")
    if target == "awk":
        prog = _rand_bytes(rng, rng.randint(0, 24), a + "{};$/")
        return ["awk", prog.decode("latin1")], _rand_bytes(rng, rng.randint(0, 40), "1 2\n")
    if target == "shell":
        script = _rand_bytes(rng, rng.randint(0, 40), a + "();`")
        return ["sh", "-c", script.decode("latin1")], b""
    if target in ("tar", "cpio"):
        blob = _rand_bytes(rng, rng.randint(0, 64), a)
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(blob)
            path = f.name
        mode = rng.choice(["-t", "-tv", "-x", "--bogus"])
        return [target, mode, "-f", path], b""
    if target in ("gzip", "bzip2", "xz", "lzop"):
        blob = _rand_bytes(rng, rng.randint(0, 64), a)
        return [target, "-cd"], blob
    if target == "dns":
        # nslookup with a malformed name exercises label parsing without I/O.
        q = _rand_bytes(rng, rng.randint(0, 24), "abcdef.-0123")
        return ["nslookup", q.decode("latin1")], b""
    if target == "dhcp":
        # dumpleases parses a lease file; feed it random bytes.
        blob = _rand_bytes(rng, rng.randint(0, 80), a + "\n")
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(blob)
            path = f.name
        return ["dumpleases", "-f", path], b""
    if target == "http":
        # httpd rejects malformed option combinations before listening.
        opt = rng.choice(["-f", "-p", "-h", "-c", "--bogus", "-v"])
        val = rng.choice(["nonsense", "0", "-1", "99999", ""])
        return ["httpd", opt, val], b""
    if target == "tls":
        # ssl_client/ssl_server option parsing and malformed config.
        opt = rng.choice(["-s", "-p", "-c", "-k", "--bogus", "-v"])
        val = rng.choice(["nonsense", "/no/such/file", "0", "-1", ""])
        prog = "ssl_client" if rng.getrandbits(1) else "ssl_server"
        return [prog, opt, val], b""
    raise ValueError("unknown fuzz target: " + target)


def _run(binary, argv, stdin, cwd, timeout):
    try:
        p = subprocess.run(
            [binary] + argv, input=stdin, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=cwd, timeout=timeout,
            preexec_fn=_set_limits,
        )
    except subprocess.TimeoutExpired:
        return "hang", None, b"", b""
    except OSError as exc:
        return "error:" + str(exc), None, b"", b""
    if p.returncode < 0 or p.returncode >= 128:
        # Negative = signal; >=128 = shell-style signal encoding.  137 is
        # SIGKILL, which is how the RLIMIT_AS breach presents itself.
        kind = "oom" if p.returncode == -9 or p.returncode == 137 else "crash"
        return kind, p.returncode, p.stdout, p.stderr
    return "ok", p.returncode, p.stdout, p.stderr


def fuzz(ref, zig, iterations, seed, targets, timeout):
    rng = random.Random(seed)
    results = []
    for target in targets:
        for i in range(iterations):
            argv, stdin = _gen(rng, target)
            with tempfile.TemporaryDirectory(prefix="bb-fuzz-") as td:
                rk, rc, ro, re_ = _run(ref, argv, stdin, td, timeout)
                zk, zc, zo, ze = _run(zig, argv, stdin, td, timeout)
            if "crash" in (rk, zk) or "hang" in (rk, zk) or "oom" in (rk, zk) or \
                    rk.startswith("error") or zk.startswith("error"):
                status = rk if rk != "ok" else zk
            elif (rc, ro, re_) == (zc, zo, ze):
                status = "pass"
            else:
                status = "divergence"
            results.append({
                "target": target, "seed": seed, "index": i,
                "argv": argv, "status": status,
                "ref": {"kind": rk, "exit": rc},
                "zig": {"kind": zk, "exit": zc},
            })
            if status in ("crash", "hang", "oom") or status.startswith("error"):
                results[-1]["detail"] = {
                    "ref_stderr": re_[:400].decode("latin1"),
                    "zig_stderr": ze[:400].decode("latin1"),
                }
    return results


def ref_available(path):
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ref", help="reference busybox binary; SKIP when absent")
    ap.add_argument("--zig", required=True)
    ap.add_argument("--iterations", type=int, default=12)
    ap.add_argument("--seed", type=int, default=20261124)
    ap.add_argument("--timeout", type=float, default=3.0)
    ap.add_argument("--targets", nargs="*", default=list(TARGETS))
    ap.add_argument("--out", default=None)
    ap.add_argument("--smoke", action="store_true",
                    help="short sweep: 3 iterations per target")
    args = ap.parse_args(argv)
    if args.smoke:
        args.iterations = 3
    bad = [t for t in args.targets if t not in TARGETS]
    if bad:
        ap.error("unknown target(s): " + ", ".join(bad))

    if not ref_available(args.ref):
        reason = "reference binary not available at %s" % (args.ref or "<unset>")
        print("SKIP: " + reason + "; fuzz-smoke skipped")
        summary = {
            "status": "skip", "reason": reason,
            "ref": args.ref, "zig": args.zig,
            "iterations": args.iterations, "seed": args.seed,
            "targets": list(args.targets),
            "counts": {"skip": 1}, "results": [],
        }
        if args.out:
            with open(args.out, "w") as f:
                json.dump(summary, f, indent=2)
            print("wrote", args.out)
        return 0

    results = fuzz(os.path.abspath(args.ref), os.path.abspath(args.zig),
                   args.iterations, args.seed, args.targets, args.timeout)
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    summary = {
        "status": "complete",
        "ref": args.ref, "zig": args.zig, "iterations": args.iterations,
        "seed": args.seed, "targets": list(args.targets),
        "counts": counts, "results": results,
    }
    print(json.dumps({"counts": counts}, indent=2))
    if args.out:
        with open(args.out, "w") as f:
            json.dump(summary, f, indent=2)
        print("wrote", args.out)
    hard = sum(v for k, v in counts.items()
               if k in ("crash", "hang", "oom") or k.startswith("error"))
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main())
