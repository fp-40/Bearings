# open N keep-alive connections, one request each, keep them idle; print when ready, wait for stdin
import socket, sys, selectors
port, n = int(sys.argv[1]), int(sys.argv[2])
req = b"GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"
socks = []
for i in range(n):
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(req)
    socks.append(s)
got = 0
for s in socks:
    buf = b""
    while b"Hello, world!" not in buf:
        d = s.recv(4096)
        if not d: break
        buf += d
    got += 1
print("ready", got, flush=True)
sys.stdin.readline()
