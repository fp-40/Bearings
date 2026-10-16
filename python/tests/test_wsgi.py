import io
import os
import socket
import sys
import threading
from importlib.metadata import version

import pytest

from bearings import FileWrapper


def echo_environ(keys):
    def app(environ, start_response):
        body = repr({key: environ.get(key) for key in keys}).encode()
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [body]

    return app


def test_environ_of_a_request(serve):
    keys = [
        "REQUEST_METHOD", "SCRIPT_NAME", "PATH_INFO", "QUERY_STRING", "RAW_URI",
        "SERVER_PROTOCOL", "SERVER_NAME", "SERVER_SOFTWARE", "REMOTE_ADDR",
        "wsgi.url_scheme", "wsgi.input_terminated", "wsgi.multithread",
    ]
    client = serve(echo_environ(keys))
    response = client.request("GET", "/a%20b/%C3%B1?x=1&y=%20")
    environ = eval(response.body)
    assert environ == {
        "REQUEST_METHOD": "GET",
        "SCRIPT_NAME": "",
        # PEP 3333: decoded, as bytes in a latin-1 str
        "PATH_INFO": "/a b/" + "ñ".encode().decode("latin-1"),
        "QUERY_STRING": "x=1&y=%20",
        "RAW_URI": "/a%20b/%C3%B1?x=1&y=%20",
        "SERVER_PROTOCOL": "HTTP/1.1",
        "SERVER_NAME": "127.0.0.1",
        # one version for the library and the package (tools/check-version.sh)
        "SERVER_SOFTWARE": f"bearings/{version('pybearings')}",
        "REMOTE_ADDR": "127.0.0.1",
        "wsgi.url_scheme": "http",
        "wsgi.input_terminated": True,
        "wsgi.multithread": True,
    }


def test_server_and_remote_ports(serve):
    client = serve(echo_environ(["SERVER_PORT", "REMOTE_PORT"]))
    environ = eval(client.request().body)
    assert environ["SERVER_PORT"] == str(client.port)
    assert int(environ["REMOTE_PORT"]) > 0


def test_url_scheme(serve):
    client = serve(echo_environ(["wsgi.url_scheme"]), url_scheme="https")
    assert eval(client.request().body) == {"wsgi.url_scheme": "https"}


def test_headers(serve):
    keys = ["CONTENT_TYPE", "CONTENT_LENGTH", "HTTP_X_ONE", "HTTP_ACCEPT", "HTTP_COOKIE",
            "HTTP_X_UNDER", "HTTP_CONTENT_TYPE"]
    client = serve(echo_environ(keys))
    request = (
        b"POST / HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n"
        b"X-One: 1\r\nAccept: a\r\nAccept: b\r\nCookie: a=1\r\nCookie: b=2\r\n"
        b"X_Under: dropped\r\nConnection: close\r\n\r\nhi"
    )
    answer = client.raw(request)
    environ = eval(answer.split(b"\r\n\r\n", 1)[1])
    assert environ == {
        "CONTENT_TYPE": "text/plain",
        "CONTENT_LENGTH": "2",
        "HTTP_X_ONE": "1",
        "HTTP_ACCEPT": "a,b",
        "HTTP_COOKIE": "a=1; b=2",
        # it would read as X-Under
        "HTTP_X_UNDER": None,
        "HTTP_CONTENT_TYPE": None,
    }


def body_app(read):
    def app(environ, start_response):
        body = read(environ["wsgi.input"])
        start_response("200 OK", [])
        return [body if isinstance(body, bytes) else repr(body).encode()]

    return app


def test_read_the_whole_body(serve):
    client = serve(body_app(lambda stream: stream.read()))
    data = bytes(range(256)) * 1024  # bigger than one read
    assert client.request("POST", "/", body=data).body == data


def test_read_by_size(serve):
    def read(stream):
        return [stream.read(3), stream.read(0), stream.read(100000), stream.read(5)]

    client = serve(body_app(read))
    response = client.request("POST", "/", body=b"abcdefgh")
    assert eval(response.body) == [b"abc", b"", b"defgh", b""]


def test_read_none_is_all(serve):
    client = serve(body_app(lambda stream: stream.read(None)))
    assert client.request("POST", "/", body=b"all of it").body == b"all of it"


def test_read_a_chunked_body(serve):
    client = serve(body_app(lambda stream: stream.read()))
    answer = client.raw(
        b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        b"3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n"
    )
    assert answer.endswith(b"\r\n\r\nabcdefg")


