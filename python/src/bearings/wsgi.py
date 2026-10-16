"""WSGI (PEP 3333) on Bearings: the environ, `wsgi.input` and the response.

`WsgiHandler` is the callback the server calls on a worker thread, once per
request, with the exchange and the request head (`bearings.h`). The
exchange is valid only during the call: `Input` and `Response.write()`
refuse to use it after, also from another thread (a lock per request
orders their calls with its end).

`RawHandler` is the callback with `Server(app, raw=True)`: the app gets the
head as Bearings sends it, without an environ, and returns its response.
"""
import io
import os
import stat
import sys
import threading
import traceback
import typing as t
from urllib.parse import unquote_to_bytes

from ._ffi import BAD_HEADER, CANCELED, CLIENT_GONE, OK, VERSION, ffi, lib


READ_SIZE = 65536
# the most one read asks the server for: `read(n)` of a large n allocates
# as the body arrives, not n bytes up front (n comes from the client)
MAX_READ = 1 << 20
ERROR_BODY = b"Internal Server Error\n"
ERROR_HEADERS = b"content-type\0text/plain; charset=utf-8\0"

# read buffers are written over at once: no need to zero them
_alloc = ffi.new_allocator(should_clear_after_alloc=False)


class BodyError(ValueError):
    """The request body could not be read: malformed, cut short, or sent
    too slowly."""


class ClientDisconnected(BodyError):
    """The request was canceled while the app read its body: the client
    went away, or the server's shutdown deadline passed."""


class FileWrapper:
    """`wsgi.file_wrapper`: a file the server sends with sendfile(2)
    when it is a regular file, and reads in blocks otherwise."""

    def __init__(self, filelike: t.Any, block_size: int = READ_SIZE) -> None:
        self.filelike = filelike
        self.block_size = block_size

    def __iter__(self) -> "FileWrapper":
        return self

    def __next__(self) -> bytes:
        data = self.filelike.read(self.block_size)
        if data:
            return data
        raise StopIteration

    def close(self) -> None:
        close = getattr(self.filelike, "close", None)
        if close is not None:
            close()


class Input:
    """`wsgi.input`: the request body, read from the client as the app asks."""

    def __init__(self, ex: t.Any, lock: threading.Lock) -> None:
        self._ex = ex
        self._lock = lock  # the request's: its end sets `_ex` to None under it
        self._buf = b""
        self._ended = False

    def _receive(self, size: int) -> bytes:
        """At most `size` bytes from the client; `b""` at the end of the body."""
        if self._ended:
            return b""
        with self._lock:
            if self._ex is None:
                raise ValueError("the request has ended: its body can't be read anymore")
            buf = _alloc("char[]", size)
            n = lib.bearings_read(self._ex, buf, size)
            if n > 0:
                return ffi.buffer(buf, n)[:]
            if n == 0:
                self._ended = True
                return b""
            if n == CLIENT_GONE:
                raise ClientDisconnected("the client disconnected")
            raise BodyError(self._error())

    def _error(self) -> str:
        """The server's message for the body error (under the lock)."""
        size = 256
        while True:
            message = ffi.new("char[]", size)
            n = lib.bearings_body_error(self._ex, message, size)
            if n < size:  # it fit; else nothing was copied: n is its length
                return ffi.string(message, n).decode(errors="replace")
            size = n + 1

    def read(self, size: int | None = -1) -> bytes:
        if size is None or size < 0:
            chunks = [self._buf]
            self._buf = b""
            while chunk := self._receive(READ_SIZE):
                chunks.append(chunk)
            return b"".join(chunks)
        chunks = []
        have = len(self._buf)
        if have:
            chunks.append(self._buf)
            self._buf = b""
        while have < size:
            chunk = self._receive(min(max(size - have, READ_SIZE), MAX_READ))
            if not chunk:
                break
            chunks.append(chunk)
            have += len(chunk)
        data = b"".join(chunks)
        if len(data) > size:
            data, self._buf = data[:size], data[size:]
        return data

    def readline(self, size: int | None = -1) -> bytes:
        limit = size if size is not None and size >= 0 else None
        while True:
            end = self._buf.find(b"\n")
            if end >= 0 and (limit is None or end < limit):
                line, self._buf = self._buf[: end + 1], self._buf[end + 1 :]
                return line
            if limit is not None and len(self._buf) >= limit:
                line, self._buf = self._buf[:limit], self._buf[limit:]
                return line
            chunk = self._receive(READ_SIZE)
            if not chunk:
                line, self._buf = self._buf, b""
                return line
            self._buf += chunk

    def readlines(self, hint: int | None = -1) -> list[bytes]:
        lines = []
        total = 0
        while line := self.readline():
            lines.append(line)
            total += len(line)
            if hint is not None and 0 < hint <= total:
                break
        return lines

    def __iter__(self) -> "Input":
        return self

    def __next__(self) -> bytes:
        line = self.readline()
        if not line:
            raise StopIteration
        return line


