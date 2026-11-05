"""The reader of the read_response step: a minimal, permissive HTTP/1.x
response reader that frames one response by the rules of RFC 9112 section
6.3 (no body for HEAD, 1xx, 204 and 304; chunked when the last transfer
coding is chunked, else read until close; else Content-Length; else read
until close), so that the following steps see the bytes after it.

Test tooling only."""

from dataclasses import dataclass, field

from .bytestr import CaseError, latin1, show, trim_ows
from .conn import OPEN, RESET, TIMEOUT, now_us


@dataclass
class Parsed:
    version: bytes = b""
    status: int = 0
    reason: bytes = b""
    headers: list = field(default_factory=list)   # [(name, value)]
    body: bytes = b""
    trailers: list = field(default_factory=list)
    framing: str = "none"                         # none | content-length | chunked | close
    raw: bytes = b""


def field_values(fields, name: bytes):
    name = name.lower()
    return [(n, v) for n, v in fields if n.lower() == name]


def fields_show(fields) -> str:
    return " | ".join(latin1(n) + ": " + latin1(v) for n, v in fields)


def parse_fields(block: bytes):
    out = []
    for line in block.split(b"\n"):
        if line.endswith(b"\r"):
            line = line[:-1]
        if not line:
            continue
        colon = line.find(b":")
        if colon < 0:
            raise CaseError(f"malformed field line {show(line, 200)}")
        out.append((line[:colon], trim_ows(line[colon + 1 :])))
    return out


def _incomplete(eof: bool, what: str):
    if eof:
        raise CaseError(f"connection ended in the middle of the {what}")
    return None


def _chunk_size(line: bytes) -> int:
    s = line.split(b";", 1)[0]
    s = trim_ows(s)
    if s.startswith(b"+"):
        s = s[1:]
    if not s or any(c not in b"0123456789abcdefABCDEF" for c in s):
        raise CaseError(f"invalid chunk size line {show(line, 200)}")
    size = int(s, 16)
    if size > 0xFFFFFFFFFFFFFFFF:
        raise CaseError(f"invalid chunk size line {show(line, 200)}")
    return size


def try_parse(buf: bytes, is_head: bool, eof: bool):
    """One response at the front of buf: (Parsed, used bytes), or None when
    more bytes are needed."""
    p = Parsed()
    head_end = buf.find(b"\r\n\r\n")
    if head_end < 0:
        if eof:
            raise CaseError("connection ended before a complete response head")
        return None
    head = buf[:head_end]
    line_end = head.find(b"\r\n")
    if line_end >= 0:
        status_line, rest = head[:line_end], head[line_end + 2 :]
    else:
        status_line, rest = head, b""
    parts = status_line.split(b" ", 2)
    p.version = parts[0]
    code = parts[1] if len(parts) > 1 else b""
    p.reason = parts[2] if len(parts) > 2 else b""
    if not p.version.startswith(b"HTTP/") or len(code) != 3 or not code.isdigit():
        raise CaseError(f"malformed status line {show(status_line, 200)}")
    p.status = int(code)
    p.headers = parse_fields(rest)
    pos = head_end + 4
    te = field_values(p.headers, b"transfer-encoding")
    cl = field_values(p.headers, b"content-length")
    if is_head or 100 <= p.status < 200 or p.status in (204, 304):
        p.framing = "none"
    elif te:
        joined = b",".join(v for _, v in te)
        last = trim_ows(joined.rsplit(b",", 1)[-1])
        if last.lower() == b"chunked":
            p.framing = "chunked"
            body = []
            while True:
                line_end = buf.find(b"\r\n", pos)
                if line_end < 0:
                    return _incomplete(eof, "chunk size line")
                size = _chunk_size(buf[pos:line_end])
                pos = line_end + 2
                if size == 0:
                    tpos = pos
                    while True:
                        le = buf.find(b"\r\n", tpos)
                        if le < 0:
                            return _incomplete(eof, "trailer section")
                        if le == tpos:
                            p.trailers = parse_fields(buf[pos:tpos])
                            pos = le + 2
                            break
                        tpos = le + 2
                    break
                if len(buf) < pos + size + 2:
                    return _incomplete(eof, "chunk data")
                body.append(buf[pos : pos + size])
                if buf[pos + size : pos + size + 2] != b"\r\n":
                    raise CaseError("chunk data not followed by CRLF")
                pos += size + 2
            p.body = b"".join(body)
        else:
            p.framing = "close"
    elif cl:
        for _, v in cl:
            if v != cl[0][1] or not v or not v.isdigit():
                raise CaseError(f"invalid content-length {fields_show(cl)}")
        if len(cl[0][1]) > 18:
            raise CaseError("content-length overflow")
        size = int(cl[0][1])
        p.framing = "content-length"
        if len(buf) < pos + size:
            return _incomplete(eof, "content-length body")
        p.body = buf[pos : pos + size]
        pos += size
    else:
        p.framing = "close"
    if p.framing == "close":
        if not eof:
            return None
        p.body += buf[pos:]
        pos = len(buf)
    p.raw = buf[:pos]
    return p, pos


def read_response(c, is_head: bool, timeout_ms: int, allow_reset: bool):
    """Reads one response from c: (Parsed, end state, done_at)."""
    while True:
        if c.end == RESET and not allow_reset:
            raise CaseError("connection reset by peer (set allow_reset to accept)")
        r = try_parse(c.buf, is_head, c.end != OPEN)
        if r is not None:
            p, used = r
            c.buf = c.buf[used:]
            return p, c.end, now_us()
        if c.read_some(timeout_ms) == TIMEOUT:
            raise CaseError(
                f"timed out after {timeout_ms} ms waiting for response bytes ({len(c.buf)} buffered)"
            )
