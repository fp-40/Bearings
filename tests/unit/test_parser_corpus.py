#!/usr/bin/env python3
"""Write a deterministic corpus of request-like inputs for the parser's
expected-value test (test_parser_golden.sh) and the split fuzz.

Usage: python3 -I test_parser_corpus.py <out file> [random cases] [seed]

Format: repeated (u32 little-endian length, bytes).  Contents:
  1. every prefix of each seed request;
  2. every string of length 1..4 over a small alphabet of delimiter bytes;
  3. "GET / " followed by every string of length 1..3 over a version
     alphabet, plus CRLF CRLF;
  4. random mutations (replace / insert / delete / duplicate / truncate)
     of the seeds, biased toward bytes that matter to the grammar;
  5. every prefix of each long seed, and every one of the 256 byte values
     substituted at every position of it.  The long seeds have a 71-byte
     path and 78-byte header values, so a vectorized scanner (32-byte or
     8-byte blocks) runs over several blocks and the tail, with the bad
     byte in each lane.
"""
import itertools
import random
import struct
import sys


SEEDS = [
    b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
    b"POST /submit?x=1 HTTP/1.0\r\nContent-Length: 5\r\nX: y\r\n\r\nhello",
    b"\r\n\nOPTIONS * HTTP/1.1\nA:b\n\n",
    b"GET   /foo   HTTP/1.1\r\n Leading: ws\r\nBad Name: v\r\nOk: v\t \r\n\r\n",
    b"GET /caf\xc3\xa9/\xe2\x82\xac/\xf0\x9f\x98\x80 HTTP/1.1\r\nUA: \xe3\x81\xb2\r\n\r\n",
    b"GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\nE: 5\r\nF: 6\r\n\r\n",
    b"Foo: bar\r\nBaz:qux \t\r\n\r\n",
    b"PATCH /a/b;c?d=e&f#g HTTP/1.1\r\nCookie: \r\nX-Empty:\r\nX-Tab:\tv\r\n\r\n",
    b'M-SEARCH * HTTP/1.1\r\nST: ssdp:all\r\nMan: "ssdp:discover"\r\n\r\n',
    b"GET / HTTP/1.1\r\nBad\x00Name: v\r\nGood: v\r\n\r\n",
    b"GET / HTTP/1.1\r\nX: a\x01b\r\nGood: v\r\n\r\n",
    b"GET / HTTP/1.1\r\n: empty\r\nX\r\nY : z\r\n  fold\r\nOk: 1\r\n\r\n",
    b"GET /\x7f HTTP/1.1\r\n\r\n",
    b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
]

LONG_SEEDS = [
    b"GET /" + b"abcdefghij" * 7 + b" HTTP/1.1\r\nUser-Agent: " + b"v" * 37 + b"\t"
    + b"w" * 40 + b"\r\nH: v\r\n\r\n",
    b"Name: value\r\nOther:" + b"v" * 37 + b"\t" + b"w" * 40 + b"\r\n\r\n",
]

INTERESTING = b" \t\r\n\x00:\x7f\x80\xff\xc3\xa9\xed\xa0\xf4\x90\xe0\x9f\xc0\xf0\xbf/HTP1.0\x01\x0b\x0c;?#%Aa_~\"'"
SHORT_ALPHA = b"G /\r\n: \tH1"
VERSION_ALPHA = b"HTP/1.02 \r\n"


def mutate(rng, data):
    data = bytearray(data)
    for _ in range(rng.randint(1, 4)):
        op = rng.randrange(5)
        pos = rng.randrange(len(data) + 1)
        b = rng.choice(INTERESTING) if rng.random() < 0.8 else rng.randrange(256)
        if op == 0 and pos < len(data):
            data[pos] = b
        elif op == 1:
            data.insert(pos, b)
        elif op == 2 and pos < len(data):
            del data[pos]
        elif op == 3 and data:
            a = rng.randrange(len(data))
            seg = data[a:a + rng.randint(1, 8)]
            data[pos:pos] = seg
        elif op == 4:
            del data[pos:]
    return bytes(data)


def main():
    out = sys.argv[1]
    n_random = int(sys.argv[2]) if len(sys.argv) > 2 else 50000
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    rng = random.Random(seed)
    cases = []
    for s in SEEDS:
        cases.extend(s[:i] for i in range(len(s) + 1))
    for n in range(1, 5):
        cases.extend(bytes(t) for t in itertools.product(SHORT_ALPHA, repeat=n))
    for n in range(1, 4):
        cases.extend(b"GET / " + bytes(t) + b"\r\n\r\n"
                     for t in itertools.product(VERSION_ALPHA, repeat=n))
    for _ in range(n_random):
        cases.append(mutate(rng, rng.choice(SEEDS)))
    for s in LONG_SEEDS:
        cases.extend(s[:i] for i in range(len(s) + 1))
        for i in range(len(s)):
            cases.extend(s[:i] + bytes([b]) + s[i + 1:] for b in range(256))
    with open(out, "wb") as f:
        for c in cases:
            f.write(struct.pack("<I", len(c)))
            f.write(c)
    print("%d cases written to %s" % (len(cases), out))


if __name__ == "__main__":
    main()