class _ClientGone(Exception):
    """The client went away while the response was being sent."""


class Response:
    """`start_response` and the sending of the app's result."""

    __slots__ = ("ex", "lock", "status", "headers", "streaming")

    def __init__(self, ex: t.Any, lock: threading.Lock) -> None:
        self.ex = ex
        self.lock = lock  # the request's: its end sets `ex` to None under it
        # the WSGI status line, or the code a raw app returned
        self.status: str | int | None = None
        self.headers: list[tuple[str, str]] = []
        self.streaming = False

    def start_response(
        self, status: str, headers: list[tuple[str, str]], exc_info: t.Any = None
    ) -> t.Callable[[bytes], None]:
        if exc_info:
            try:
                if self.streaming:
                    raise exc_info[1].with_traceback(exc_info[2])
            finally:
                exc_info = None
        elif self.status is not None:
            raise AssertionError("start_response was already called")
        self.status = status
        self.headers = headers
        return self.write

    def _head(self) -> tuple[int, bytes]:
        if self.status is None:
            raise AssertionError("the app did not call start_response")
        status = self.status
        code = status if isinstance(status, int) else int(status[:3])
        headers = "".join(f"{name}\0{value}\0" for name, value in self.headers)
        # a NUL ends a name or a value in what the server reads: one in the
        # app's header would make the rest a field of its own
        if headers.count("\0") != 2 * len(self.headers):
            raise ValueError(f"a NUL in a response header in {self.headers!r}")
        return code, headers.encode("latin-1")

    def _check(self, result: int) -> None:
        if result == OK:
            return
        if result == CANCELED:
            raise _ClientGone
        if result == BAD_HEADER:
            raise ValueError(f"invalid response header in {self.headers!r}")
        # a Pascal exception caught at the C boundary: a bug in bearings
        raise RuntimeError("bearings could not send the response")  # pragma: no cover

    def write(self, data: bytes) -> None:
        """The `write()` of `start_response`, for apps that push the body."""
        if not data:
            return
        with self.lock:
            if self.ex is None:
                raise RuntimeError("the request has ended: write() can't send anymore")
            if not self.streaming:
                self._begin()
            self._check(lib.bearings_write(self.ex, data, len(data)))

    def _begin(self) -> None:
        code, headers = self._head()
        self._check(lib.bearings_begin_stream(self.ex, code, headers, len(headers)))
        self.streaming = True

    def _respond(self, body: bytes) -> None:
        code, headers = self._head()
        self._check(lib.bearings_respond(self.ex, code, headers, len(headers), body, len(body)))

    def send(self, result: t.Iterable[bytes], method: str) -> None:
        if self.streaming:  # the app used write(): the rest follows
            for chunk in result:
                self.write(chunk)
            self._check(lib.bearings_finish(self.ex))
            return
        if method == "HEAD":
            for _ in result:  # an app may set its headers while it iterates
                pass
            self._respond(b"")
            return
        if self._send_file(result):
            return
        if isinstance(result, (list, tuple)) and len(result) <= 1:
            self._respond(result[0] if result else b"")
            return
        # The head goes with the first chunk that isn't empty (PEP 3333);
        # a body of one chunk goes with its length, like the list above.
        it = iter(result)
        first = b""
        for chunk in it:
            if chunk:
                first = chunk
                break
        second = next(it, None)
        while second is not None and not second:
            second = next(it, None)
        if second is None:
            self._respond(first)
            return
        self._begin()
        self.write(first)
        self.write(second)
        for chunk in it:
            self.write(chunk)
        self._check(lib.bearings_finish(self.ex))

    def _send_file(self, result: t.Any) -> bool:
        """Send a file body with sendfile(2): a body with a `filelike` that
        is a regular file (`FileWrapper`, and wsgiref's and Proper's)."""
        filelike: t.Any = getattr(result, "filelike", None)
        fileno = getattr(filelike, "fileno", None)
        if fileno is None:
            return False
        try:
            fd = fileno()
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):  # a pipe, a socket
                return False
            offset = filelike.tell()
        except (OSError, ValueError, AttributeError):  # closed, or no tell()
            return False
        length = info.st_size - offset
        # at most the app's Content-Length; the server writes the length it
        # sends in place of that header
        for name, value in self.headers:
            if name.lower() == "content-length" and value.isdigit():
                length = min(length, int(value))
        code, headers = self._head()
        dup = os.dup(fd)  # the server closes it once sent
        self._check(
            lib.bearings_respond_file(self.ex, code, headers, len(headers), dup, offset, length)
        )
        return True

    def fail(self) -> None:
        """The app raised: a 500, or a truncated body if one was begun."""
        if self.streaming:
            lib.bearings_abort_stream(self.ex, b"the app raised an exception")
            return
        lib.bearings_respond(
            self.ex, 500, ERROR_HEADERS, len(ERROR_HEADERS), ERROR_BODY, len(ERROR_BODY)
        )


