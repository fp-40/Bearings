"""Capture normalization, step assertions and event patterns (SPEC.md
sections 10, 11 and 12).

normalize replaces the value of every date field that is an IMF-fixdate
(CRLF "date:" [SP/HTAB]* "Sun, 06 Nov 1994 08:49:37 GMT", the field name,
the day and month names and GMT in any case) with CANONICAL_DATE, which
has the same length.

Test tooling only."""

from dataclasses import dataclass

from .bytestr import (
    CaseError,
    check_keys,
    decode_bytes,
    get_bool,
    get_str,
    is_u64,
    is_valid_utf8,
    json_str,
    json_text,
    latin1,
    show,
    substitute,
)
from .conn import OPEN
from .response import Parsed, field_values, fields_show


CANONICAL_DATE = b"Sun, 06 Nov 1994 08:49:37 GMT"

BYTE_KINDS = ("equals", "starts_with", "ends_with", "contains", "not_contains", "len", "min_len",
              "max_len", "utf8")
OTHER_KINDS = ("end", "read_result", "status", "reason", "version", "framing", "header", "trailer",
               "body")
READ_RESULTS = ("data", "eof", "reset", "timeout")
DAYS = (b"mon", b"tue", b"wed", b"thu", b"fri", b"sat", b"sun")
MONTHS = (b"jan", b"feb", b"mar", b"apr", b"may", b"jun", b"jul", b"aug", b"sep", b"oct", b"nov",
          b"dec")


@dataclass
class Capture:
    raw: bytes = b""
    norm: bytes = b""
    end: str = OPEN
    resp: Parsed | None = None
    read_result: str = ""              # read_once only


# ---- normalization ----

def _fixdate_at(s: bytes, p: int) -> bool:
    if p + 29 > len(s):
        return False
    low = s[p : p + 29].lower()
    return (low[0:3] in DAYS and low[3:5] == b", " and low[5:7].isdigit() and low[7:8] == b" "
            and low[8:11] in MONTHS and low[11:12] == b" " and low[12:16].isdigit()
            and low[16:17] == b" " and low[17:19].isdigit() and low[19:20] == b":"
            and low[20:22].isdigit() and low[22:23] == b":" and low[23:25].isdigit()
            and low[25:29] == b" gmt")


def normalize(b: bytes) -> bytes:
    out = []
    k = 0
    n = len(b)
    while True:
        p = b.find(b"\r\n", k)
        if p < 0:
            break
        if b[p + 2 : p + 7].lower() == b"date:":
            v = p + 7
            while v < n and b[v] in b" \t":
                v += 1
            if _fixdate_at(b, v):
                out.append(b[k:v])
                out.append(CANONICAL_DATE)
                k = v + 29
                continue
        out.append(b[k : p + 2])
        k = p + 2
    out.append(b[k:])
    return b"".join(out)


# ---- step assertions ----

def _need_resp(cap: Capture, kind: str) -> Parsed:
    if cap.resp is None:
        raise CaseError(f"assertion {json_str(kind)} is only valid on a read_response step")
    return cap.resp


def _str_list(items) -> str:
    return "[" + ", ".join(json_str(x) for x in items) + "]"


