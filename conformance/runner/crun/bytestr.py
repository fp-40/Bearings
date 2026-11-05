"""Byte strings of the conformance cases (SPEC.md section 2): the latin-1
mapping between bytes and JSON strings, the substitution of ${name}, the
byte-string spec (a string, or parts with "repeat" and "hex"), the
allowed-keys check and the escaped display of bytes used in failure
messages.

Errors are raised as CaseError with the message the runner prints.

Test tooling only."""

import json


class CaseError(Exception):
    """A case failed or is invalid; the message is what the runner prints."""


def json_text(v) -> str:
    """Compact JSON, non-ASCII kept as is, keys in order."""
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def json_str(s: str) -> str:
    return json_text(s)


def is_u64(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def get_str(o, key: str, default: str = "") -> str:
    """The string at key, or default when absent or not a string."""
    if isinstance(o, dict):
        v = o.get(key)
        if isinstance(v, str):
            return v
    return default


def get_u64(o, key: str):
    """The non-negative integer at key, or None."""
    if isinstance(o, dict):
        v = o.get(key)
        if is_u64(v):
            return v
    return None


def get_bool(o, key: str) -> bool:
    """False when absent or not a boolean."""
    if isinstance(o, dict):
        v = o.get(key)
        if isinstance(v, bool):
            return v
    return False


def latin1(b: bytes) -> str:
    """Every byte as the code point of the same value."""
    return b.decode("latin-1")


def from_latin1(s: str) -> bytes:
    """The inverse: every code point must be <= U+00FF."""
    try:
        return s.encode("latin-1")
    except UnicodeEncodeError as e:
        cp = ord(s[e.start])
        raise CaseError(
            f"byte string contains code point U+{cp:04X} (> U+00FF); use \\u00XX escapes for bytes"
        ) from None


def substitute(s: str, variables: dict, enabled: bool = True) -> str:
    """${name} -> its value; $${ -> ${; other $ kept."""
    if not enabled or "$" not in s:
        return s
    out = []
    k = 0
    n = len(s)
    while k < n:
        c = s[k]
        if c != "$":
            out.append(c)
            k += 1
            continue
        if s.startswith("$${", k):
            out.append("${")
            k += 3
        elif s.startswith("${", k):
            e = s.find("}", k + 2)
            if e < 0:
                raise CaseError(f"unterminated ${{...}} in {show(s.encode('utf-8'), 200)}")
            name = s[k + 2 : e]
            if name not in variables:
                raise CaseError(f"unknown variable ${{{name}}} in {show(s.encode('utf-8'), 200)}")
            out.append(variables[name])
            k = e + 1
        else:
            out.append("$")
            k += 1
    return "".join(out)


def decode_hex(h: str) -> bytes:
    digits = "".join(c for c in h if c not in " \t\n\x0c\r")
    if len(digits) % 2:
        raise CaseError(f"odd number of hex digits in {show(h.encode('utf-8'), 200)}")
    for c in digits:
        if c not in "0123456789abcdefABCDEF":
            raise CaseError(f"invalid hex digit '{c}'")
    return bytes.fromhex(digits)


def decode_bytes(v, variables: dict, with_vars: bool = True) -> bytes:
    """A byte-string spec: a JSON string, an array of parts, or one part object."""
    if isinstance(v, str):
        return from_latin1(substitute(v, variables, with_vars))
    if isinstance(v, list):
        return b"".join(decode_part(p, variables, with_vars) for p in v)
    if isinstance(v, dict):
        return decode_part(v, variables, with_vars)
    raise CaseError(f"expected a byte string, found {json_text(v)}")


def decode_part(p, variables: dict, with_vars: bool) -> bytes:
    if isinstance(p, str):
        return decode_bytes(p, variables, with_vars)
    if isinstance(p, dict):
        if "repeat" in p:
            check_keys(p, ["repeat", "count"])
            unit = decode_bytes(p["repeat"], variables, with_vars)
            count = get_u64(p, "count")
            if count is None:
                raise CaseError('repeat part needs an integer "count"')
            return unit * count
        if "hex" in p:
            check_keys(p, ["hex"])
            h = p["hex"]
            if not isinstance(h, str):
                raise CaseError('"hex" must be a string')
            return decode_hex(h)
    raise CaseError(f"unknown byte-string part {json_text(p)}")


def check_keys(o: dict, allowed) -> None:
    for k in o:
        if k not in allowed:
            raise CaseError(f"unknown field {json_str(k)} (allowed: {', '.join(allowed)})")


def show(b: bytes, limit: int) -> str:
    """The bytes in quotes, with \\r \\n \\t \\\\ \\" and \\xNN escapes, at most
    limit bytes then "... (N bytes total)"."""
    out = ['"']
    for c in b[:limit]:
        if c == 13:
            out.append("\\r")
        elif c == 10:
            out.append("\\n")
        elif c == 9:
            out.append("\\t")
        elif c == 0x5C:
            out.append("\\\\")
        elif c == 0x22:
            out.append('\\"')
        elif 0x20 <= c <= 0x7E:
            out.append(chr(c))
        else:
            out.append(f"\\x{c:02x}")
    if len(b) > limit:
        out.append(f"... ({len(b)} bytes total)")
    out.append('"')
    return "".join(out)


def is_valid_utf8(b: bytes) -> bool:
    """No overlong forms, no surrogates, nothing above U+10FFFF (Python's
    strict decoder rejects all three)."""
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def trim_ctl(b: bytes) -> bytes:
    """Leading and trailing bytes <= 0x20 removed (Pascal's Trim)."""
    return b.strip(bytes(range(33)))


def trim_ows(b: bytes) -> bytes:
    return b.strip(b" \t")
