"""The in-process HTTP/1 proxy of the via_proxy cases (SPEC.md section 8):
- it serves the accepted connections one at a time, each until the client
  closes it, one request after another;
- it rewrites the request target to http://127.0.0.1:<server port><path>
  (the path only, the query dropped) and sends the request upstream on a
  new connection, as HTTP/1.1, with the client's fields (names in
  lowercase) and body (Content-Length or chunked, as received);
- it reads the whole response, removes the Connection field, adds a Date
  field when the response has none, and sends it back with the body's
  length in Content-Length (no body for HEAD, 1xx, 204 and 304).

Test tooling only."""

import email.utils
import socket
import sys
import threading

from .bytestr import CaseError, show, trim_ctl


class Sock:
    """A blocking socket with a byte buffer."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.eof = False

    def fill(self) -> bool:
        if self.eof:
            return False
        try:
            chunk = self.sock.recv(65536)
        except OSError:
            chunk = b""
        if not chunk:
            self.eof = True
            return False
        self.buf += chunk
        return True

    def line(self):
        """A line up to CRLF (without it); None at EOF before one."""
        while True:
            p = self.buf.find(b"\r\n")
            if p >= 0:
                out = self.buf[:p]
                self.buf = self.buf[p + 2 :]
                return out
            if not self.fill():
                return None

    def take(self, n: int):
        while len(self.buf) < n:
            if not self.fill():
                return None
        out = self.buf[:n]
        self.buf = self.buf[n:]
        return out

    def send(self, b: bytes) -> None:
        try:
            self.sock.sendall(b)
        except OSError as e:
            raise CaseError(f"send failed: {e.strerror}") from None


def read_head(s: Sock):
    """(first line, [(name, value)]) or None when the peer closed first."""
    first = s.line()
    if first is None:
        return None
    fields = []
    while True:
        line = s.line()
        if line is None:
            raise CaseError("connection ended inside a head")
        if line == b"":
            return first, fields
        c = line.find(b":")
        if c < 0:
            raise CaseError(f"malformed field line {show(line, 200)}")
        fields.append((line[:c], trim_ctl(line[c + 1 :])))


def field_of(fields, name: bytes):
    for n, v in fields:
        if n.lower() == name:
            return v
    return None


def is_chunked(fields) -> bool:
    values = [v for n, v in fields if n.lower() == b"transfer-encoding"]
    if not values:
        return False
    last = b",".join(values).rsplit(b",", 1)[-1]
    return trim_ctl(last).lower() == b"chunked"


def read_chunked(s: Sock) -> bytes:
    """The decoded body of a chunked message; the trailer section is dropped."""
    out = []
    while True:
        line = s.line()
        if line is None:
            raise CaseError("connection ended inside a chunked body")
        size_text = trim_ctl(line.split(b";", 1)[0])
        if not size_text or any(c not in b"0123456789abcdefABCDEF" for c in size_text):
            raise CaseError(f"invalid chunk size line {show(line, 200)}")
        size = int(size_text, 16)
        if size == 0:
            while True:
                line = s.line()
                if line is None:
                    raise CaseError("connection ended inside a trailer section")
                if line == b"":
                    return b"".join(out)
        data = s.take(size + 2)
        if data is None:
            raise CaseError("connection ended inside a chunk")
        out.append(data[:size])


def read_body(s: Sock, fields, close: bool) -> bytes:
    """The body by Content-Length, chunked, or (close) until EOF."""
    if is_chunked(fields):
        return read_chunked(s)
    cl = field_of(fields, b"content-length")
    if cl is not None:
        if not cl.isdigit():
            raise CaseError(f"invalid content-length {show(cl, 50)}")
        body = s.take(int(cl))
        if body is None:
            raise CaseError("connection ended inside a body")
        return body
    if close:
        while s.fill():
            pass
        body, s.buf = s.buf, b""
        return body
    return b""


def target_path(t: bytes) -> bytes:
    """The path of a request target, without the query: "/" for none."""
    p = t.find(b"://")
    if p >= 0:
        t = t[p + 3 :]
        q = t.find(b"/")
        t = b"" if q < 0 else t[q:]
    t = t.split(b"?", 1)[0].split(b"#", 1)[0]
    return t or b"/"


def http_date() -> bytes:
    return email.utils.formatdate(usegmt=True).encode("ascii")


def proxy_one(client: Sock, server_port: int) -> bool:
    """One request from the client, forwarded; False when the client closed."""
    head = read_head(client)
    if head is None:
        return False
    req_line, req_fields = head
    parts = req_line.split(b" ")
    if len(parts) < 3:
        raise CaseError(f"malformed request line {show(req_line, 200)}")
    method, target = parts[0], parts[1]
    chunked = is_chunked(req_fields)
    body = read_body(client, req_fields, False)

    out = [
        method
        + b" http://127.0.0.1:"
        + str(server_port).encode()
        + target_path(target)
        + b" HTTP/1.1\r\n"
    ]
    for n, v in req_fields:
        out.append(n.lower() + b": " + v + b"\r\n")
    out.append(b"\r\n")
    if chunked:
        if body:
            out.append(f"{len(body):x}".encode() + b"\r\n" + body + b"\r\n")
        out.append(b"0\r\n\r\n")
    else:
        out.append(body)

    try:
        upstream = socket.create_connection(("127.0.0.1", server_port))
    except OSError as e:
        raise CaseError(f"connect to the server failed: {e.strerror}") from None
    up = Sock(upstream)
    try:
        up.send(b"".join(out))
        # skip interim (1xx) responses other than 101
        while True:
            resp = read_head(up)
            if resp is None:
                raise CaseError("the server closed the connection without a response")
            resp_line, resp_fields = resp
            code = resp_line[9:12]
            status = int(code) if code.isdigit() else 0
            if status < 100 or status >= 200 or status == 101:
                break
        no_body = method.upper() == b"HEAD" or status < 200 or status in (204, 304)
        rbody = b"" if no_body else read_body(up, resp_fields, True)
    finally:
        upstream.close()

    out = [b"HTTP/1.1 " + resp_line[9:] + b"\r\n"]
    for n, v in resp_fields:
        if n.lower() not in (b"connection", b"content-length", b"transfer-encoding"):
            out.append(n.lower() + b": " + v + b"\r\n")
    if field_of(resp_fields, b"date") is None:
        out.append(b"date: " + http_date() + b"\r\n")
    if not no_body:
        out.append(b"content-length: " + str(len(rbody)).encode() + b"\r\n")
    out.append(b"\r\n" + rbody)
    client.send(b"".join(out))
    return True


class Proxy:
    def __init__(self, server_port: int):
        self.server_port = server_port
        self.stop = False
        try:
            self.listener = socket.create_server(("127.0.0.1", 0), backlog=16)
        except OSError as e:
            raise CaseError(f"proxy bind failed: {e.strerror}") from None
        self.port = self.listener.getsockname()[1]
        self.listener.settimeout(0.05)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stop:
            try:
                fd, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError as e:
                if self.stop:
                    break
                print(f"runner proxy: accept error: {e.strerror}", file=sys.stderr)
                continue
            client = Sock(fd)
            try:
                while not self.stop and proxy_one(client, self.server_port):
                    pass
            except Exception as e:  # noqa: BLE001 - reported, the proxy goes on
                print(f"runner proxy: {e}", file=sys.stderr)
            fd.close()

    def destroy(self) -> None:
        self.stop = True
        self.thread.join()
        self.listener.close()
