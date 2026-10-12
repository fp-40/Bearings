#!/usr/bin/env python3
"""Generate fpcunit ports of httparse's req! macro tests.

Usage: python3 -I test_parser_gen.py <httparse-1.10.1 dir> <out dir>

Reads  <httparse>/tests/uri.rs  -> writes <out>/test_parser_uri.pas
       <httparse>/src/lib.rs    -> writes <out>/test_parser_lib_req.pas
Every req! block becomes one published method Test_<rust name>.  Any body
statement the generator does not recognise aborts generation, so nothing is
silently dropped.
"""
import re
import sys

# Hand-ported in test_parser_lib.pas because our API differs (see there).
HAND_PORTED = {"test_request_partial_parses_headers_as_much_as_it_can"}

STR_RE = r'"((?:[^"\\]|\\.|\\\n)*)"'


def rust_unescape(body, is_bytes):
    """Rust (byte) string literal body -> bytes."""
    out = bytearray()
    i = 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out += c.encode("utf-8")
            i += 1
            continue
        n = body[i + 1]
        if n == "n":
            out.append(10); i += 2
        elif n == "r":
            out.append(13); i += 2
        elif n == "t":
            out.append(9); i += 2
        elif n == "0":
            out.append(0); i += 2
        elif n in "\\\"'":
            out.append(ord(n)); i += 2
        elif n == "x":
            out.append(int(body[i + 2:i + 4], 16)); i += 4
        elif n == "\n":
            i += 2
            while i < len(body) and body[i] in " \t\n":
                i += 1
        elif n == "u" and not is_bytes:
            j = body.index("}", i)
            out += chr(int(body[i + 3:j], 16)).encode("utf-8"); i = j + 1
        else:
            raise ValueError("unknown escape \\%s" % n)
    return bytes(out)


def pascal_lit(data):
    """bytes -> Pascal string expression (ASCII-only source, short lines)."""
    if not data:
        return "''"
    tokens = []
    run = ""
    for b in data:
        if 0x20 <= b < 0x7F:
            run += "''" if b == 0x27 else chr(b)
            if len(run) >= 60:
                tokens.append("'" + run + "'")
                run = ""
        else:
            if run:
                tokens.append("'" + run + "'")
                run = ""
            tokens.append("#$%02X" % b)
    if run:
        tokens.append("'" + run + "'")
    lines = []
    cur = ""
    for t in tokens:
        if cur and len(cur) + len(t) > 72:
            lines.append(cur)
            cur = ""
        if cur.endswith("'") and t.startswith("'"):
            cur += " + "  # 'a''b' would be one literal with an embedded quote
        cur += t
    lines.append(cur)
    return " +\n    ".join(lines)


def find_blocks(src):
    """Yield the text inside each `req! { ... }`."""
    pos = 0
    while True:
        m = re.compile(r"^\s*req! \{", re.M).search(src, pos)
        if not m:
            return
        i = m.end()
        depth = 1
        j = i
        while depth:
            c = src[j]
            if c == '"':
                j += 1
                while src[j] != '"':
                    j += 2 if src[j] == "\\" else 1
            elif c == "/" and src[j + 1] == "/":
                j = src.index("\n", j)
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            j += 1
        yield src[i:j - 1]
        pos = j


STATUS = {
    "Ok(Status::Partial)": "CheckPartial;",
    "Ok(crate::Status::Partial)": "CheckPartial;",
}
for kind in ["HeaderName", "HeaderValue", "NewLine", "Status", "Token",
             "TooManyHeaders", "Version"]:
    STATUS["Err(Error::%s)" % kind] = "CheckError(pe%s);" % kind
    STATUS["Err(crate::Error::%s)" % kind] = "CheckError(pe%s);" % kind


def translate_stmt(stmt):
    stmt = stmt.strip()
    m = re.fullmatch(r"assert_eq!\(req\.method\.unwrap\(\), " + STR_RE + r"\);", stmt, re.S)
    if m:
        return "CheckMethod(%s);" % pascal_lit(rust_unescape(m.group(1), False))
    m = re.fullmatch(r"assert_eq!\(req\.path\.unwrap\(\), " + STR_RE + r"\);", stmt, re.S)
    if m:
        return "CheckPath(%s);" % pascal_lit(rust_unescape(m.group(1), False))
    m = re.fullmatch(r"assert_eq!\(req\.version\.unwrap\(\), (\d+)\);", stmt)
    if m:
        return "CheckVersion(%s);" % m.group(1)
    m = re.fullmatch(r"assert_eq!\(req\.headers\.len\(\), (\d+|NUM_OF_HEADERS)\);", stmt)
    if m:
        return "CheckHeaderCount(%s);" % m.group(1)
    m = re.fullmatch(r"assert_eq!\(req\.headers\[(\d+)\]\.name, " + STR_RE + r"\);", stmt, re.S)
    if m:
        return ("name", int(m.group(1)), rust_unescape(m.group(2), False))
    m = re.fullmatch(r"assert_eq!\(req\.headers\[(\d+)\]\.value, &?b" + STR_RE + r"(?:\[\.\.\])?\);",
                     stmt, re.S)
    if m:
        return ("value", int(m.group(1)), rust_unescape(m.group(2), True))
    raise ValueError("unrecognised statement: %r" % stmt)


