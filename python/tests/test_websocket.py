import queue
import socket
import threading
import time

import pytest
from conftest import WsClient

from bearings import Server, WebSocketHandler


def not_found(environ, start_response):
    start_response("404 Not Found", [])
    return [b"not here"]


class Recorder(WebSocketHandler):
    """Keeps every event; echoes what `echo` says."""

    def __init__(self, echo=False):
        self.events = queue.Queue()
        self.opened_ids = []
        self.echo = echo
        self.server = None

    def opened(self, ws, environ):
        self.opened_ids.append(ws)
        self.events.put(("opened", ws, environ))

    def received(self, ws, message):
        self.events.put(("received", ws, message))
        if self.echo:
            self.server.ws_send(ws, message if isinstance(message, str) else repr(message))

    def closed(self, ws, code, reason):
        self.events.put(("closed", ws, code, reason))

    def next(self, kind=None):
        event = self.events.get(timeout=10)
        if kind is not None:
            assert event[0] == kind, event
        return event

    def wait_for(self, kind):
        """The next event of this kind; the others before it are skipped."""
        while (event := self.events.get(timeout=10))[0] != kind:
            pass
        return event


@pytest.fixture()
def ws_serve():
    servers = []

    def start(handler, app=not_found, **options):
        options.setdefault("host", "127.0.0.1")
        options.setdefault("loops", 2)
        options.setdefault("workers", 4)
        options.setdefault("ws_path", "/ws")
        server = Server(app, websocket=handler, **options)
        handler.server = server
        server.start()
        servers.append(server)
        return server

    yield start
    for server in servers:
        server.stop(grace=1)
        server.wait()


def test_the_events_of_a_connection(ws_serve):
    handler = Recorder(echo=True)
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws?room=1", headers=[("Cookie", "a=1")])
    assert client.status == 101
    _, ws, environ = handler.next("opened")
    assert environ["PATH_INFO"] == "/ws"
    assert environ["QUERY_STRING"] == "room=1"
    assert environ["HTTP_COOKIE"] == "a=1"
    assert environ["REMOTE_ADDR"] == "127.0.0.1"
    client.send("hola")
    assert handler.next("received") == ("received", ws, "hola")
    assert client.recv() == "hola"
    client.send(b"\x00\x01", opcode=2)
    assert handler.next("received") == ("received", ws, b"\x00\x01")
    assert client.recv() == "b'\\x00\\x01'"
    client.close(4000, "bye")
    assert client.recv() is None
    assert client.close_code == 4000
    assert handler.next("closed") == ("closed", ws, 4000, "bye")


