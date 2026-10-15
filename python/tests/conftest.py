import base64
import http.client
import os
import socket
import struct

import pytest

from bearings import Server


class Client:
    """Requests to a running server, one connection each."""

    def __init__(self, port: int) -> None:
        self.port = port

    def request(self, method="GET", path="/", body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            response.body = response.read()
            return response
        finally:
            conn.close()

    def raw(self, data: bytes) -> bytes:
        """Send raw bytes; everything the server answers until it closes."""
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as sock:
            sock.sendall(data)
            chunks = []
            while chunk := sock.recv(65536):
                chunks.append(chunk)
            return b"".join(chunks)


@pytest.fixture()
def serve():
    """`serve(app, **options)` starts a server on a free port and returns a
    `Client` for it; the servers stop at the end of the test."""
    servers = []

    def start(app, **options):
        options.setdefault("host", "127.0.0.1")
        options.setdefault("loops", 2)
        options.setdefault("workers", 4)
        server = Server(app, **options)
        server.start()
        servers.append(server)
        client = Client(server.port)
        client.server = server
        return client

    yield start
    for server in servers:
        server.stop(grace=1)
        server.wait()


class WsClient:
    """A minimal WebSocket client (RFC 6455), for the tests."""

    def __init__(self, port, path="/", headers=(), timeout=10):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            + "".join(f"{name}: {value}\r\n" for name, value in headers)
            + "\r\n"
        )
        self.sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                break
            head += chunk
        self.status = int(head.split(b" ", 2)[1]) if head else 0
        self.buffer = b""
        self.closing = False

    def send(self, payload, opcode=1):
        if isinstance(payload, str):
            payload = payload.encode()
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            header = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
        elif n < 65536:
            header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def frame(self):
        """The next frame: `(opcode, payload)`."""
        first, second = self._read(2)
        n = second & 0x7F
        if n == 126:
            n = struct.unpack("!H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self._read(8))[0]
        return first & 0x0F, self._read(n)

    def recv(self):
        """The next data message, skipping pings; `None` for a close frame."""
        while True:
            opcode, payload = self.frame()
            if opcode == 1:
                return payload.decode()
            if opcode == 2:
                return payload
            if opcode == 8:
                # as a browser does: answer a close the server began, then
                # close the socket, which the server waits for
                self.close_code = struct.unpack("!H", payload[:2])[0] if payload else None
                if not self.closing:
                    self.close(self.close_code or 1000)
                self.shut()
                return None

    def close(self, code=1000, reason=""):
        self.closing = True
        self.send(struct.pack("!H", code) + reason.encode(), opcode=8)

    def shut(self):
        self.sock.close()
