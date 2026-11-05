"""The runner's own checks: JSON strings as byte strings, latin-1, ${var},
the date normalization, the UTF-8 check and the assertion errors."""

import json

from .assertions import CANONICAL_DATE, Capture, check, json_equal, normalize
from .bytestr import CaseError, decode_bytes, is_valid_utf8, json_text, latin1

DATE = b"Wed, 04 Nov 2026 19:22:45 GMT"


def selftest() -> int:
    failures = []

    def expect(ok: bool, what: str):
        if not ok:
            failures.append(what)

    def check_fails(assertion: str, subject: bytes) -> bool:
        a = json.loads(assertion)
        cap = Capture(raw=subject, norm=subject)
        try:
            check(a, cap, {})
            return False
        except CaseError:
            return True

    # JSON: \u escapes and raw UTF-8, control characters kept, key order,
    # number types kept apart, \u0000 is a NUL character
    v = json.loads(
        '{"z":1,"a":"x\\u00ff\\u0001/y\\ud83d\\ude00é","n":-2,"f":1.0,"b":[true,null]}'
    )
    expect(list(v)[0] == "z", "json key order")
    expect(v["a"] == "xÿ\u0001/y\U0001f600é", "json string")
    expect(
        not json_equal(v["z"], v["f"]) and not json_equal(True, 1),
        "json 1 <> 1.0, true <> 1",
    )
    expect(json_text(v["a"]) == '"xÿ\\u0001/y\U0001f600é"', "json text")
    expect(
        json.loads('{"a":"x\\u0000"}')["a"] == "x\0", "NUL escape is a NUL character"
    )
    expect(json.loads('"a\\\\u0000"') == "a\\u0000", "escaped backslash before u0000")
    # byte strings
    variables = {"port": "8080"}
    v = json.loads(
        '["h:${port} $${port} $x", {"repeat": "ab", "count": 2}, {"hex": "00 ff"}, "é"]'
    )
    expect(
        decode_bytes(v, variables)
        == b"h:8080 ${port} $x" + b"abab" + b"\x00\xff" + b"\xe9",
        "decode bytes",
    )
    try:
        decode_bytes("Ā", variables)
        expect(False, "code point above U+00FF must fail")
    except CaseError:
        pass
    expect(latin1(b"\xe9\xffa") == "éÿa", "latin1")
    # date normalization
    s = (
        b"HTTP/1.1 200 OK\r\nDate: "
        + DATE
        + b"\r\ndate:\t"
        + DATE.lower()
        + b"\r\nx-date: "
        + DATE
        + b"\r\n"
    )
    expect(
        normalize(s)
        == b"HTTP/1.1 200 OK\r\nDate: "
        + CANONICAL_DATE
        + b"\r\ndate:\t"
        + CANONICAL_DATE
        + b"\r\nx-date: "
        + DATE
        + b"\r\n",
        "normalize date",
    )
    expect(
        normalize(b"\r\ndate: Wed, 4 Nov 2026 19:22:45 GMT")
        == b"\r\ndate: Wed, 4 Nov 2026 19:22:45 GMT",
        "normalize keeps a non-fixdate",
    )
    # utf8
    expect(is_valid_utf8(b"ok\xc3\xa9\nx\xf0\x9f\x98\x80"), "utf8: valid")
    expect(not is_valid_utf8(b"ok\xff"), "utf8: invalid byte")
    expect(not is_valid_utf8(b"\xed\xa0\x80"), "utf8: surrogate")
    expect(not is_valid_utf8(b"\xc0\x80"), "utf8: overlong")
    expect(not is_valid_utf8(b"\xe2\x82"), "utf8: truncated")
    expect(not is_valid_utf8(b"\xf4\x90\x80\x80"), "utf8: above U+10FFFF")
    expect(
        not check_fails('{"utf8": true}', b"a\xc3\xa9")
        and check_fails('{"utf8": true}', b"a\xe9"),
        "utf8 assertion",
    )
    expect(
        not check_fails('{"utf8": false}', b"\xe9")
        and check_fails('{"utf8": false}', b"a"),
        "utf8 false",
    )
    # assertions
    expect(
        check_fails('{"regex": "a"}', b"a") and check_fails('{"not_regex": "a"}', b"b"),
        "regex is refused",
    )
    expect(
        not check_fails('{"equals": "b\\r\\nfoo", "ci": true}', b"B\r\nfoo")
        and check_fails('{"equals": "b\\r\\nfoo"}', b"B\r\nfoo"),
        "equals, ci",
    )
    expect(
        not check_fails('{"equals": [{"repeat": "x", "count": 3}]}', b"xxx")
        and check_fails('{"equals": [{"repeat": "x", "count": 3}]}', b"xxy"),
        "equals repeat",
    )
    expect(
        check_fails('{"len": 0}', b"a") and not check_fails('{"len": 0}', b""), "len"
    )
    expect(
        check_fails('{"starts_with": "ab"}', b"a")
        and check_fails('{"ends_with": "b", "x": 1}', b"b"),
        "starts_with, unknown key",
    )
    for f in failures:
        print("selftest FAIL:", f)
    if failures:
        print(f"selftest: {len(failures)} failed")
        return 1
    print("selftest: passed")
    return 0