def check_simple(kind: str, v, m: dict, cap: Capture, variables: dict) -> None:
    if kind == "end":
        if not isinstance(v, str):
            raise CaseError("end: expected a string")
        if v == "closed":
            ok = cap.end != OPEN
        elif v in ("eof", "reset", "open"):
            ok = cap.end == v
        else:
            raise CaseError(f"end: unknown value {json_str(v)}")
        if not ok:
            raise CaseError(f"expected end {json_str(v)}, connection state is {json_str(cap.end)}")
        return
    if kind == "read_result":
        if not cap.read_result:
            raise CaseError('assertion "read_result" is only valid on a read_once step')
        if isinstance(v, str):
            wants = [v]
        elif isinstance(v, list) and all(isinstance(x, str) for x in v):
            wants = v
        else:
            raise CaseError("read_result: expected a string or an array of strings")
        if not wants:
            raise CaseError("read_result: the array must not be empty")
        for w in wants:
            if w not in READ_RESULTS:
                raise CaseError(f"read_result: unknown value {json_str(w)} (expected one of "
                                f"{_str_list(READ_RESULTS)})")
        if cap.read_result not in wants:
            raise CaseError(f"expected read_result in {_str_list(wants)}, got {json_str(cap.read_result)}")
        return
    if kind == "status":
        resp = _need_resp(cap, kind)
        if not is_u64(v):
            raise CaseError("status: expected an integer")
        if resp.status != v:
            raise CaseError(f"expected status {v}, got {resp.status}")
        return
    if kind == "reason":
        resp = _need_resp(cap, kind)
        want = decode_bytes(v, variables)
        if resp.reason != want:
            raise CaseError(f"expected reason {show(want, 200)}, got {show(resp.reason, 200)}")
        return
    if kind == "version":
        resp = _need_resp(cap, kind)
        if not isinstance(v, str):
            raise CaseError("version: expected a string")
        if latin1(resp.version) != v:
            raise CaseError(f"expected version {json_str(v)}, got {json_str(latin1(resp.version))}")
        return
    if kind == "framing":
        resp = _need_resp(cap, kind)
        if not isinstance(v, str):
            raise CaseError("framing: expected a string")
        if resp.framing != v:
            raise CaseError(f"expected framing {json_str(v)}, got {json_str(resp.framing)}")
        return
    if kind == "body":
        resp = _need_resp(cap, kind)
        want = decode_bytes(v, variables)
        if resp.body != want:
            raise CaseError(f"expected decoded body {show(want, 400)}, got {show(resp.body, 400)}")
        return

    # the byte kinds, on the selected scope
    base = cap.raw if get_bool(m, "raw") else cap.norm
    scope = get_str(m, "scope", "all")
    if scope == "all":
        subject = base
    elif scope == "head":
        p = base.find(b"\r\n\r\n")
        subject = base if p < 0 else base[:p]
    elif scope == "after_head":
        p = base.find(b"\r\n\r\n")
        subject = b"" if p < 0 else base[p + 4 :]
    elif scope == "body":
        subject = _need_resp(cap, "scope body").body
    else:
        raise CaseError(f"unknown scope {json_str(scope)}")
    ci = get_bool(m, "ci")
    where = "" if scope == "all" else f" (scope {scope})"

    if kind in ("len", "min_len", "max_len"):
        if not is_u64(v):
            raise CaseError(f"{kind}: expected an integer")
        n = len(subject)
        ok = n == v if kind == "len" else n >= v if kind == "min_len" else n <= v
        if not ok:
            raise CaseError(f"expected {kind} {v}{where}, got length {n}: {show(subject, 300)}")
        return
    if kind == "utf8":
        if not isinstance(v, bool):
            raise CaseError("utf8: expected a boolean")
        if is_valid_utf8(subject) != v:
            raise CaseError(f"expected {'valid' if v else 'invalid'} UTF-8{where}, got {show(subject, 600)}")
        return
    want = decode_bytes(v, variables)
    s, w = (subject.lower(), want.lower()) if ci else (subject, want)
    if kind == "equals":
        ok = s == w
    elif kind == "starts_with":
        ok = s.startswith(w)
    elif kind == "ends_with":
        ok = s.endswith(w)
    elif kind == "contains":
        ok = w in s
    else:
        ok = w not in s
    if not ok:
        raise CaseError(f"expected {kind} {show(want, 300)}{where}{' (case-insensitive)' if ci else ''}, "
                        f"got {show(subject, 800)}")


