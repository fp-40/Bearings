"""The server: Bearings' event loops and worker pool, with a WSGI app (or a raw one)."""
import ipaddress
import os
import re
import signal
import socket
import threading
import typing as t

from ._ffi import INVALID, OK, ffi, lib
from .websocket import WebSocketHandler, WsDispatch
from .wsgi import RawHandler, WsgiHandler


ACCESS_LOGS = {None: 0, "json": 1, "combined": 2}
_ERRNO = re.compile(r"errno (\d+)")

# The servers started and not yet freed: C calls their callbacks (cffi
# closures that live as long as their Server), so a server stays alive
# while it runs even when the program dropped its last reference.
_running: set["Server"] = set()


def _address(host: str) -> str:
    """Bearings listens on an address: a host name is looked up, and its
    first address taken, as a socket's `bind()` would."""
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        pass
    # an AF_INET or AF_INET6 sockaddr: its first item is the address, a str
    return str(socket.getaddrinfo(host, None, type=socket.SOCK_STREAM, flags=socket.AI_PASSIVE)[0][4][0])


def _error(message: str) -> OSError:
    """Bearings' error as an `OSError` with its `errno` and what it means."""
    found = _ERRNO.search(message)
    if found is None:
        return OSError(message)
    number = int(found.group(1))
    return OSError(number, f"{message} ({os.strerror(number)})")


