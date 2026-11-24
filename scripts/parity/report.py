#!/usr/bin/env python3
"""Generate a compact Markdown parity report from machine-readable results.

Inputs:
  --fuzz REPORT.json    output of scripts/parity/fuzz.py
  --differential LOG    captured stdout of scripts/parity/run.py --all
  --golden LOG          captured stdout of the golden-mode run
  --out FILE           write Markdown here (default: stdout)

The generator only formats counts and residual gaps; it never suppresses a
failure.  Known divergences must be listed explicitly via --residual so the
final report states them in prose rather than hiding them behind a normalizer.

Usage:
  python3 scripts/parity/report.py \\
      --fuzz fuzz-report.json --differential diff.log --golden golden.log \\
      --residual "shell ash_test: 100/327 divergences (breaker ruling)" \\
      --out parity-report.md
"""

from __future__ import annotations

import argparse
import json
import re
import sys


def _count_log(path):
    """Extract the trailing '<n> passed, ...' summary from a harness log."""
    if not path:
        return None
    text = open(path, errors="replace").read()
    matches = re.findall(
        r"(\d+) passed, (\d+) failed, (\d+) known-failures, "
        r"(\d+) skipped, (\d+) errors", text)
    if not matches:
        return None
    n = matches[-1]
    return dict(zip(
        ("passed", "failed", "known_failures", "skipped", "errors"),
        map(int, n)))


def _fmt_counts(c):
    if c is None:
        return "_no summary line found_"
    return ("{passed} passed / {failed} failed / {skipped} skipped / "
            "{errors} errors / {known_failures} known-failures").format(**c)


def generate(fuzz_path, differential, golden, residuals):
    lines = ["# Parity verification report", ""]
    lines.append("## Differential suite")
    lines.append("")
    lines.append(_fmt_counts(_count_log(differential)))
    lines.append("")
    lines.append("## Golden suite")
    lines.append("")
    lines.append(_fmt_counts(_count_log(golden)))
    lines.append("")
    lines.append("## Fuzz / smoke")
    lines.append("")
    if fuzz_path:
        data = json.load(open(fuzz_path))
        counts = data.get("counts", {})
        per_target = {}
        for r in data.get("results", []):
            d = per_target.setdefault(r["target"], {})
            d[r["status"]] = d.get(r["status"], 0) + 1
        lines.append("Seed %s, %s iterations/target. Counts: %s" % (
            data.get("seed"), data.get("iterations"),
            ", ".join("%s=%d" % kv for kv in sorted(counts.items()))))
        lines.append("")
        lines.append("| Target | Results |")
        lines.append("|---|---|")
        for t in sorted(per_target):
            d = per_target[t]
            lines.append("| %s | %s |" % (
                t, ", ".join("%s=%d" % kv for kv in sorted(d.items()))))
        hard = [r for r in data.get("results", [])
                if r["status"] in ("crash", "hang", "oom")
                or r["status"].startswith("error")]
        lines.append("")
        lines.append("Hard failures (crash/hang/OOM): %d" % len(hard))
    else:
        lines.append("_no fuzz report supplied_")
    lines.append("")
    lines.append("## Residuals (explicit, not normalized away)")
    lines.append("")
    if residuals:
        for r in residuals:
            lines.append("- " + r)
    else:
        lines.append("- none declared")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fuzz")
    ap.add_argument("--differential")
    ap.add_argument("--golden")
    ap.add_argument("--residual", action="append", default=[])
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    text = generate(args.fuzz, args.differential, args.golden, args.residual)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
        print("wrote", args.out)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
