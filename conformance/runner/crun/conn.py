"""A client connection of the conformance runner: a TCP socket with a
timeout per read and per write, the bytes received but not yet used by a
step, and the end state, which stays once reached ("eof": the peer sent
FIN; "reset": ECONNRESET or ECONNABORTED).

Also: the monotonic clock used for every time in the runner.

Test tooling only."""

import socket
import time

from .bytestr import CaseError

DEFAULT_TIMEOUT_MS = 1000

OPEN, EOF, RESET = "open", "eof", "reset"
DATA, TIMEOUT = "data", "timeout"


def now_us() -> int:
    return time.monotonic_ns() // 1000


def sleep_ms(ms: int) -> None:
    if ms > 0:
        time.sleep(ms / 1000)


class Conn:
    def __init__(self, port: int, nodelay: bool):
        self.buf = b""
        self.end = OPEN
        self.sock = None
        try:
            self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        except OSError as e:
            raise CaseError(
                f"connect to 127.0.0.1:{port} failed: {e.strerror or e}"
            ) from None
        self.connected_at = now_us()
        try:
            self.sock.setsockopt(
                socket.IPPROTO_TCP, socket.TCP_NODELAY, 1 if nodelay else 0
            )
        except OSError as e:
            raise CaseError(f"set_nodelay: {e.strerror}") from None

    def _need_open(self):
        if self.sock is None:
            raise CaseError("connection was closed by a previous close step")

    def write_all(self, data: bytes, timeout_ms: int) -> None:
        self._need_open()
        self.sock.settimeout(max(timeout_ms, 1) / 1000)
        try:
            self.sock.sendall(data)
        except TimeoutError:
            raise CaseError(f"write failed: timed out after {timeout_ms} ms") from None
        except OSError as e:
            raise CaseError(f"write failed: {e.strerror} (errno {e.errno})") from None

    def shutdown_write(self) -> None:
        self._need_open()
        try:
            self.sock.shutdown(socket.SHUT_WR)
        except OSError as e:
            raise CaseError(f"shutdown(Write) failed: {e.strerror}") from None

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    @property
    def closed_locally(self) -> bool:
        return self.sock is None

    def read_some(self, timeout_ms: int) -> str:
        """One recv into buf, waiting at most timeout_ms: DATA, EOF, RESET or
        TIMEOUT."""
        if self.end != OPEN:
            return self.end
        self._need_open()
        self.sock.settimeout(max(timeout_ms, 1) / 1000)
        try:
            chunk = self.sock.recv(65536)
        except TimeoutError:
            return TIMEOUT
        except (ConnectionResetError, ConnectionAbortedError):
            self.end = RESET
            return RESET
        except OSError as e:
            raise CaseError(f"read failed: {e.strerror} (errno {e.errno})") from None
        if not chunk:
            self.end = EOF
            return EOF
        self.buf += chunk
        return DATA

    def take(self, maximum: int) -> bytes:
        out = self.buf[:maximum]
        self.buf = self.buf[len(out) :]
        return out
