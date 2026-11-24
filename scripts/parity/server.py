"""Minimal deterministic loopback TCP servers for parity cases.

A case with a ``server`` object gets a server bound to 127.0.0.1 on an
ephemeral port.  The port is exposed to the case as ``<PORT>`` in argv (and
stdin).  Each observation starts its own server, so reference and Zig runs are
independent; the harness normalizes the ephemeral port to ``<PORT>`` in the
captured output before comparing.

Supported modes:

``echo``        read all client data, send it back, close.
``delayed``     read the request, wait ``delay_ms``, send ``data``, close.
``timed_echo``  read all client data, report ``early_data`` / ``late_data``
                depending on whether the first byte arrived before
                ``threshold_ms`` after accept (used to observe nc -i).
``partial_once`` first connection sends a truncated HTTP response with a
                Content-Length larger than the body; the second sends the
                complete response (used to observe wget -t retries).
"""

from __future__ import annotations

import socket
import threading
import time
from typing import Any


class LoopbackServer:
    def __init__(self, spec: dict[str, Any]):
        self.spec = spec
        self.is_udp = spec.get("proto") == "udp"
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if self.is_udp else socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        if not self.is_udp:
            self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self._stop = False
        self.transcript_path = spec.get("transcript")
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _log(self, line: str) -> None:
        if not self.transcript_path:
            return
        try:
            with open(self.transcript_path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def _accept(self, timeout: float = 6.0):
        self.sock.settimeout(0.1)
        deadline = time.time() + timeout
        while time.time() < deadline and not self._stop:
            try:
                conn, _ = self.sock.accept()
                return conn
            except socket.timeout:
                continue
            except OSError:
                return None
        return None

    @staticmethod
    def _read_all(conn, timeout: float = 5.0) -> bytes:
        conn.settimeout(timeout)
        out = bytearray()
        try:
            while True:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        return bytes(out)

    @staticmethod
    def _send(conn, data: str) -> None:
        try:
            conn.sendall(data.encode())
        except OSError:
            pass

    def _run(self) -> None:
        mode = self.spec.get("mode", "echo")
        if self.is_udp:
            self._run_udp(mode)
            return
        conn = self._accept()
        if conn is None:
            return
        try:
            if mode in ("nbd_old", "nbd_new", "nbd_bad"):
                self._run_nbd(conn, mode)
                return
            if mode == "smtp":
                self._run_smtp(conn)
                return
            if mode == "pop3":
                self._run_pop3(conn)
                return
            if mode == "echo":
                data = self._read_all(conn)
                conn.sendall(data)
            elif mode == "delayed":
                self._read_all(conn, timeout=1.0)
                time.sleep(self.spec.get("delay_ms", 0) / 1000.0)
                self._send(conn, self.spec.get("data", ""))
            elif mode == "timed_echo":
                started = time.time()
                conn.settimeout(5.0)
                first = None
                buf = bytearray()
                try:
                    while True:
                        chunk = conn.recv(8192)
                        if not chunk:
                            break
                        if first is None:
                            first = time.time()
                        buf += chunk
                except OSError:
                    pass
                early = first is not None and (first - started) * 1000 < self.spec.get("threshold_ms", 1000)
                self._send(conn, self.spec.get("early_data", "EARLY\n") if early
                           else self.spec.get("late_data", "LATE\n"))
            elif mode in ("partial_once", "partial_n"):
                try:
                    failures = int(self.spec.get("fail_count", 1))
                except (TypeError, ValueError):
                    failures = 1
                for _ in range(failures):
                    self._read_all(conn, timeout=1.0)
                    self._send(conn, self.spec.get("partial_data", "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nSHORT"))
                    conn.close()
                    conn = self._accept()
                    if conn is None:
                        return
                self._read_all(conn, timeout=1.0)
                self._send(conn, self.spec.get("full_data", "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nHELLOWORLD"))
        finally:
            if conn is not None:
                try:
                    conn.close()
                except OSError:
                    pass

    @staticmethod
    def _lines(conn, buf: bytearray):
        """Yield CR/LF-terminated command lines read from ``conn``."""
        while b"\n" in buf:
            raw, rest = bytes(buf).split(b"\n", 1)
            del buf[:]
            buf.extend(rest)
            yield raw.rstrip(b"\r").decode("utf-8", "replace")

    def _run_smtp(self, conn) -> None:
        """Deterministic ESMTP dialog for the sendmail applet.

        All responses are fixed strings from the case spec (with sane
        defaults), so a verbose ``sendmail -v`` run produces a reproducible
        send:/recv: transcript.  No real mail is ever transferred.
        """
        spec = self.spec
        conn.settimeout(2.0)
        self._send(conn, spec.get("greeting", "220 test ESMTP ready\r\n"))
        data_mode = False
        auth_phase = ""
        buf = bytearray()
        try:
            while True:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                buf.extend(chunk)
                for line in self._lines(conn, buf):
                    self._log("C: " + line)
                    upper = line.upper()
                    if data_mode:
                        if line == ".":
                            data_mode = False
                            self._send(conn, spec.get("data_ok", "250 2.0.0 Ok: queued\r\n"))
                        continue
                    if upper.startswith(("EHLO", "HELO")):
                        if upper.startswith("EHLO"):
                            for ln in spec.get("ehlo_lines", ["250-test", "250 8BITMIME"]):
                                self._send(conn, ln + "\r\n")
                        else:
                            self._send(conn, "250 OK\r\n")
                    elif upper.startswith("AUTH PLAIN"):
                        self._send(conn, "334 UGFzc3dvcmQ6\r\n")
                        auth_phase = "plain"
                    elif upper.startswith("AUTH LOGIN"):
                        self._send(conn, "334 VXNlcm5hbWU6\r\n")
                        auth_phase = "login_user"
                    elif auth_phase == "plain":
                        self._send(conn, "235 2.7.0 Authentication successful\r\n")
                        auth_phase = ""
                    elif auth_phase == "login_user":
                        self._send(conn, "334 UGFzc3dvcmQ6\r\n")
                        auth_phase = "login_pass"
                    elif auth_phase == "login_pass":
                        self._send(conn, "235 2.7.0 Authentication successful\r\n")
                        auth_phase = ""
                    elif upper.startswith("MAIL FROM"):
                        self._send(conn, "250 2.1.0 Ok\r\n")
                    elif upper.startswith("RCPT TO"):
                        if spec.get("reject_rcpt"):
                            self._send(conn, "550 5.1.1 Rejected\r\n")
                        else:
                            self._send(conn, "250 2.1.5 Ok\r\n")
                    elif upper.startswith("DATA"):
                        if spec.get("reject_data"):
                            self._send(conn, "554 5.7.1 Rejected\r\n")
                        else:
                            self._send(conn, "354 End data with <CR><LF>.<CR><LF>\r\n")
                            data_mode = True
                    elif upper.startswith("NOOP"):
                        self._send(conn, "250 2.0.0 Ok\r\n")
                    elif upper.startswith("QUIT"):
                        self._send(conn, "221 2.0.0 Bye\r\n")
                        return
                    else:
                        self._send(conn, "250 2.0.0 Ok\r\n")
        except OSError:
            pass

    def _run_pop3(self, conn) -> None:
        """Deterministic POP3 dialog for the popmaildir applet."""
        spec = self.spec
        conn.settimeout(2.0)
        self._send(conn, spec.get("greeting", "+OK POP3 ready\r\n"))
        messages = [str(m) for m in spec.get("messages", [
            "From: a@b\r\nSubject: one\r\n\r\nFirst message body\r\n",
            "From: c@d\r\nSubject: two\r\n\r\nSecond message body\r\n",
        ])]
        deleted = set()
        buf = bytearray()
        try:
            while True:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                buf.extend(chunk)
                for line in self._lines(conn, buf):
                    self._log("C: " + line)
                    upper = line.upper()
                    if upper.startswith("USER") or upper.startswith("PASS") or upper.startswith("APOP"):
                        if spec.get("reject_pass") and upper.startswith("PASS"):
                            self._send(conn, "-ERR authentication failed\r\n")
                        else:
                            self._send(conn, "+OK user accepted\r\n")
                    elif upper.startswith("STAT"):
                        live = [i for i in range(len(messages)) if i not in deleted]
                        size = sum(len(messages[i].encode()) for i in live)
                        self._send(conn, "+OK %d %d\r\n" % (len(live), size))
                    elif upper.startswith(("RETR", "TOP")):
                        parts = upper.split()
                        idx = int(parts[1]) - 1 if len(parts) > 1 else -1
                        if 0 <= idx < len(messages):
                            body = messages[idx]
                            if upper.startswith("TOP") and len(parts) > 2:
                                nlines = int(parts[2])
                                body = "\r\n".join(body.split("\r\n")[:nlines]) + "\r\n"
                            self._send(conn, "+OK %d octets\r\n" % len(body.encode()))
                            self._send(conn, body)
                            self._send(conn, ".\r\n")
                        else:
                            self._send(conn, "-ERR no such message\r\n")
                    elif upper.startswith("DELE"):
                        parts = upper.split()
                        if len(parts) > 1:
                            deleted.add(int(parts[1]) - 1)
                        self._send(conn, "+OK message deleted\r\n")
                    elif upper.startswith("QUIT"):
                        self._send(conn, "+OK bye\r\n")
                        return
                    else:
                        self._send(conn, "+OK\r\n")
        except OSError:
            pass

    def _run_nbd(self, conn, mode: str) -> None:
        """Deterministic NBD handshake peek (no real block device is touched).

        Sends the fixed-size handshake the client expects, optionally consumes
        the new-style option request, then holds the socket open briefly so the
        client can finish its (failing) device ioctl path.
        """
        import struct

        conn.settimeout(1.0)
        try:
            if mode == "nbd_bad":
                conn.sendall(b"BADMAGIC!" + b"\0" * 8)
            elif mode == "nbd_old":
                conn.sendall(b"NBDMAGIC" + bytes.fromhex("0000420281861253")
                             + struct.pack(">Q", 1024 * 1024)
                             + struct.pack(">I", 0) + b"\0" * 124)
            else:
                conn.sendall(b"NBDMAGIC" + b"IHAVEOPT" + struct.pack(">H", 0))
                # The client sends client_flags (4 bytes) followed by the
                # NBD_OPT_EXPORT_NAME request (16-byte header + name).
                req = self.spec.get("expect_request", "")
                want = 4 + 16 + len(req)
                buf = b""
                while len(buf) < want:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                conn.sendall(struct.pack(">Q", 1024 * 1024)
                             + struct.pack(">H", 0) + b"\0" * 124)
            self._read_all(conn, timeout=1.0)
        except OSError:
            pass

    def _run_udp(self, mode: str) -> None:
        self.sock.settimeout(0.1)
        deadline = time.time() + 8.0
        while time.time() < deadline and not self._stop:
            try:
                data, peer = self.sock.recvfrom(8192)
            except socket.timeout:
                continue
            except OSError:
                return
            if mode == "tftp_error":
                code = self.spec.get("error_code", 1)
                msg = self.spec.get("error_msg", "file not found")
                reply = b"\x00\x05" + code.to_bytes(2, "big") + msg.encode() + b"\x00"
                try:
                    self.sock.sendto(reply, peer)
                except OSError:
                    pass
                return
            if mode == "tftp_oack":
                # ERROR after an OACK still terminates the transfer cleanly.
                reply = b"\x00\x05\x00\x01" + b"file not found\x00"
                try:
                    self.sock.sendto(reply, peer)
                except OSError:
                    pass
                return

    def stop(self) -> None:
        self._stop = True
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)