def test_events_of_one_connection_come_in_order(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws")
    handler.next("opened")
    for n in range(50):
        client.send(str(n))
    assert [handler.next("received")[2] for _ in range(50)] == [str(n) for n in range(50)]


def test_other_requests_go_to_the_app(ws_serve):
    import http.client

    server = ws_serve(Recorder())
    for path in ("/elsewhere", "/ws"):  # the path without an upgrade, too
        conn = http.client.HTTPConnection("127.0.0.1", server.port, timeout=5)
        conn.request("GET", path)
        response = conn.getresponse()
        assert (response.status, response.read()) == (404, b"not here")
        conn.close()


def test_the_server_closes(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws")
    _, ws, _ = handler.next("opened")
    assert server.ws_close(ws, 4001, "go away")
    assert client.recv() is None
    assert client.close_code == 4001
    assert handler.next("closed")[:3] == ("closed", ws, 4001)
    # gone now
    assert not server.ws_send(ws, "x")
    assert not server.ws_close(ws)
    assert not server.subscribe(ws, "a")
    assert not server.unsubscribe(ws, "a")


def test_a_client_that_vanishes(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws")
    _, ws, _ = handler.next("opened")
    client.shut()
    assert handler.next("closed")[:3] == ("closed", ws, 1006)


def test_topics(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    # one at a time: the events of two connections come in any order
    a = WsClient(server.port, "/ws")
    ws_a = handler.next("opened")[1]
    b = WsClient(server.port, "/ws")
    ws_b = handler.next("opened")[1]
    assert server.subscribe(ws_a, "room/1")
    assert server.subscribe(ws_b, "room/+")
    assert server.publish("room/1", "to both")
    assert a.recv() == "to both"
    assert b.recv() == "to both"
    assert server.publish("room/2", "to b")
    assert b.recv() == "to b"
    assert server.unsubscribe(ws_b, "room/+")
    server.publish("room/1", "to a")
    assert a.recv() == "to a"
    assert server.websockets == 2


def test_invalid_topics(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    WsClient(server.port, "/ws")
    ws = handler.next("opened")[1]
    with pytest.raises(ValueError, match="not a valid topic"):
        server.subscribe(ws, "a/#/b")
    with pytest.raises(ValueError, match="not a valid topic"):
        server.publish("a/+", "x")


@pytest.mark.parametrize(
    ("origin", "status"),
    [
        (None, 101),  # not a browser
        ("https://listed.example", 101),
        ("HTTPS://Listed.Example/", 101),
        ("SAME", 101),  # the handshake's own Host
        ("http://127.0.0.1:1", 403),  # another port
        ("https://evil.example", 403),
        ("not a url", 403),
    ],
)
def test_origins(ws_serve, origin, status):
    server = ws_serve(Recorder(), origins=["https://listed.example"])
    if origin == "SAME":
        origin = f"http://127.0.0.1:{server.port}"
    headers = [("Origin", origin)] if origin else []
    assert WsClient(server.port, "/ws", headers=headers).status == status


def test_any_port_origin(ws_serve):
    server = ws_serve(Recorder(), any_port_origin=True, same_host_origin=False)
    assert WsClient(server.port, "/ws", headers=[("Origin", "http://127.0.0.1:1")]).status == 101
    assert WsClient(server.port, "/ws", headers=[("Origin", "http://[::1]:1")]).status == 403


def test_only_listed_origins(ws_serve):
    server = ws_serve(Recorder(), same_host_origin=False)
    same = f"http://127.0.0.1:{server.port}"
    assert WsClient(server.port, "/ws", headers=[("Origin", same)]).status == 403


def test_two_origins_are_refused(ws_serve):
    server = ws_serve(Recorder())
    same = f"http://127.0.0.1:{server.port}"
    headers = [("Origin", same), ("Origin", same)]
    assert WsClient(server.port, "/ws", headers=headers).status == 403


def test_ignored_text(ws_serve):
    handler = Recorder()
    server = ws_serve(handler, ignore_text="PONG")
    client = WsClient(server.port, "/ws")
    handler.next("opened")
    client.send("PONG")
    client.send("real")
    assert handler.next("received")[2] == "real"


def test_pings_and_the_idle_timeout(ws_serve):
    handler = Recorder()
    server = ws_serve(handler, ping_interval=0.2, idle_timeout=1)
    client = WsClient(server.port, "/ws")
    ws = handler.next("opened")[1]
    started = time.monotonic()
    assert client.frame()[0] == 9  # a ping, which this client doesn't answer
    # nothing comes from the client: closed as idle
    assert client.recv() is None
    assert client.close_code == 1001
    assert time.monotonic() - started < 3
    assert handler.next("closed")[:2] == ("closed", ws)


def test_a_message_too_large(ws_serve):
    handler = Recorder()
    server = ws_serve(handler, max_message=10)
    client = WsClient(server.port, "/ws")
    ws = handler.next("opened")[1]
    client.send("x" * 11)
    assert client.recv() is None
    assert client.close_code == 1009
    assert handler.next("closed")[:2] == ("closed", ws)


def test_a_handler_that_fails_to_open_closes_the_connection(ws_serve, capfd):
    class Failing(WebSocketHandler):
        def opened(self, ws, environ):
            raise RuntimeError("no")

    server = ws_serve(Failing())
    client = WsClient(server.port, "/ws")
    assert client.recv() is None
    assert client.close_code == 1011
    assert "RuntimeError: no" in capfd.readouterr().err


def test_the_base_handler_does_nothing(ws_serve):
    server = ws_serve(WebSocketHandler())
    client = WsClient(server.port, "/ws")
    client.send("ignored")
    client.close()
    assert client.recv() is None


def test_a_subscriber_that_is_behind(ws_serve):
    handler = Recorder()
    server = ws_serve(handler, send_high_water=65536, close_on_backpressure=True)
    client = WsClient(server.port, "/ws")
    client.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    ws = handler.next("opened")[1]
    server.subscribe(ws, "flood")
    for _ in range(200):  # the client reads nothing
        server.publish("flood", "x" * 16384)
    assert handler.next("closed")[:3] == ("closed", ws, 1006)


def test_a_send_to_a_client_that_is_behind(ws_serve):
    handler = Recorder()
    server = ws_serve(handler, send_high_water=65536)
    client = WsClient(server.port, "/ws")  # reads nothing
    client.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    ws = handler.next("opened")[1]
    results = {server.ws_send(ws, "x" * 16384) for _ in range(200)}
    assert results == {True, False}


def test_the_server_stops_with_open_connections(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws")
    ws = handler.next("opened")[1]
    done = threading.Thread(target=lambda: (server.stop(grace=5), server.wait()))
    done.start()
    assert client.recv() is None
    assert client.close_code == 1001
    done.join(10)
    assert handler.next("closed")[:2] == ("closed", ws)
    with pytest.raises(RuntimeError, match="not running"):
        server.publish("a", "x")


def test_no_publish_once_stopping(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    server.stop(grace=1)
    assert not server.publish("a", "x")
    server.wait()


def test_a_close_without_a_code(ws_serve):
    handler = Recorder()
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws")
    ws = handler.next("opened")[1]
    client.closing = True
    client.send(b"", opcode=8)
    assert client.recv() is None
    assert handler.next("closed")[:3] == ("closed", ws, 1005)


def test_a_handler_that_raises_keeps_the_connection(ws_serve, capfd):
    class Raising(Recorder):
        def received(self, ws, message):
            super().received(ws, message)
            if message == "boom":
                raise RuntimeError("in received")

    handler = Raising(echo=True)
    server = ws_serve(handler)
    client = WsClient(server.port, "/ws")
    handler.next("opened")
    client.send("boom")
    client.send("after")
    assert client.recv() == "boom"
    assert client.recv() == "after"
    assert "RuntimeError: in received" in capfd.readouterr().err


def test_a_publish_after_subscribe_reaches_the_new_subscriber(ws_serve):
    """Even the first subscription on a loop, with no pause in between."""
    handler = Recorder()
    server = ws_serve(handler, loops=4)
    for n in range(40):
        client = WsClient(server.port, "/ws")
        ws = handler.wait_for("opened")[1]  # the last one's close may come first
        assert server.subscribe(ws, f"fresh/{n}")
        assert server.publish(f"fresh/{n}", "first")
        assert client.recv() == "first"
        assert server.unsubscribe(ws, f"fresh/{n}")
        assert server.publish(f"fresh/{n}", "not this")
        assert server.ws_send(ws, "this")
        assert client.recv() == "this"
        client.shut()