def test_readline_and_iteration(serve):
    def read(stream):
        first = stream.readline()
        limited = stream.readline(2)
        rest = list(stream)
        return [first, limited, rest, stream.readline()]

    client = serve(body_app(read))
    response = client.request("POST", "/", body=b"one\ntwo\nthree\nfour")
    assert eval(response.body) == [b"one\n", b"tw", [b"o\n", b"three\n", b"four"], b""]


def test_readline_limit_over_buffered_data(serve):
    def read(stream):
        stream.read(1)  # receives the whole body: the rest stays buffered
        return [stream.readline(3), stream.readline(-1), stream.readline(None)]

    client = serve(body_app(read))
    assert eval(client.request("POST", "/", body=b"xabcdef\ng").body) == [
        b"abc", b"def\n", b"g",
    ]


def test_readlines(serve):
    client = serve(body_app(lambda stream: stream.readlines()))
    response = client.request("POST", "/", body=b"a\nb\nc")
    assert eval(response.body) == [b"a\n", b"b\n", b"c"]


def test_readlines_with_a_hint(serve):
    client = serve(body_app(lambda stream: stream.readlines(3)))
    response = client.request("POST", "/", body=b"a\nb\nc\n")
    assert eval(response.body) == [b"a\n", b"b\n"]


def test_a_malformed_body(serve):
    errors = []

    def read(stream):
        try:
            stream.read()
        except ValueError as exc:
            errors.append(repr(exc))
        return b"answered anyway"

    client = serve(body_app(read))
    answer = client.raw(
        b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n"
    )
    assert errors == ["BodyError('Invalid chunk size line: missing size digit')"]
    # the answer goes, and the connection closes: the rest of the body is lost
    assert answer.startswith(b"HTTP/1.1 200 OK\r\n")
    assert answer.endswith(b"\r\n\r\nanswered anyway")


def test_the_body_cannot_be_read_after_the_request(serve):
    kept = []

    def app(environ, start_response):
        kept.append(environ["wsgi.input"])
        start_response("200 OK", [])
        return [b"ok"]

    client = serve(app)
    client.request("POST", "/", body=b"unread")
    with pytest.raises(ValueError, match="request has ended"):
        kept[0].read()


def respond_with(status="200 OK", headers=(), body=(b"",), *, method_body=None):
    def app(environ, start_response):
        start_response(status, list(headers))
        return method_body(environ) if method_body else body

    return app


def test_a_body_of_one_chunk_has_a_length(serve):
    client = serve(respond_with(body=[b"hello"]))
    response = client.request()
    assert response.getheader("content-length") == "5"
    assert response.body == b"hello"


def test_an_empty_body(serve):
    for body in ([], [b""], iter([]), iter([b"", b""])):
        client = serve(respond_with(body=body))
        response = client.request()
        assert response.getheader("content-length") == "0"
        assert response.body == b""


def test_a_generator_of_one_chunk_has_a_length(serve):
    client = serve(respond_with(body=iter([b"", b"only", b""])))
    response = client.request()
    assert response.getheader("content-length") == "4"
    assert response.body == b"only"


def test_a_generator_is_streamed(serve):
    def chunks(environ):
        yield b"one "
        yield b""
        yield b"two "
        yield b"three"

    client = serve(respond_with(method_body=chunks))
    response = client.request()
    assert response.getheader("transfer-encoding") == "chunked"
    assert response.body == b"one two three"


def test_a_streamed_body_with_a_length(serve):
    client = serve(respond_with(headers=[("Content-Length", "6")], body=iter([b"abc", b"def"])))
    response = client.request()
    assert response.getheader("content-length") == "6"
    assert response.getheader("transfer-encoding") is None
    assert response.body == b"abcdef"


def test_status_and_headers(serve):
    client = serve(respond_with("404 Not Found", [("X-A", "1"), ("Set-Cookie", "a=1"),
                                                  ("Set-Cookie", "b=2")], [b"no"]))
    response = client.request()
    assert response.status == 404
    assert response.getheader("x-a") == "1"
    assert response.headers.get_all("set-cookie") == ["a=1", "b=2"]


def test_head_sends_no_body(serve):
    calls = []

    def app(environ, start_response):
        start_response("200 OK", [("Content-Length", "11")])

        def body():
            calls.append("iterated")
            yield b"hello world"

        return body()

    client = serve(app)
    response = client.request("HEAD")
    assert response.getheader("content-length") == "11"
    assert response.body == b""
    assert calls == ["iterated"]


def test_write(serve):
    def app(environ, start_response):
        write = start_response("200 OK", [])
        write(b"")
        write(b"pushed ")
        write(b"then ")
        return [b"returned"]

    client = serve(app)
    response = client.request()
    assert response.getheader("transfer-encoding") == "chunked"
    assert response.body == b"pushed then returned"