class Server:
    """Serves a WSGI app on Bearings.

    Every request runs the app on a thread of the worker pool, so the
    app may block. The event loops never run Python.

    Arguments:
        app:
            The WSGI app; with `raw=True`, a raw app.
        raw [False]:
            Call `app(head, input, listener)` instead of the WSGI
            `app(environ, start_response)`: the app gets the request head
            as Bearings sends it and returns `(status, headers, body)`.
            It saves building an environ the app would take apart again.
            `RawHandler` describes the arguments.
        host ["0.0.0.0"]:
            The address to listen on.
        port [0]:
            The port to listen on; 0 picks a free one (`Server.port`).
        unix_path:
            Listen on this Unix socket instead of a TCP port.
        unix_mode [0o660]:
            The permission bits of the Unix socket's file.
        fd:
            An open listening socket to serve from, instead of a port
            (for example one systemd passed).
        loops [0]:
            Event loops: threads that do the network I/O. 0 is one per CPU.
        workers [0]:
            Threads that run the app. 0 is `min(32, CPUs + 4)`.
        queue_limit [0]:
            With more than this many requests waiting for a worker, a new
            one is answered at once with a 503. 0 is no limit.
        max_connections [0]:
            Connections open at once; the next ones wait in the kernel's
            accept queue. 0 is no limit.
        access_log:
            `"json"` or `"combined"`: one line per request on stdout.
        metrics [False]:
            Keep the counters `Server.metrics()` returns.
        url_scheme ["http"]:
            `wsgi.url_scheme`: `"https"` behind a proxy that ends TLS.
        websocket:
            A `WebSocketHandler`: the server accepts WebSockets on
            `ws_path`, and the other requests go to the app.
        ws_path ["/"]:
            The path of the WebSockets.
        origins [()]:
            The `Origin` values a handshake may have (`"https://example.com"`).
            One without `Origin` is not from a browser, and is accepted.
        same_host_origin [True]:
            Also accept an `Origin` whose host and port are the handshake's
            `Host`: the page and the WebSockets on the same site.
        any_port_origin [False]:
            Also accept any port of the `Host`'s name (in development, the
            page and the WebSockets on different ports).
        ping_interval [25]:
            Seconds between the pings to each connection; 0 is none.
        idle_timeout [60]:
            A connection that sends nothing for this many seconds is closed
            (the browser's answers to the pings count); 0 is never.
        max_message [16 MiB]:
            Bytes; a larger message closes the connection.
        send_high_water [1 MiB]:
            Bytes queued for a connection that is behind before a send to it
            is refused, and a published message skips it.
        close_on_backpressure [False]:
            Close a subscriber that is behind instead of skipping it.
        ignore_text:
            A text message equal to this never reaches the handler (the
            client's answer to a ping of the application's own).

    `start()` returns once the server listens; `stop()` starts a graceful
    shutdown and `wait()` blocks until it ended. As a context manager it
    starts on entering and stops on leaving.
    """

    def __init__(
        self,
        app: t.Callable,
        *,
        raw: bool = False,
        host: str = "0.0.0.0",
        port: int = 0,
        unix_path: str | None = None,
        unix_mode: int = 0,
        fd: int = 0,
        loops: int = 0,
        workers: int = 0,
        queue_limit: int = 0,
        max_connections: int = 0,
        access_log: str | None = None,
        metrics: bool = False,
        url_scheme: str = "http",
        websocket: WebSocketHandler | None = None,
        ws_path: str = "/",
        origins: t.Iterable[str] = (),
        same_host_origin: bool = True,
        any_port_origin: bool = False,
        ping_interval: float = 25,
        idle_timeout: float = 60,
        max_message: int = 0,
        send_high_water: int = 0,
        close_on_backpressure: bool = False,
        ignore_text: str | None = None,
    ) -> None:
        if access_log not in ACCESS_LOGS:
            raise ValueError(f"access_log must be one of {list(ACCESS_LOGS)}")
        self.host = host
        handler = RawHandler if raw else WsgiHandler
        self._handler = handler(app, host=host, unix_path=unix_path, url_scheme=url_scheme)
        # kept alive with the config: the struct only points to them
        self._strings: list = []
        config = ffi.new("bearings_config *")
        config.port = port
        if unix_path:
            self._strings.append(ffi.new("char[]", unix_path.encode()))
            config.unix_path = self._strings[-1]
        config.unix_mode = unix_mode
        config.inherited_fd = fd
        config.loops = loops
        config.workers = workers
        config.worker_queue_limit = queue_limit
        config.saturated_status = 503 if queue_limit else 0
        config.max_connections = max_connections
        config.access_log = ACCESS_LOGS[access_log]
        config.metrics = int(metrics)
        self._ws_callback = ffi.NULL
        if websocket is not None:
            config.ws_path = self._keep(ws_path)
            config.ws_origins = self._keep("\n".join(origins))
            config.ws_same_host = int(same_host_origin)
            config.ws_any_port = int(any_port_origin)
            config.ws_ping_ms = int(ping_interval * 1000) if ping_interval > 0 else -1
            config.ws_idle_ms = int(idle_timeout * 1000) if idle_timeout > 0 else -1
            config.ws_max_message = max_message
            config.ws_send_high_water = send_high_water
            config.ws_close_on_backpressure = int(close_on_backpressure)
            if ignore_text:
                config.ws_ignore_text = self._keep(ignore_text)
            self._ws_callback = ffi.callback(
                "void(void *, int, unsigned long long, const char *, size_t)",
                WsDispatch(websocket, self._handler.environ, self.ws_close),
            )
        self._config = config
        self._callback = ffi.callback(
            "void(void *, bearings_exchange *, const char *, size_t)", self._handler
        )
        self._server = None
        self._lock = threading.Lock()
        # the calls into the server under way (from any thread): wait()
        # frees it only when there are none
        self._users = 0
        self._idle = threading.Condition(self._lock)

    def _keep(self, text: str) -> t.Any:
        """A C string the config points to, alive as long as the server."""
        self._strings.append(ffi.new("char[]", text.encode()))
        return self._strings[-1]

    @property
    def port(self) -> int:
        """The port it listens on (0 on a Unix socket)."""
        server = self._enter()
        try:
            return lib.bearings_server_port(server)
        finally:
            self._leave()

    def start(self) -> None:
        with self._lock:
            if self._server is not None:
                return
            self._config.host = self._keep(_address(self.host))
            err = ffi.new("char[]", 512)
            server = lib.bearings_server_new(
                self._config, self._callback, self._ws_callback, ffi.NULL, err, 512
            )
            if server == ffi.NULL:
                raise _error(ffi.string(err).decode(errors="replace"))
            self._server = server
            _running.add(self)
            self._handler.listening_on(lib.bearings_server_port(server))

    def stop(self, grace: float = 30) -> None:
        """Stop listening and let the open connections finish their requests,
        for at most `grace` seconds. Returns at once; `wait()` blocks."""
        with self._lock:
            if self._server is not None:
                lib.bearings_server_stop(self._server, int(grace * 1000))

    def wait(self) -> None:
        """Block until the server stopped, then free it."""
        with self._lock:
            server = self._server
            if server is None:
                return
            self._users += 1  # another thread may wait() too
        try:
            lib.bearings_server_wait(server)  # another thread may call stop() meanwhile
        finally:
            with self._lock:
                self._users -= 1
                if self._server is server:
                    self._server = None  # no new call starts
                    while self._users:
                        self._idle.wait()
                    lib.bearings_server_free(server)
                    _running.discard(self)
                elif not self._users:
                    self._idle.notify_all()

    def metrics(self) -> str:
        """The counters, in the Prometheus text format (with `metrics=True`)."""
        server = self._enter()
        try:
            size = 0  # the first call asks for the length
            while True:
                buf = ffi.new("char[]", size) if size else ffi.NULL
                n = lib.bearings_metrics(server, buf, size)
                if n < size:
                    return ffi.string(buf, n).decode()
                size = n + 256  # the counters may grow a digit before the next call
        finally:
            self._leave()

    # WebSockets, by the id `WebSocketHandler.opened()` got; from any thread

    def ws_send(self, ws: int, message: str) -> bool:
        """Send a text message. False when nothing was sent: the connection
        is closing or gone, or behind by `send_high_water` bytes."""
        data = message.encode()
        server = self._enter()
        try:
            return lib.bearings_ws_send(server, ws, data, len(data)) == OK
        finally:
            self._leave()

    def ws_close(self, ws: int, code: int = 1000, reason: str = "") -> bool:
        """Start the close handshake. False when the connection is already
        closing or gone."""
        server = self._enter()
        try:
            return lib.bearings_ws_close(server, ws, code, reason.encode()) == OK
        finally:
            self._leave()

    def subscribe(self, ws: int, topic: str) -> bool:
        """Subscribe a connection to a topic, or to a pattern of them: levels
        separated by `/`, where `+` is any one level and `#` the rest. False
        when the connection is closing or gone."""
        return self._subscription(lib.bearings_ws_subscribe, ws, topic)

    def unsubscribe(self, ws: int, topic: str) -> bool:
        return self._subscription(lib.bearings_ws_unsubscribe, ws, topic)

    def _subscription(self, call: t.Callable, ws: int, topic: str) -> bool:
        data = topic.encode()
        server = self._enter()
        try:
            result = call(server, ws, data, len(data))
        finally:
            self._leave()
        if result == INVALID:
            raise ValueError(f"not a valid topic: {topic!r}")
        return result == OK

    def publish(self, topic: str, message: str) -> bool:
        """Send a text message to every subscriber of `topic`, encoded once.
        A subscriber behind by `send_high_water` bytes misses it (or is
        closed, with `close_on_backpressure`). False after `stop()`."""
        name = topic.encode()
        data = message.encode()
        server = self._enter()
        try:
            result = lib.bearings_ws_publish(server, name, len(name), data, len(data))
        finally:
            self._leave()
        if result == INVALID:
            raise ValueError(f"not a valid topic: {topic!r}")
        return result == OK

    @property
    def websockets(self) -> int:
        """The WebSockets open."""
        server = self._enter()
        try:
            return lib.bearings_ws_count(server)
        finally:
            self._leave()

    def _enter(self) -> t.Any:
        """The server, for a call into it; `_leave()` after the call."""
        with self._lock:
            if self._server is None:
                raise RuntimeError("the server is not running")
            self._users += 1
            return self._server

    def _leave(self) -> None:
        with self._lock:
            self._users -= 1
            if not self._users:
                self._idle.notify_all()

    def __enter__(self) -> "Server":
        self.start()
        return self

    def __exit__(self, *exc: t.Any) -> None:
        self.stop(grace=5)
        self.wait()


def serve(
    app: t.Callable,
    *,
    grace: float = 30,
    started: t.Callable[[Server], t.Any] | None = None,
    **options: t.Any,
) -> None:
    """Serve `app` until SIGINT or SIGTERM, then shut down gracefully.

    `started(server)`, if given, is called once the server listens (to
    print its port, for example). `options` are those of `Server`. Call it from the main thread: it
    installs the handlers of those two signals while it runs.
    """
    # first: if the options are wrong, nothing is left installed
    server = Server(app, **options)
    stopping = []

    def on_signal(signum: int, frame: t.Any) -> None:
        stopping.append(signum)

    # A signal may land on any thread; Python runs its handler on the main
    # thread, but only once that thread runs Python code again. The wakeup
    # fd, written from whichever thread got the signal, ends the read below.
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_write, False)
    previous_fd = signal.set_wakeup_fd(wake_write)
    previous = {
        signum: signal.signal(signum, on_signal) for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        server.start()
        if started is not None:
            started(server)
        while not stopping:
            os.read(wake_read, 64)
    finally:
        server.stop(grace)
        server.wait()
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        signal.set_wakeup_fd(previous_fd)
        os.close(wake_read)
        os.close(wake_write)
