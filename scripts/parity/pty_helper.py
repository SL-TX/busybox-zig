"""Pseudo-terminal helper for interactive parity cases.

``run_pty`` drives a child through a real PTY so terminal-detecting applets
behave as they would for a user.  The optional ``script`` is a list of steps;
each step is either a string to send immediately, or a ``(send, expect)`` pair
that is sent once ``expect`` has appeared in the transcript.  This lets a case
wait for a prompt before answering it without hard-coded sleeps.

Like ``ns.py``, this helper never skips silently: callers must declare the
capability in the case's ``requires`` list.  Missing capabilities raise
``PtyUnavailable``; a run that exceeds its deadline raises ``PtyTimeout``.
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import signal
import time


class PtyUnavailable(Exception):
    """The host cannot provide a usable pseudo-terminal."""


class PtyTimeout(Exception):
    """The PTY child exceeded the supplied deadline."""


def _as_bytes(value) -> bytes:
    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return value.encode("utf-8")
    raise TypeError("PTY script values must be str or bytes")


def _normalize_script(script) -> list[tuple[bytes, bytes | None]]:
    steps: list[tuple[bytes, bytes | None]] = []
    for item in script or []:
        if isinstance(item, (str, bytes)):
            steps.append((_as_bytes(item), None))
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            send, expect = item
            steps.append((_as_bytes(send), _as_bytes(expect) or None))
        else:
            raise TypeError("PTY script steps must be str, bytes or (send, expect)")
    return steps


def _terminate(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def run_pty(
    argv: list[str],
    script=None,
    timeout: float = 5.0,
    *,
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    stdin: bytes | None = None,
) -> tuple[str, int]:
    """Run ``argv`` on a PTY, feed ``script`` and return ``(stdout, exit_code)``.

    ``cwd`` and ``env`` are applied in the child before exec: a parity case
    must observe its own sandbox, not the harness checkout.  ``stdin`` (when
    present) is written to the PTY before the scripted steps.
    """
    if not os.path.exists("/dev/ptmx"):
        raise PtyUnavailable("no /dev/ptmx on this host")
    steps = _normalize_script(script)
    if stdin:
        steps.insert(0, (bytes(stdin), None))
    try:
        pid, master = pty.fork()
    except OSError as exc:
        raise PtyUnavailable("pty.fork failed: %s" % exc) from exc

    if pid == 0:  # child: slave fd is already stdin/stdout/stderr
        try:
            if cwd is not None:
                os.chdir(cwd)
            if env is not None:
                os.execve(argv[0], list(argv), dict(env))
            else:
                os.execv(argv[0], list(argv))
        except BaseException:
            os._exit(127)

    flags = fcntl.fcntl(master, fcntl.F_GETFL)
    fcntl.fcntl(master, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    output = bytearray()
    deadline = time.monotonic() + timeout
    step_index = 0
    status: int | None = None

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _terminate(pid)
                raise PtyTimeout("PTY child timed out after %g s" % timeout)

            readable, _, _ = select.select([master], [], [], min(0.1, remaining))
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except (OSError, BlockingIOError):
                    chunk = b""
                if chunk:
                    output.extend(chunk)
                else:
                    break  # slave closed: child has finished

            transcript = bytes(output)
            while step_index < len(steps):
                send, expect = steps[step_index]
                if expect is not None and expect not in transcript:
                    break
                if send:
                    try:
                        os.write(master, send)
                    except OSError:
                        pass
                step_index += 1

            got, wait_status = os.waitpid(pid, os.WNOHANG)
            if got == pid:
                status = wait_status
                while True:  # drain bytes buffered after the last select
                    try:
                        chunk = os.read(master, 65536)
                    except (OSError, BlockingIOError):
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                break

        if status is None:
            got, wait_status = os.waitpid(pid, 0)
            status = wait_status
    finally:
        os.close(master)

    return output.decode("utf-8", "replace"), os.waitstatus_to_exitcode(status)
