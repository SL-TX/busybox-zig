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
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

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
