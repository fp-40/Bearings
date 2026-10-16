import http.client
import os
import signal
import socket
import threading
import time

import pytest

from bearings import BodyError, ClientDisconnected, Server, serve


def hello(environ, start_response):
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"hello"]


def test_a_free_port(serve):
    client = serve(hello, port=0)
    assert client.port > 0
    assert client.request().body == b"hello"


def test_a_unix_socket(tmp_path):
    path = str(tmp_path / "app.sock")
    with Server(hello, unix_path=path, loops=1, workers=1) as server:
        assert server.port == 0
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(path)
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            answer = b""
            while chunk := sock.recv(4096):
                answer += chunk
    assert answer.endswith(b"\r\n\r\nhello")
    assert not os.path.exists(path)  # removed when the server stopped


def test_unix_socket_environ(tmp_path):
    seen = {}

    def app(environ, start_response):
        seen.update(name=environ["SERVER_NAME"], server_port=environ["SERVER_PORT"],
                    addr=environ["REMOTE_ADDR"], port=environ["REMOTE_PORT"])
        return hello(environ, start_response)

    path = str(tmp_path / "app.sock")
    with Server(app, unix_path=path, loops=1, workers=1):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(path)
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            while sock.recv(4096):
                pass
    assert seen == {"name": path, "server_port": "", "addr": "", "port": ""}