class WsgiHandler:
    """The server's callback: runs the WSGI app for one request."""

    def __init__(
        self,
        app: t.Callable,
        *,
        host: str,
        unix_path: str | None = None,
        url_scheme: str = "http",
    ) -> None:
        self.app = app
        self.host = host
        self.unix_path = unix_path
        self.url_scheme = url_scheme
        # set by listening_on(): the server accepts before it can be told its
        # port, so a request that comes first waits for it
        self._listening = threading.Event()
        self._configure(0)

    def listening_on(self, port: int) -> None:
        """The port the server listens on, once it does (`SERVER_PORT`)."""
        self._configure(port)
        self._listening.set()

    def _configure(self, port: int) -> None:
        self._base: dict[str, t.Any] = {
            "SCRIPT_NAME": "",
            "SERVER_NAME": self.unix_path or self.host,
            "SERVER_PORT": "" if self.unix_path else str(port),
            "SERVER_SOFTWARE": f"bearings/{VERSION}",
            "wsgi.version": (1, 0),
            "wsgi.url_scheme": self.url_scheme,
            "wsgi.errors": sys.stderr,
            "wsgi.multithread": True,
            "wsgi.multiprocess": False,
            "wsgi.run_once": False,
            "wsgi.input_terminated": True,
            "wsgi.file_wrapper": FileWrapper,
        }

    def environ(self, head: bytes, body: Input | None = None) -> dict:
        """The head as an environ; without `body` (a WebSocket's handshake),
        with an empty `wsgi.input`."""
        if not self._listening.is_set():
            self._listening.wait()
        parts = head.decode("latin-1").split("\0")
        method, path, query, version, address, port = parts[:6]
        environ = self._base.copy()
        environ["REQUEST_METHOD"] = method
        # PEP 3333: the path decoded, as bytes in a latin-1 str
        environ["PATH_INFO"] = (
            unquote_to_bytes(path.encode("latin-1")).decode("latin-1") if "%" in path else path
        )
        environ["QUERY_STRING"] = query
        environ["RAW_URI"] = environ["REQUEST_URI"] = f"{path}?{query}" if query else path
        environ["SERVER_PROTOCOL"] = version
        environ["REMOTE_ADDR"] = address
        environ["REMOTE_PORT"] = port
        environ["wsgi.input"] = body if body is not None else io.BytesIO()
        for i in range(6, len(parts) - 1, 2):
            name = parts[i]
            if "_" in name:  # it would read as the same variable as one with "-"
                continue
            key = name.upper().replace("-", "_")
            if key != "CONTENT_TYPE" and key != "CONTENT_LENGTH":
                key = "HTTP_" + key
            if key in environ:
                environ[key] += ("; " if key == "HTTP_COOKIE" else ",") + parts[i + 1]
            else:
                environ[key] = parts[i + 1]
        return environ

    def __call__(self, ctx: t.Any, ex: t.Any, head: t.Any, length: int) -> None:
        lock = threading.Lock()
        response = Response(ex, lock)
        # kept here: middleware may put another stream in `wsgi.input`
        body = Input(ex, lock)
        try:
            environ = self.environ(ffi.unpack(head, length), body)
            result = self.app(environ, response.start_response)
            _send(response, result, environ["REQUEST_METHOD"])
        except _ClientGone:
            pass
        except BaseException:
            traceback.print_exc(file=sys.stderr)
            response.fail()
        finally:
            _end(response, body)


