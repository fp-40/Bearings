"""Bearings, the Free Pascal HTTP/1.1 server, as a WSGI server.

    from bearings import serve
    serve(app, port=8000)          # until SIGINT or SIGTERM
"""
from ._ffi import VERSION
from .server import Server, serve
from .websocket import WebSocketHandler
from .wsgi import BodyError, ClientDisconnected, FileWrapper


__all__ = (
    "VERSION", "BodyError", "ClientDisconnected", "FileWrapper", "Server", "WebSocketHandler",
    "serve",
)