def check_field(kind: str, m: dict, cap: Capture, variables: dict) -> None:
    check_keys(m, [kind, "value", "values", "present", "count", "comment"])
    resp = _need_resp(cap, kind)
    name = m[kind]
    if not isinstance(name, str):
        raise CaseError(f"{kind}: expected a field name string")
    fields = resp.headers if kind == "header" else resp.trailers
    vals = field_values(fields, name.encode("latin-1", "replace"))
    checked = False
    if "present" in m:
        checked = True
        x = m["present"]
        if not isinstance(x, bool):
            raise CaseError("present: expected a boolean")
        if x != (len(vals) > 0):
            raise CaseError(f"expected {kind} {json_str(name)} to be {'present' if x else 'absent'}; "
                            f"fields: {fields_show(fields)}")
    if "count" in m:
        checked = True
        x = m["count"]
        if not is_u64(x):
            raise CaseError("count: expected an integer")
        if len(vals) != x:
            raise CaseError(f"expected {x} {kind} field(s) {json_str(name)}, found {len(vals)}")
    if "value" in m:
        checked = True
        want = decode_bytes(m["value"], variables)
        if not vals:
            raise CaseError(f"expected {kind} {json_str(name)} = {show(want, 200)}, field absent")
        if vals[0][1] != want:
            raise CaseError(f"expected {kind} {json_str(name)} = {show(want, 200)}, got {show(vals[0][1], 200)}")
    if "values" in m:
        checked = True
        x = m["values"]
        if not isinstance(x, list):
            raise CaseError("values: expected an array")
        wants = [decode_bytes(item, variables) for item in x]
        if wants != [v for _, v in vals]:
            raise CaseError(f"expected {kind} {json_str(name)} values "
                            f"{_str_list(latin1(w) for w in wants)}, got "
                            f"{_str_list(latin1(v) for _, v in vals)}")
    if not checked:
        raise CaseError(f"{kind} assertion needs one of value, values, present, count")


def check(a, cap: Capture, variables: dict) -> None:
    """One assertion of a step; raises CaseError with the failure."""
    if not isinstance(a, dict):
        raise CaseError(f"assertion must be an object: {json_text(a)}")
    if "regex" in a or "not_regex" in a:
        raise CaseError("regex assertions are not supported (SPEC.md section 10: use the byte kinds or utf8)")
    kinds = [k for k in a if k in BYTE_KINDS or k in OTHER_KINDS]
    if len(kinds) != 1:
        raise CaseError(f"assertion needs exactly one kind key, found {json_text(a)}")
    kind = kinds[0]
    if kind in ("header", "trailer"):
        check_field(kind, a, cap, variables)
    else:
        check_keys(a, ["scope", "ci", "raw", "comment", kind])
        check_simple(kind, a[kind], a, cap, variables)


# ---- event patterns ----

_ABSENT = object()


def json_equal(a, b) -> bool:
    """Equality with JSON types kept apart: true != 1, 1 != 1.0."""
    if type(a) is bool or type(b) is bool:
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return type(a) is type(b) and a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return len(a) == len(b) and all(k in b and json_equal(v, b[k]) for k, v in a.items())
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b, strict=True))
    return type(a) is type(b) and a == b


def _match_op(op: str, arg, act, variables: dict) -> bool:
    if op == "$absent":
        return act is _ABSENT
    if op == "$any":
        return act is not _ABSENT
    if op == "$not":
        return not matches(arg, act, variables)
    if op == "$bytes":
        want = latin1(decode_bytes(arg, variables))
        return isinstance(act, str) and act == want
    if op == "$contains":
        want = latin1(decode_bytes(arg, variables))
        return isinstance(act, str) and want in act
    if op == "$includes":
        if not isinstance(arg, list):
            raise CaseError("$includes: expected an array")
        if not isinstance(act, list):
            return False
        return all(any(matches(p, item, variables) for item in act) for p in arg)
    raise CaseError(f"unknown pattern operator {op}")


def matches(pat, act, variables: dict) -> bool:
    """An event (or any value; act is _ABSENT for a missing field) against a
    pattern; raises CaseError on a bad pattern."""
    if isinstance(pat, dict):
        if len(pat) == 1:
            (key, arg), = pat.items()
            if key.startswith("$"):
                return _match_op(key, arg, act, variables)
        if not isinstance(act, dict):
            return False
        return all(matches(v, act.get(k, _ABSENT), variables) for k, v in pat.items())
    if act is _ABSENT:
        return False
    if isinstance(pat, str) and isinstance(act, str):
        return substitute(pat, variables, True) == act
    if isinstance(pat, list) and isinstance(act, list):
        return len(pat) == len(act) and all(matches(p, a, variables) for p, a in zip(pat, act, strict=True))
    return json_equal(pat, act)
