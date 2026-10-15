"""WebSockets: the events of each connection, handed to a `WebSocketHandler`."""
import sys
import traceback
import typing as t

from ._ffi import ffi


OPENED = 1
TEXT = 2
BINARY = 3
CLOSED = 4
# a close code for "the server failed" (RFC 6455)
INTERNAL_ERROR = 1011


class WebSocketHandler:
    """What the server calls for each WebSocket, on a thread of its worker
    pool: the events of one connection one at a time, in order, so a method
    may block. `ws` is the connection's id, for `Server.ws_send()` and the
    other methods of the server. Subclass it and override what you need.
    """

    def opened(self, ws: int, environ: dict) -> None:
        """A connection opened. `environ` is its handshake, as WSGI's environ
        (`PATH_INFO`, `QUERY_STRING`, `HTTP_COOKIE`, `REMOTE_ADDR`, ...)."""

    def received(self, ws: int, message: str | bytes) -> None:
        """A message: `str` for a text one, `bytes` for a binary one."""

    def closed(self, ws: int, code: int, reason: str) -> None:
        """The connection ended: the last event. `code` is the client's
        close code; 1006 when it ended without one."""


class WsDispatch:
    """The server's WebSocket callback: one event to the handler."""

    def __init__(self, handler: WebSocketHandler, environ: t.Callable, close: t.Callable):
        self.handler = handler
        self.environ = environ  # the head as an environ
        self.close = close  # closes a connection whose open failed

    def __call__(self, ctx: t.Any, event: int, ws: int, data: t.Any, length: int) -> None:
        try:
            raw = ffi.unpack(data, length)
            if event == TEXT:
                self.handler.received(ws, raw.decode())  # valid UTF-8: the server checked
            elif event == BINARY:
                self.handler.received(ws, raw)
            elif event == OPENED:
                try:
                    self.handler.opened(ws, self.environ(raw))
                except BaseException:
                    traceback.print_exc(file=sys.stderr)
                    self.close(ws, INTERNAL_ERROR)
            else:
                code, _, reason = raw.partition(b"\0")
                self.handler.closed(ws, int(code), reason.decode(errors="replace"))
        except BaseException:
            traceback.print_exc(file=sys.stderr)
