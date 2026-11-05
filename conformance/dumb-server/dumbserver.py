"""dumbserver - a mutation check for the conformance cases (test tooling only).

It implements the process protocol of SPEC.md section 3 (the LISTENING
line, the stdin control commands with acknowledgements, "exit", exit at the
end of stdin) and nothing else of the contract. The server spec passed
with --config is ignored. Every time the bytes received on a connection
hold a CRLF CRLF, everything up to and including it counts as one
"request", and the server writes

    HTTP/1.1 200 OK CRLF content-length: 0 CRLF CRLF

Request bodies are not parsed (their bytes become part of the next
"request"). The connection is closed when the client sends EOF or the
socket fails. No date field, no keep-alive logic, no error responses, no
timeouts, no upgrades.

Events: by default only control_ack / control_error. With --events, also
conn_open, a request event per "request" (method, target and version split
from the first line; fields split at the first colon, names lowercased, in
received order), and conn_close with outcome ok when the socket closes.

A case that PASSES against this server checks less than a fixed 200
response can satisfy. See MANIFEST.md for how each such case was judged.

Usage: dumbserver.py [--events] --config <file>
"""

import os
import socket
import sys
import threading

RESPONSE = b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"

out_lock = threading.Lock()
events = "--events" in sys.argv[1:]
conns = 0


def jstr(b: bytes) -> str:
    """A byte string as a JSON string literal (SPEC.md section 2: latin-1)."""
    out = ['"']
    for c in b:
        if c == 0x22:
            out.append('\\"')
        elif c == 0x5C:
            out.append("\\\\")
        elif c <= 0x1F or c >= 0x7F:
            out.append(f"\\u00{c:02x}")
        else:
            out.append(chr(c))
    out.append('"')
    return "".join(out)


def emit(line: str) -> None:
    with out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def request_event(conn: int, req: int, head: bytes) -> str:
    lines = [line[:-1] if line.endswith(b"\r") else line for line in head.split(b"\n")]
    parts = lines[0].split(b" ", 2)
    method = parts[0]
    target = parts[1] if len(parts) > 1 else b""
    version = parts[2] if len(parts) > 2 else b""
    fields = []
    for line in lines[1:]:
        if not line:
            continue
        c = line.find(b":")
        if c < 0:
            continue
        fields.append(
            "["
            + jstr(line[:c].lower())
            + ","
            + jstr(line[c + 1 :].strip(bytes(range(33))))
            + "]"
        )
    return (
        f'{{"event":"request","conn":{conn},"req":{req},"method":{jstr(method)},'
        f'"target":{jstr(target)},"version":{jstr(version)},"headers":[{",".join(fields)}]}}'
    )


def serve(sock: socket.socket, conn_id: int) -> None:
    if events:
        emit(f'{{"event":"conn_open","conn":{conn_id}}}')
    buf = b""
    req = 0
    try:
        while True:
            try:
                chunk = sock.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while True:
                i = buf.find(b"\r\n\r\n")
                if i < 0:
                    break
                req += 1
                if events:
                    emit(request_event(conn_id, req, buf[:i]))
                buf = buf[i + 4 :]
                try:
                    sock.sendall(RESPONSE)
                except OSError:
                    raise SystemExit from None
    except SystemExit:
        pass
    sock.close()
    if events:
        emit(f'{{"event":"conn_close","conn":{conn_id},"outcome":"ok"}}')


def read_stdin() -> None:
    for raw in sys.stdin.buffer:
        line = raw.rstrip(b"\r\n")
        if line == b"exit":
            os._exit(0)
        elif line == b"graceful_shutdown":
            emit('{"event":"control_ack","command":"graceful_shutdown"}')
        elif line.startswith(b"signal "):
            emit(
                f'{{"event":"control_ack","command":"signal","name":{jstr(line[7:])}}}'
            )
        else:
            emit(f'{{"event":"control_error","line":{jstr(line)}}}')
    # the end of stdin: the runner is gone
    os._exit(0)


def main() -> None:
    global conns
    listener = socket.create_server(("127.0.0.1", 0), backlog=128)
    emit(f"LISTENING {listener.getsockname()[1]}")
    threading.Thread(target=read_stdin, daemon=True).start()
    while True:
        try:
            sock, _ = listener.accept()
        except OSError:
            continue
        conns += 1
        threading.Thread(target=serve, args=(sock, conns), daemon=True).start()


if __name__ == "__main__":
    main()
