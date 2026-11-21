"""Linux namespace helper for sandboxed parity cases.

``run_ns`` wraps ``unshare(1)`` so a case can request an isolated namespace
(kind: net, mnt/mount, pid, uts, ipc, user or cgroup).  It returns a normal
``subprocess.CompletedProcess`` and never skips a case by itself: if the host
cannot create the namespace it raises ``NsUnavailable`` and the harness turns
that into a SKIP *only* when the case declared the capability in ``requires``.
"""

from __future__ import annotations

import shutil
import subprocess

_ALLOWED_KINDS = {"net", "mnt", "mount", "pid", "uts", "ipc", "user", "cgroup"}


class NsUnavailable(Exception):
    """The host cannot create the requested namespace."""


class NsTimeout(Exception):
    """The namespaced child exceeded the supplied deadline."""


def run_ns(kind: str, argv: list[str], timeout: float = 30.0) -> subprocess.CompletedProcess:
    """Run ``argv`` inside a ``kind`` namespace and return its CompletedProcess."""
    if kind not in _ALLOWED_KINDS:
        raise ValueError("unknown namespace kind: " + kind)
    unshare = shutil.which("unshare")
    if not unshare:
        raise NsUnavailable("unshare(1) is not installed")
    flag = "--mount" if kind in ("mnt", "mount") else "--" + kind
    cmd = [unshare, flag, "--fork", "--", *argv]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise NsTimeout("namespaced child timed out after %g s" % timeout) from exc
    except (FileNotFoundError, PermissionError, OSError) as exc:
        raise NsUnavailable("unshare failed: %s" % exc) from exc

    stderr = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0 and (
        "Operation not permitted" in stderr or "unshare: unshare failed" in stderr
    ):
        raise NsUnavailable(stderr.strip())
    return proc
