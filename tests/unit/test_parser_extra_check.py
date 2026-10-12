#!/usr/bin/env python3
"""Check the expectations in test_parser_extra.pas against the real httparse.

Every ExpectReq(...) / ExpectHdrs(...) call in test_parser_extra.pas states
the result line that bearings.http1.parser must produce.  This script reads those
calls out of the Pascal source, runs the same inputs through httparse 1.10.1
(the `expect` binary of test_parser_diff_rs, test tooling only) and fails if
any expected line differs from what httparse returns.

Build the oracle, then run:
  CARGO_TARGET_DIR=<dir> cargo build --offline --release \\
      --manifest-path tests/unit/test_parser_diff_rs/Cargo.toml
  python3 -I tests/unit/test_parser_extra_check.py <dir>/release/expect
"""
import os
import re
import subprocess
import sys

FLAGS = {"F_MULTI_SP": 1, "F_SP_FIRST": 2, "F_IGNORE": 4, "F_RESP_SP_NAME": 8,
         "F_RESP_IGNORE": 16, "F_RESP_FOLD": 32, "F_RESP_MULTI_SP": 64}


def pas_expr(s, i):
    """Evaluate a Pascal string expression ('..', #13, #$0D joined by +)
    starting at s[i]; return (bytes, index of the first byte after it)."""
    out = bytearray()
    while True:
        while s[i] in " \n\t+":
            i += 1
        if s[i] == "'":
            i += 1
            while True:
                if s[i] == "'":
                    if s[i + 1] == "'":
                        out.append(39)
                        i += 2
                        continue
                    i += 1
                    break
                out += s[i].encode("latin-1")
                i += 1
        elif s[i] == "#":
            m = re.match(r"#\$([0-9A-Fa-f]{2})|#(\d+)", s[i:])
            out.append(int(m.group(1), 16) if m.group(1) else int(m.group(2)))
            i += m.end()
        else:
            return bytes(out), i


def read_cases(path):
    src = open(path, encoding="latin-1").read()
    impl = src[src.index("implementation"):]
    cases = []
    for m in re.finditer(r"\b(ExpectReq|ExpectHdrs)\(", impl):
        i = m.end()
        if "const Buf" in impl[i:i + 20]:
            continue  # the declaration of the helper itself
        idm = re.match(r"\s*([A-Z_][A-Z0-9_]*)\s*,", impl[i:])
        if idm and idm.group(1) not in FLAGS:
            cm = re.search(r"\b%s = " % idm.group(1), impl)  # local const
            buf, _ = pas_expr(impl, cm.end())
            i += idm.end() - 1
        else:
            buf, i = pas_expr(impl, i)
        assert impl[i] == ",", impl[i:i + 40]
        i += 1
        flags = 0
        if m.group(1) == "ExpectReq":
            j = impl.index(",", i)
            for tok in re.split(r"\s+or\s+", impl[i:j].strip()):
                flags |= FLAGS[tok] if tok in FLAGS else int(tok)
            i = j + 1
        j = impl.index(",", i)
        slots = int(impl[i:j])
        exp, i = pas_expr(impl, j + 1)
        assert impl[i] == ")", impl[i:i + 40]
        cases.append(("R" if m.group(1) == "ExpectReq" else "H", flags, slots, buf,
                      exp.decode("latin-1")))
    return cases


def main():
    oracle = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    cases = read_cases(os.path.join(here, "test_parser_extra.pas"))
    inp = "".join("%s %d %d %s\n" % (k, f, s, b.hex()) for k, f, s, b, _ in cases)
    out = subprocess.run([oracle], input=inp.encode(), capture_output=True,
                         check=True).stdout.decode().split("\n")
    bad = 0
    for (k, f, s, b, e), got in zip(cases, out):
        if e != got:
            bad += 1
            print("MISMATCH %s flags=%d slots=%d %r\n  test expects: %s\n  httparse:     %s"
                  % (k, f, s, b, e, got))
    print("%d expectations checked against httparse, %d mismatches" % (len(cases), bad))
    sys.exit(1 if bad or not cases else 0)


if __name__ == "__main__":
    main()
