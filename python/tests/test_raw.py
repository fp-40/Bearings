"""`Server(app, raw=True)`: the app gets the head, not an environ."""
import socket
import threading

from conftest import WsClient

from bearings import VERSION, FileWrapper, Listener, Server, WebSocketHandler


def echo_head(seen):
    """A raw app that keeps what it got and answers with the fields."""

    def app(head, input, listener):
        seen.update(head=head, body=input.read(), listener=listener)
        return 200, [("Content-Type", "text/plain")], repr(head.split("\0")).encode()

    return app


def test_the_head_as_bearings_sends_it(serve):
    seen = {}
    client = serve(echo_head(seen), raw=True)
    request = (
        b"POST /a%20b/%C3%B1?x=1&y=%20 HTTP/1.1\r\nHost: x\r\nX-One: 1\r\n"
        b"Accept: a\r\nAccept: b\r\nX_Under: kept\r\nContent-Length: 2\r\n"
        b"Connection: close\r\n\r\nhi"
    )
    answer = client.raw(request)
    assert answer.startswith(b"HTTP/1.1 200 ")
    fields = seen["head"].split("\0")
    method, path, query, version, address, port = fields[:6]
    assert (method, path, query, version, address) == (
        "POST", "/a%20b/%C3%B1", "x=1&y=%20", "HTTP/1.1", "127.0.0.1"
    )
    assert int(port) > 0
    # each field ends with a NUL; the names as the client wrote them, in order,
    # repeated lines apart and nothing dropped
    assert fields[-1] == ""
    assert list(zip(fields[6:-1:2], fields[7::2], strict=True)) == [
        ("Host", "x"), ("X-One", "1"), ("Accept", "a"), ("Accept", "b"),
        ("X_Under", "kept"), ("Content-Length", "2"), ("Connection", "close"),
    ]
    assert seen["body"] == b"hi"


def test_a_latin1_header_value(serve):
    seen = {}
    client = serve(echo_head(seen), raw=True)
    client.raw(b"GET / HTTP/1.1\r\nHost: x\r\nX-Name: \xf1\r\nConnection: close\r\n\r\n")
    assert "X-Name\0\xf1\0" in seen["head"]


def test_the_listener(serve):
    seen = {}
    client = serve(echo_head(seen), raw=True, url_scheme="https")
    client.request()
    listener = seen["listener"]
    assert isinstance(listener, Listener)
    assert (listener.name, listener.port, listener.url_scheme, listener.software) == (
        "127.0.0.1", client.port, "https", f"bearings/{VERSION}"
    )
    assert repr(listener) == f"<Listener https://127.0.0.1:{client.port}>"
    client.request()
    assert seen["listener"] is listener  # one object for every request


def test_the_listener_of_a_unix_socket(tmp_path):
    seen = {}
    path = str(tmp_path / "app.sock")
    with Server(echo_head(seen), raw=True, unix_path=path, loops=1, workers=1):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(path)
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            while sock.recv(4096):
                pass
    assert (seen["listener"].name, seen["listener"].port) == (path, None)
    address, port = seen["head"].split("\0")[4:6]
    assert (address, port) == ("", "")


def respond(status, headers, body):
    return lambda head, input, listener: (status, headers, body)


def test_status_headers_and_bytes(serve):
    client = serve(respond(201, [("X-A", "1"), ("X-A", "2")], b"made"), raw=True)
    response = client.request()
    assert response.status == 201
    assert response.headers.get_all("X-A") == ["1", "2"]
    assert response.headers["Content-Length"] == "4"
    assert response.body == b"made"


def test_an_iterable_body_is_streamed(serve):
    client = serve(respond(200, [], iter([b"a", b"b", b"c"])), raw=True)
    response = client.request()
    assert response.headers["Transfer-Encoding"] == "chunked"
    assert response.body == b"abc"


def test_the_result_is_closed(serve):
    closed = []

    class Body(list):
        def close(self):
            closed.append(True)

    client = serve(respond(200, [], Body([b"x"])), raw=True)
    assert client.request().body == b"x"
    assert closed == [True]


def test_a_file(serve, tmp_path):
    path = tmp_path / "f.txt"
    path.write_bytes(b"file body")

    def app(head, input, listener):
        return 200, [], FileWrapper(open(path, "rb"))

    client = serve(app, raw=True)
    response = client.request()
    assert response.headers["Content-Length"] == "9"
    assert response.body == b"file body"


def test_head_sends_no_body(serve):
    client = serve(respond(200, [], b"not sent"), raw=True)
    response = client.request("HEAD")
    assert response.status == 200
    assert response.body == b""


def test_the_app_raises(serve, capfd):
    def app(head, input, listener):
        raise RuntimeError("boom")

    client = serve(app, raw=True)
    response = client.request()
    assert response.status == 500
    assert response.body == b"Internal Server Error\n"
    assert "RuntimeError: boom" in capfd.readouterr().err


def test_the_app_returns_something_else(serve, capfd):
    client = serve(lambda head, input, listener: b"just bytes", raw=True)
    assert client.request().status == 500
    assert "ValueError" in capfd.readouterr().err


def test_an_invalid_header(serve, capfd):
    client = serve(respond(200, [("Bad Name", "x")], b""), raw=True)
    assert client.request().status == 500
    assert "invalid response header" in capfd.readouterr().err


def test_the_body_cannot_be_read_after_the_request(serve):
    kept = []

    def app(head, input, listener):
        kept.append(input)
        return 200, [], b""

    client = serve(app, raw=True)
    client.request("POST", "/", body=b"unread")
    try:
        kept[0].read(1)
    except ValueError as error:
        assert "the request has ended" in str(error)
    else:
        raise AssertionError("the body was read after the request")


def test_a_client_that_leaves_while_streaming(serve):
    closed = threading.Event()

    class Endless:
        def __iter__(self):
            while True:
                yield b"x" * 65536

        def close(self):
            closed.set()

    def app(head, input, listener):
        endless = head.split("\0")[1] == "/endless"
        return 200, [], Endless() if endless else b"still here"

    client = serve(app, raw=True)
    with socket.create_connection(("127.0.0.1", client.port)) as sock:
        sock.sendall(b"GET /endless HTTP/1.1\r\nHost: x\r\n\r\n")
        sock.recv(1000)
    assert closed.wait(10)  # the worker stopped writing and closed the result
    assert client.request().body == b"still here"


class Opened(WebSocketHandler):
    def __init__(self):
        self.environ = None

    def opened(self, ws, environ):
        self.environ = environ
        self.server.ws_close(ws)


def test_websockets_still_get_an_environ():
    handler = Opened()
    server = Server(
        respond(404, [], b"no"), raw=True, websocket=handler, ws_path="/ws",
        host="127.0.0.1", loops=1, workers=2,
    )
    handler.server = server
    with server:
        client = WsClient(server.port, "/ws", headers=[("Cookie", "a=1")])
        assert client.status == 101
        assert client.recv() is None
        assert handler.environ["HTTP_COOKIE"] == "a=1"
        assert handler.environ["SERVER_PORT"] == str(server.port)
        # the other requests go to the raw app
        with socket.create_connection(("127.0.0.1", server.port)) as sock:
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            answer = b""
            while chunk := sock.recv(4096):
                answer += chunk
        assert answer.startswith(b"HTTP/1.1 404 ")