def test_an_inherited_socket():
    listener = socket.create_server(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    with Server(hello, fd=listener.detach(), loops=1, workers=1) as server:
        assert server.port == port
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", "/")
        assert conn.getresponse().read() == b"hello"
        conn.close()


def test_a_port_in_use():
    taken = socket.create_server(("127.0.0.1", 0))
    try:
        server = Server(hello, host="127.0.0.1", port=taken.getsockname()[1], loops=1)
        with pytest.raises(OSError):
            server.start()
    finally:
        taken.close()


def test_negative_workers():
    with pytest.raises(OSError, match="workers"):
        Server(hello, workers=-1).start()


def test_an_unknown_access_log():
    with pytest.raises(ValueError, match="access_log"):
        Server(hello, access_log="xml")


def test_not_running():
    server = Server(hello)
    with pytest.raises(RuntimeError):
        server.port  # noqa: B018
    with pytest.raises(RuntimeError):
        server.metrics()
    server.stop()  # nothing to stop
    server.wait()


def test_start_twice_and_wait_twice():
    server = Server(hello, host="127.0.0.1", loops=1, workers=1)
    server.start()
    port = server.port
    server.start()
    assert server.port == port
    server.stop(grace=1)
    server.wait()
    server.wait()


def test_metrics(serve):
    client = serve(hello, metrics=True)
    client.request()
    text = client.server.metrics()
    assert "bearings_requests_total 1" in text
    assert 'bearings_responses_total{status="2xx"} 1' in text


def test_access_log(capfd):
    with Server(hello, host="127.0.0.1", loops=1, workers=1, access_log="combined") as server:
        conn = http.client.HTTPConnection("127.0.0.1", server.port, timeout=5)
        conn.request("GET", "/logged?q=1")
        conn.getresponse().read()
        conn.close()
    # written by the flusher thread, on the file descriptor 1
    assert '"GET /logged?q=1 HTTP/1.1" 200 5' in capfd.readouterr().out


def test_a_full_queue_is_answered_with_503(serve):
    release = threading.Event()
    entered = threading.Event()

    def slow(environ, start_response):
        entered.set()
        release.wait(10)
        return hello(environ, start_response)

    client = serve(slow, workers=1, queue_limit=1)
    results = []

    def get():
        results.append(client.request().status)

    first = threading.Thread(target=get)
    first.start()
    assert entered.wait(5)  # the only worker is busy
    second = threading.Thread(target=get)
    second.start()  # waits in the queue, now full
    time.sleep(0.2)
    assert client.request().status == 503
    release.set()
    first.join()
    second.join()
    assert results == [200, 200]


def reading_app(errors, done):
    def app(environ, start_response):
        try:
            environ["wsgi.input"].read()
        except BodyError as exc:
            errors.append(exc)
        finally:
            done.set()
        return hello(environ, start_response)

    return app


def test_a_body_cut_short(serve):
    errors = []
    done = threading.Event()
    client = serve(reading_app(errors, done))
    with socket.create_connection(("127.0.0.1", client.port)) as sock:
        sock.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\npart")
    assert done.wait(5)
    assert [repr(exc) for exc in errors] == [
        "BodyError('end of file before message length reached')"
    ]


def test_a_read_canceled_by_the_shutdown(serve):
    errors = []
    done = threading.Event()
    client = serve(reading_app(errors, done))
    with socket.create_connection(("127.0.0.1", client.port)) as sock:
        sock.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\npart")
        time.sleep(0.2)  # the worker waits for the rest of the body
        client.server.stop(grace=0.2)  # then gives up on the connection
        assert done.wait(5)
    client.server.wait()
    assert [type(exc) for exc in errors] == [ClientDisconnected]


def test_stop_does_not_wait_for_idle_connections(serve):
    client = serve(hello)
    conn = http.client.HTTPConnection("127.0.0.1", client.port, timeout=5)
    conn.request("GET", "/")
    conn.getresponse().read()  # the connection stays open, idle
    started = time.monotonic()
    client.server.stop(grace=10)
    client.server.wait()
    assert time.monotonic() - started < 2
    conn.close()


def test_stop_lets_a_request_finish(serve):
    entered = threading.Event()

    def slow(environ, start_response):
        entered.set()
        time.sleep(0.3)
        return hello(environ, start_response)

    client = serve(slow)
    results = []
    thread = threading.Thread(target=lambda: results.append(client.request().body))
    thread.start()
    assert entered.wait(5)
    client.server.stop(grace=5)
    client.server.wait()
    thread.join()
    assert results == [b"hello"]


@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM])
def test_serve_until_a_signal(signum):
    listener = socket.create_server(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    previous = signal.getsignal(signum)
    answers = []

    def client():
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        for _ in range(50):  # until the server listens
            try:
                conn.request("GET", "/")
                answers.append(conn.getresponse().read())
                break
            except OSError:
                time.sleep(0.05)
        conn.close()
        os.kill(os.getpid(), signum)  # to the process: any thread may get it

    thread = threading.Thread(target=client)
    thread.start()
    ports = []
    serve(hello, fd=listener.detach(), loops=1, workers=1, grace=1,
          started=lambda server: ports.append(server.port))
    thread.join()
    assert answers == [b"hello"]
    assert ports == [port]
    assert signal.getsignal(signum) is previous


def test_a_host_name_is_looked_up():
    with Server(hello, host="localhost", loops=1, workers=1) as server:
        address = socket.getaddrinfo("localhost", None, type=socket.SOCK_STREAM,
                                     flags=socket.AI_PASSIVE)[0][4][0]
        conn = http.client.HTTPConnection(address, server.port, timeout=5)
        conn.request("GET", "/")
        assert conn.getresponse().read() == b"hello"
        conn.close()


def test_a_host_that_cannot_be_found():
    with pytest.raises(socket.gaierror):
        Server(hello, host="no-such-host.invalid").start()


def test_the_reason_a_port_cannot_be_listened_on():
    import errno

    taken = socket.create_server(("127.0.0.1", 0))
    try:
        server = Server(hello, host="127.0.0.1", port=taken.getsockname()[1], loops=1)
        with pytest.raises(OSError, match="in use") as error:
            server.start()
        assert error.value.errno == errno.EADDRINUSE
    finally:
        taken.close()


def test_a_server_whose_last_reference_is_dropped():
    import gc

    from bearings import server as server_module

    server = Server(hello, host="127.0.0.1", loops=1, workers=1)
    server.start()
    port = server.port
    del server
    gc.collect()  # the callbacks C calls must outlive the reference
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/")
    assert conn.getresponse().read() == b"hello"
    conn.close()
    (running,) = server_module._running
    running.stop(grace=1)
    running.wait()
    assert not server_module._running


def test_calls_from_other_threads_while_the_server_is_freed():
    from bearings import WebSocketHandler

    for _ in range(20):
        server = Server(hello, host="127.0.0.1", loops=1, workers=1, websocket=WebSocketHandler())
        server.start()
        outcomes = []

        def hammer(server=server, outcomes=outcomes):
            try:
                while True:
                    server.publish("news", "x")
                    server.websockets  # noqa: B018
            except RuntimeError:  # the server stopped: no use-after-free
                outcomes.append("stopped")

        threads = [threading.Thread(target=hammer) for _ in range(4)]
        for thread in threads:
            thread.start()
        server.stop(grace=0)
        server.wait()
        for thread in threads:
            thread.join()
        assert outcomes == ["stopped"] * 4


def test_serve_with_a_wrong_option_leaves_the_signals_alone():
    previous = {signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)}
    previous_fd = signal.set_wakeup_fd(-1)
    signal.set_wakeup_fd(previous_fd)
    with pytest.raises(ValueError):
        serve(hello, access_log="nonsense")
    assert {signum: signal.getsignal(signum) for signum in previous} == previous
    assert signal.set_wakeup_fd(previous_fd) == previous_fd