def split_stmts(body):
    """Split a closure body into statements, skipping // comments."""
    lines = [l for l in body.split("\n") if not l.strip().startswith("//")]
    text = "\n".join(lines)
    stmts = []
    cur = ""
    i = 0
    while i < len(text):
        c = text[i]
        if c == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            cur += text[i:j + 1]
            i = j + 1
            continue
        if c == "/" and text[i + 1] == "/":
            i = text.index("\n", i) if "\n" in text[i:] else len(text)
            continue
        cur += c
        if c == ";":
            stmts.append(cur)
            cur = ""
        i += 1
    if cur.strip():
        raise ValueError("trailing text in body: %r" % cur)
    return stmts


def parse_block(block):
    m = re.match(r"\s*(?://[^\n]*\n\s*)*([a-z0-9_]+),\s*b" + STR_RE + r",\s*", block, re.S)
    if not m:
        raise ValueError("cannot parse block head: %r" % block[:120])
    name = m.group(1)
    buf = rust_unescape(m.group(2), True)
    rest = block[m.end():]
    status = "CheckComplete(Length(FBuf));"
    if not rest.startswith("|"):
        sm = re.match(r"([^|]+?),\s*\|", rest, re.S)
        expr = sm.group(1).strip()
        if expr not in STATUS:
            raise ValueError("unknown status %r in %s" % (expr, name))
        status = STATUS[expr]
        rest = rest[sm.end() - 1:]
    cm = re.match(r"\|(\w+)\|\s*\{(.*)\}\s*$", rest, re.S)
    if not cm:
        raise ValueError("cannot parse closure in %s" % name)
    body_lines = []
    pending = {}
    for stmt in split_stmts(cm.group(2)):
        t = translate_stmt(stmt)
        if isinstance(t, tuple):
            kind, idx, val = t
            pending.setdefault(idx, {})[kind] = val
            if len(pending[idx]) == 2:
                body_lines.append("CheckHeader(%d, %s,\n    %s);" % (
                    idx, pascal_lit(pending[idx]["name"]), pascal_lit(pending[idx]["value"])))
                del pending[idx]
        else:
            body_lines.append(t)
    if pending:
        raise ValueError("unpaired header assertion in %s" % name)
    return name, buf, status, body_lines


def method_name(rust_name):
    """test_foo -> Test_foo (same identifier, Pascal is case-insensitive);
    urltest_001 -> Test_urltest_001."""
    if rust_name.startswith("test_"):
        return "Test_" + rust_name[5:]
    return "Test_" + rust_name


def emit_unit(unit, cls, source_desc, blocks):
    out = []
    out.append("{ GENERATED by test_parser_gen.py from %s." % source_desc)
    out.append("  Do not edit by hand; re-run the generator. }")
    out.append("unit %s;" % unit)
    out.append("")
    out.append("{$mode objfpc}{$H+}")
    out.append("")
    out.append("interface")
    out.append("")
    out.append("uses")
    out.append("  fpcunit, testregistry, bearings.http1.parser, test_parser_base;")
    out.append("")
    out.append("type")
    out.append("  %s = class(TParserTestCase)" % cls)
    out.append("  published")
    for name, _, _, _ in blocks:
        out.append("    procedure %s;" % method_name(name))
    out.append("  end;")
    out.append("")
    out.append("implementation")
    out.append("")
    for name, buf, status, body in blocks:
        out.append("procedure %s.%s;" % (cls, method_name(name)))
        out.append("begin")
        out.append("  ParseReq(%s);" % pascal_lit(buf))
        out.append("  " + status)
        for line in body:
            out.append("  " + line)
        out.append("end;")
        out.append("")
    out.append("initialization")
    out.append("  RegisterTest(%s);" % cls)
    out.append("end.")
    return "\n".join(out) + "\n"


def main():
    root, outdir = sys.argv[1], sys.argv[2]
    uri_src = open(root + "/tests/uri.rs", encoding="utf-8").read()
    uri_blocks = [parse_block(b) for b in find_blocks(uri_src) if not b.lstrip().startswith("$")]
    with open(outdir + "/test_parser_uri.pas", "w") as f:
        f.write(emit_unit("test_parser_uri", "TTestHttparseUri",
                          "httparse v1.10.1 tests/uri.rs", uri_blocks))
    lib_src = open(root + "/src/lib.rs", encoding="utf-8").read()
    lib_src = lib_src[lib_src.index("mod tests {"):]
    lib_src = lib_src[:lib_src.index("macro_rules! res")]
    lib_blocks = [parse_block(b) for b in find_blocks(lib_src) if not b.lstrip().startswith("$")]
    lib_blocks = [b for b in lib_blocks if b[0] not in HAND_PORTED]  # noqa
    with open(outdir + "/test_parser_lib_req.pas", "w") as f:
        f.write(emit_unit("test_parser_lib_req", "TTestHttparseLibReq",
                          "httparse v1.10.1 src/lib.rs (req! macro tests)", lib_blocks))
    print("uri.rs: %d tests; lib.rs req!: %d tests (+%d hand-ported)" % (
        len(uri_blocks), len(lib_blocks), len(HAND_PORTED)))


if __name__ == "__main__":
    main()
