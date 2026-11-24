"""Output normalization for differential parity cases.

Every rule is *explicit*: the harness never guesses that two outputs differ
"only by a PID" unless the case declared ``"normalize": ["pid"]``.  The single
exception is ``tmp_path``: the two sides run in different sandbox roots, so the
absolute root path is always replaced with ``<TMP>`` for both observations.

Supported rules (from the Shared Interfaces section of the plan):

``tmp_path``
    Replace the sandbox root with ``<TMP>``.  Applied globally; listing it in
    ``rules`` is harmless but unnecessary.
``pid`` / ``uid`` / ``gid``
    Replace ``key=<number>`` style values with ``<PID>`` / ``<UID>`` / ``<GID>``.
``hostname``
    Replace the current hostname with ``<HOST>``.
``timestamp``
    Replace ISO, ctime and clock timestamps with ``<TIMESTAMP>``.  This is the
    rule that absorbs the build timestamp in the ``--version`` banner.
``sort_lines``
    Sort lines; used where an ordering is explicitly documented as unstable.
``regex:<pattern>``
    Replace every match of ``<pattern>`` with ``<MATCH>``.
"""

from __future__ import annotations

import os
import re
import socket

# Patterns are deliberately specific: a normalizer must not silently hide a
# real output difference.  Group 1 is the stable prefix, group 2 the value.
_PID_RE = re.compile(r"\b(pid[=:]\s*|PID\s+)(\d+)")
_UID_RE = re.compile(r"\b(uid[=:]\s*|UID\s+)(\d+)")
_GID_RE = re.compile(r"\b(gid[=:]\s*|GID\s+)(\d+)")
_TIMESTAMP_RES = (
    # ctime-style "current date" output (e.g. "Sat Nov 21 17:35:34 UTC 2026"):
    # weekday, day-of-month, clock and year all change between recordings.
    # This must run before the clock-only pattern below, which would otherwise
    # leave the volatile weekday/day/year in the golden.
    re.compile(
        r"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+"
        r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+"
        r"\d{1,2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+[A-Za-z]{2,5}\s+\d{4}\b"
    ),
    re.compile(r"\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\s+[A-Za-z]{2,5})?"),
    re.compile(
        r"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+"
        r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+"
        r"\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4}\b"
    ),
    re.compile(r"\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b"),
)


def _replace_value(pattern: re.Pattern[str], text: str, token: str) -> str:
    """Replace the numeric part of a ``key=<number>`` match with a token."""
    return pattern.sub(lambda m: m.group(1) + token, text)


def apply(text: str, rules, *, root: str | None = None) -> str:
    """Return ``text`` with the declared normalizations applied.

    ``rules`` is the case's ``normalize`` list.  ``root`` is the sandbox path
    used by the ``tmp_path`` rule; when omitted the rule is a no-op (useful when
    normalizing already-relative text in unit tests).
    """
    if root:
        # Replace both the lexical root and its realpath: a sandbox may itself
        # live under a symlinked scratch directory.
        for candidate in dict.fromkeys((root, os.path.realpath(root))):
            if candidate:
                text = text.replace(candidate, "<TMP>")

    for rule in rules or []:
        if rule == "tmp_path":
            continue  # already applied globally above
        if rule == "pid":
            text = _replace_value(_PID_RE, text, "<PID>")
        elif rule == "uid":
            text = _replace_value(_UID_RE, text, "<UID>")
        elif rule == "gid":
            text = _replace_value(_GID_RE, text, "<GID>")
        elif rule == "hostname":
            host = socket.gethostname()
            if host:
                text = text.replace(host, "<HOST>")
        elif rule == "timestamp":
            for pattern in _TIMESTAMP_RES:
                text = pattern.sub("<TIMESTAMP>", text)
        elif rule == "sort_lines":
            had_trailing_newline = text.endswith("\n")
            lines = sorted(text.splitlines())
            text = "\n".join(lines)
            if had_trailing_newline and lines:
                text += "\n"
        elif rule.startswith("regex:"):
            text = re.sub(rule[len("regex:"):], "<MATCH>", text)
        else:
            raise ValueError("unknown normalization rule: " + rule)
    return text
