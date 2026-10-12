#!/usr/bin/env python3
"""Inputs of the split fuzz (tests/unit/test_split_fuzz.pas, M3 step S9,
design m3-transport.md 7.5) from the conformance case files.

Usage: python3 -I test_split_fuzz_cases.py <out file> <case file or dir>...

For every case and every named connection of it: the case's server spec and
the bytes the client writes on that connection (the data of its `write`
steps, in order; `${port}`, `${server_port}`, `${proxy_port}` become 80).
The in-process fuzz delivers these bytes and then, once the connection has
nothing more to do, EOF; the other steps (reads, sleeps, control commands,
half-closes) do not exist there.

Changes to the spec, so that one run does not depend on time:
  - every `delay_ms` (reply, stream item) is removed;
  - a numeric `header_read_timeout_ms` becomes 600000 (the timer is armed,
    it never fires within a run).
Skipped: cases with a reply that has an `upgrade` (the upgrade task needs a
socket) and `pending` cases.

Format: repeated records of three (u32 little-endian length, bytes) fields:
name ('<file stem>::<case>#<conn>'), spec JSON, input.
"""
import glob
import json
import os
import struct
import sys


def decode(v):
    if isinstance(v, str):
        b = v.encode("latin-1")
    else:
        b = b""
        for p in v:
            if isinstance(p, str):
                b += p.encode("latin-1")
            elif "repeat" in p:
                b += decode(p["repeat"]) * p["count"]
            elif "hex" in p:
                b += bytes.fromhex("".join(p["hex"].split()))
            else:
                raise ValueError(p)
    for var in (b"${port}", b"${server_port}", b"${proxy_port}"):
        b = b.replace(var, b"80")
    return b.replace(b"$${", b"${")


def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if k != "delay_ms"}
    if isinstance(o, list):
        return [strip(x) for x in o]
    return o


def has_upgrade(server):
    return any(isinstance(r, dict) and "upgrade" in r for r in server.get("replies", []))


def main():
    out = open(sys.argv[1], "wb")
    files = []
    for a in sys.argv[2:]:
        files += sorted(glob.glob(os.path.join(a, "**", "*.json"), recursive=True)) if os.path.isdir(a) else [a]
    n = skipped = 0
    for f in files:
        doc = json.load(open(f))
        stem = os.path.splitext(os.path.basename(f))[0]
        for case in doc["cases"]:
            server = case.get("server", {})
            if case.get("pending") or has_upgrade(server):
                skipped += 1
                continue
            server = strip(server)
            cfg = server.get("config", {})
            if isinstance(cfg.get("header_read_timeout_ms"), int):
                cfg["header_read_timeout_ms"] = 600000
            spec = json.dumps(server).encode()
            conns = {}
            for st in case["steps"]:
                if st["op"] == "write":
                    c = st.get("conn", "main")
                    conns[c] = conns.get(c, b"") + decode(st["data"])
            for c, data in conns.items():
                name = ("%s::%s#%s" % (stem, case["name"], c)).encode()
                for field in (name, spec, data):
                    out.write(struct.pack("<I", len(field)) + field)
                n += 1
    print("%d inputs written, %d cases skipped" % (n, skipped))


main()
