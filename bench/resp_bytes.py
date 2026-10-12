#!/usr/bin/env python3
"""Writes the raw response bytes of a running plaintext server for a fixed
set of requests, with the Date header value normalized, so two servers can be
compared with cmp (docs/design.md section 9; bench/run_gate.sh runs it
before every gate run, decision 12).

Usage: resp_bytes.py <port> <out file>
Cases (one connection each; the output is "== <case>\\n" + bytes per case):
  single     GET /plaintext, keep-alive
  pipelined  16 x GET /plaintext in one write
  notfound   GET /missing
  close      GET /plaintext with Connection: close (read to EOF)
  http10     GET /plaintext HTTP/1.0 (read to EOF)
A keep-alive connection is read until it was idle for 0.3 s."""
import re
import socket
import sys

H = (b'Host: tfb-server\r\n'
     b'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7\r\n')
REQ = b'GET /plaintext HTTP/1.1\r\n' + H + b'Connection: keep-alive\r\n\r\n'
CASES = [
    ('single', REQ, False),
    ('pipelined', REQ * 16, False),
    ('notfound', b'GET /missing HTTP/1.1\r\n' + H + b'\r\n', False),
    ('close', b'GET /plaintext HTTP/1.1\r\n' + H + b'Connection: close\r\n\r\n', True),
    ('http10', b'GET /plaintext HTTP/1.0\r\n' + H + b'\r\n', True),
]


def fetch(port, req, to_eof):
    s = socket.create_connection(('127.0.0.1', port))
    s.sendall(req)
    s.settimeout(5.0 if to_eof else 0.3)
    out = b''
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except socket.timeout:
        if to_eof:
            out += b'<no EOF within 5 s>'
    s.close()
    return re.sub(rb'(?im)^(date: )[^\r\n]*', rb'\1<date>', out)


def main():
    port, path = int(sys.argv[1]), sys.argv[2]
    with open(path, 'wb') as f:
        for name, req, to_eof in CASES:
            f.write(b'== ' + name.encode() + b'\n' + fetch(port, req, to_eof) + b'\n')


if __name__ == '__main__':
    main()