def test_the_result_is_closed(serve):
    closed = threading.Event()

    class Result:
        def __iter__(self):
            yield b"a"
            yield b"b"

        def close(self):
            closed.set()

    client = serve(respond_with(method_body=lambda environ: Result()))
    assert client.request().body == b"ab"
    assert closed.wait(5)


def test_a_file(serve, tmp_path):
    path = tmp_path / "data.bin"
    data = bytes(range(256)) * 4096
    path.write_bytes(data)

    def app(environ, start_response):
        start_response("200 OK", [("Content-Length", str(len(data)))])
        return environ["wsgi.file_wrapper"](path.open("rb"))

    client = serve(app)
    assert client.request().body == data


def test_a_file_from_an_offset_without_a_length(serve, tmp_path):
    path = tmp_path / "data.txt"
    path.write_bytes(b"0123456789")

    def app(environ, start_response):
        start_response("200 OK", [])
        f = path.open("rb")
        f.seek(4)
        return FileWrapper(f)

    client = serve(app)
    response = client.request()
    assert response.getheader("content-length") == "6"
    assert response.body == b"456789"


def test_a_file_with_a_shorter_length(serve, tmp_path):
    path = tmp_path / "data.txt"
    path.write_bytes(b"0123456789")

    def app(environ, start_response):
        start_response("200 OK", [("Content-Length", "3")])
        return FileWrapper(path.open("rb"))

    assert serve(app).request().body == b"012"


def test_a_file_like_object_that_is_not_a_file(serve):
    def app(environ, start_response):
        start_response("200 OK", [])
        return FileWrapper(io.BytesIO(b"x" * 100000), block_size=30000)

    response = serve(app).request()
    assert response.body == b"x" * 100000


def test_a_closed_file_is_read_as_an_iterable(serve, tmp_path):
    path = tmp_path / "data.txt"
    path.write_bytes(b"data")

    class Closed:
        """A wrapper whose file can't tell its position."""

        def __init__(self):
            self.filelike = path.open("rb")
            self.filelike.close()

        def __iter__(self):
            yield b"fallback"

    response = serve(respond_with(method_body=lambda environ: Closed())).request()
    assert response.body == b"fallback"


def test_a_pipe_is_read_as_an_iterable(serve):
    def app(environ, start_response):
        read_end, write_end = os.pipe()
        os.write(write_end, b"through a pipe")
        os.close(write_end)
        start_response("200 OK", [])
        return FileWrapper(os.fdopen(read_end, "rb"))

    assert serve(app).request().body == b"through a pipe"


def test_the_app_raises(serve, capfd):
    def app(environ, start_response):
        raise RuntimeError("boom")

    response = serve(app).request()
    assert response.status == 500
    assert response.body == b"Internal Server Error\n"
    assert "RuntimeError: boom" in capfd.readouterr().err