class Listener:
    """Where the server listens, for a raw app: what WSGI puts in
    `SERVER_NAME`, `SERVER_PORT`, `wsgi.url_scheme` and `SERVER_SOFTWARE`.
    One object for every request."""

    __slots__ = ("name", "port", "url_scheme", "software")

    def __init__(self, name: str, port: int | None, url_scheme: str) -> None:
        self.name = name
        # None on a Unix socket
        self.port = port
        self.url_scheme = url_scheme
        self.software = f"bearings/{VERSION}"

    def __repr__(self) -> str:
        return f"<Listener {self.url_scheme}://{self.name}:{self.port}>"


class RawHandler(WsgiHandler):
    """The server's callback with `raw=True`: calls `app(head, input, listener)`.

    - `head` is the request head as Bearings sends it, decoded as latin-1:
      fields ended by `"\0"`, the method, the path (percent-escapes kept),
      the query (without the `?`), the version (`"HTTP/1.1"`), the
      client's address and port (empty on a Unix socket), then a name and
      a value per header field, in the order received and with the names
      as the client wrote them.
    - `input` is the body, the `wsgi.input` of WSGI.
    - `listener` is the `Listener`, the same object every time.

    The app returns `(status, headers, body)`: the status code, a list of
    `(name, value)` and the body, as bytes or as what a WSGI app returns
    (an iterable of bytes, or a `FileWrapper`).

    Skipping the environ is the point: the app builds its request from the
    head with no `HTTP_*` names to undo. The WebSocket handshake still
    gets an environ (`environ()`).
    """

    def _configure(self, port: int) -> None:
        super()._configure(port)
        self.listener = Listener(
            self.unix_path or self.host, None if self.unix_path else port, self.url_scheme
        )

    def __call__(self, ctx: t.Any, ex: t.Any, head: t.Any, length: int) -> None:
        lock = threading.Lock()
        response = Response(ex, lock)
        body = Input(ex, lock)
        if not self._listening.is_set():
            self._listening.wait()
        try:
            text = ffi.unpack(head, length).decode("latin-1")
            status, headers, result = self.app(text, body, self.listener)
            response.status = status
            response.headers = headers
            if isinstance(result, bytes):  # sent with its length, as a list of one
                result = [result]
            _send(response, result, text[: text.index("\0")])
        except _ClientGone:
            pass
        except BaseException:
            traceback.print_exc(file=sys.stderr)
            response.fail()
        finally:
            _end(response, body)


def _end(response: Response, body: Input) -> None:
    """The request ended: its exchange is no longer valid. Under the lock, so
    a read or a write from another thread is either done or refused."""
    with response.lock:
        response.ex = None
        body._ex = None


def _send(response: Response, result: t.Any, method: str) -> None:
    """Send the app's result, then close it if it can be closed."""
    try:
        response.send(result, method)
    finally:
        close = getattr(result, "close", None)
        if close is not None:
            close()