def test_the_app_raises_while_streaming(serve, capfd):
    def body(environ):
        yield b"a" * 10
        yield b"b" * 10
        raise RuntimeError("halfway")

    client = serve(respond_with(method_body=body))
    answer = client.raw(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    assert answer.startswith(b"HTTP/1.1 200")
    assert b"a" * 10 in answer and b"b" * 10 in answer  # what came before the error
    assert not answer.endswith(b"0\r\n\r\n")  # no last chunk: a truncated body
    assert "RuntimeError: halfway" in capfd.readouterr().err


def test_no_start_response(serve, capfd):
    response = serve(lambda environ, start_response: [b"x"]).request()
    assert response.status == 500
    assert "did not call start_response" in capfd.readouterr().err


def test_start_response_twice(serve, capfd):
    def app(environ, start_response):
        start_response("200 OK", [])
        start_response("200 OK", [])
        return [b""]

    assert serve(app).request().status == 500
    assert "already called" in capfd.readouterr().err


def test_start_response_with_exc_info_replaces_the_head(serve):
    def app(environ, start_response):
        start_response("200 OK", [("X-First", "1")])
        try:
            raise ValueError("oops")
        except ValueError:
            start_response("500 Internal Server Error", [("X-Second", "2")], sys.exc_info())
        return [b"error page"]

    response = serve(app).request()
    assert response.status == 500
    assert response.getheader("x-first") is None
    assert response.body == b"error page"


def test_start_response_with_exc_info_after_the_head_went(serve, capfd):
    def app(environ, start_response):
        write = start_response("200 OK", [])
        write(b"sent")
        try:
            raise ValueError("too late")
        except ValueError:
            start_response("500 Internal Server Error", [], sys.exc_info())
        return [b""]

    answer = serve(app).raw(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    assert answer.startswith(b"HTTP/1.1 200")
    assert b"sent" in answer
    assert not answer.endswith(b"0\r\n\r\n")
    assert "ValueError: too late" in capfd.readouterr().err


def test_an_invalid_header(serve, capfd):
    response = serve(respond_with(headers=[("X-Bad", "a\r\nb")], body=[b"x"])).request()
    assert response.status == 500
    assert "invalid response header" in capfd.readouterr().err


def test_a_client_that_leaves_while_streaming(serve):
    produced = []
    closed = threading.Event()

    class Endless:
        def __iter__(self):
            while True:
                produced.append(1)
                yield b"x" * 65536

        def close(self):
            closed.set()

    def app(environ, start_response):
        start_response("200 OK", [])
        return Endless() if environ["PATH_INFO"] == "/endless" else [b"still here"]

    client = serve(app)
    with socket.create_connection(("127.0.0.1", client.port)) as sock:
        sock.sendall(b"GET /endless HTTP/1.1\r\nHost: x\r\n\r\n")
        sock.recv(1000)
    assert closed.wait(10)  # the worker stopped writing and closed the result
    assert client.request().body == b"still here"


def test_requests_in_parallel(serve):
    started = threading.Barrier(4, timeout=10)

    def app(environ, start_response):
        started.wait()  # four requests at once, on four workers
        start_response("200 OK", [])
        return [environ["PATH_INFO"].encode()]

    client = serve(app, workers=4)
    results = {}

    def get(n):
        results[n] = client.request("GET", f"/{n}").body

    threads = [threading.Thread(target=get, args=(n,)) for n in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert results == {n: f"/{n}".encode() for n in range(4)}


def test_write_after_the_request_ended(serve):
    kept = []

    def app(environ, start_response):
        kept.append(start_response("200 OK", []))
        return [b"ok"]

    client = serve(app)
    assert client.request().body == b"ok"
    errors = []

    def late():  # from another thread, once the exchange is gone
        try:
            kept[0](b"too late")
        except RuntimeError as exc:
            errors.append(str(exc))

    thread = threading.Thread(target=late)
    thread.start()
    thread.join()
    assert errors == ["the request has ended: write() can't send anymore"]


def test_middleware_that_replaces_the_input(serve, capfd):
    kept = []

    def app(environ, start_response):
        original = environ["wsgi.input"]
        kept.append(original)
        environ["wsgi.input"] = io.BytesIO(original.read(2))  # as some middleware does
        start_response("200 OK", [])
        return [environ["wsgi.input"].read()]

    client = serve(app)
    assert client.request("POST", "/", body=b"body").body == b"bo"
    assert capfd.readouterr().err == ""
    with pytest.raises(ValueError, match="request has ended"):
        kept[0].read()  # the original stream was ended all the same


def test_a_wrong_content_length_is_replaced(serve):
    # a middleware that changed the body and kept the old length, say
    client = serve(respond_with(headers=[("Content-Length", "100")], body=[b"hello"]))
    answer = client.raw(
        b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    )
    # both answers, each framed by the length of its body
    assert answer.count(b"HTTP/1.1 200 OK\r\n") == 2
    assert answer.lower().count(b"content-length: 5\r\n") == 2
    assert b"content-length: 100" not in answer.lower()


def test_head_keeps_the_content_length(serve):
    client = serve(respond_with(headers=[("Content-Length", "100")], body=[b"x" * 100]))
    response = client.request("HEAD")
    assert response.getheader("Content-Length") == "100"
    assert response.body == b""


def test_a_file_shorter_than_its_content_length(serve, tmp_path):
    path = tmp_path / "short.txt"
    path.write_bytes(b"0123456789")

    def app(environ, start_response):
        start_response("200 OK", [("Content-Length", "50")])
        return FileWrapper(open(path, "rb"))

    response = serve(app).request()
    assert response.getheader("Content-Length") == "10"
    assert response.body == b"0123456789"


def test_a_nul_in_a_header_is_refused(serve, capfd):
    client = serve(respond_with(headers=[("X-A", "v\0Set-Cookie\0evil")], body=[b"x"]))
    response = client.request()
    assert response.status == 500
    assert response.getheader("Set-Cookie") is None
    assert "a NUL in a response header" in capfd.readouterr().err


def test_read_of_a_size_larger_than_the_body(serve):
    # the size may come from the client (CONTENT_LENGTH): nothing that
    # large is allocated before the bytes arrive
    client = serve(body_app(lambda stream: stream.read(10**12)))
    assert client.request("POST", "/", body=b"abc").body == b"abc"

