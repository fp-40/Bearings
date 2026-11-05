"""One conformance case: validation (the allowed fields of a case and of
each step, SPEC.md sections 8 and 9) and execution: start the server (and
the proxy for via_proxy), run the steps in order and stop at the first
failure, then wait for expect_events (in order, within events_timeout_ms)
and check forbid_events (after events_settle_ms).

Test tooling only."""

import sys
from dataclasses import dataclass, field

from .assertions import Capture, check, matches, normalize
from .bytestr import (
    CaseError,
    check_keys,
    decode_bytes,
    get_bool,
    get_str,
    get_u64,
    is_u64,
    json_str,
    json_text,
    show,
)
from .conn import DEFAULT_TIMEOUT_MS, EOF, OPEN, RESET, TIMEOUT, Conn, now_us, sleep_ms
from .proxy import Proxy
from .response import read_response
from .server import ServerProc


CASE_KEYS = ("name", "source", "pending", "notes", "comment", "server", "via_proxy", "steps",
             "expect_events", "forbid_events", "events_timeout_ms", "events_settle_ms")
READ_COMMON = ("op", "conn", "comment", "mark", "expect", "timing", "timeout_ms", "allow_reset",
               "diff_capture")
STEP_FIELDS = {
    "connect": ["nodelay"],
    "write": ["data", "may_fail", "expect_fail", "timeout_ms"],
    "sleep": ["ms"],
    "shutdown_write": [],
    "close": [],
    "read_once": ["max", "allow_timeout"],
    "read_exact": ["len"],
    "read_until": ["until", "max"],
    "read_to_eof": ["max", "deadline_ms"],
    "read_response": ["method"],
    "expect_open": ["for_ms", "expect", "timing", "diff_capture"],
    "control": ["command", "name"],
    "await_event": ["match", "timeout_ms"],
}


# ---- validation ----

def validate_step(s) -> None:
    if not isinstance(s, dict):
        raise CaseError("step must be an object")
    op = s.get("op")
    if not isinstance(op, str):
        raise CaseError('step needs a string "op"')
    if op not in STEP_FIELDS:
        raise CaseError(f"unknown op {json_str(op)}")
    allowed = list(STEP_FIELDS[op])
    if op.startswith("read_"):
        allowed += READ_COMMON
    allowed += ["op", "conn", "comment", "mark"]
    check_keys(s, allowed)
    if op == "write":
        if "data" not in s:
            raise CaseError('write needs "data"')
    elif op == "sleep":
        if get_u64(s, "ms") is None:
            raise CaseError('sleep needs integer "ms"')
    elif op == "read_exact":
        if get_u64(s, "len") is None:
            raise CaseError('read_exact needs integer "len"')
    elif op == "read_until":
        u = s.get("until")
        if not isinstance(u, dict):
            raise CaseError('read_until needs an "until" object')
        check_keys(u, ["ends_with", "contains", "starts_with", "min_len"])
        if len(u) != 1:
            raise CaseError("until: exactly one of ends_with, contains, starts_with, min_len")
    elif op == "expect_open":
        if get_u64(s, "for_ms") is None:
            raise CaseError('expect_open needs integer "for_ms"')
    elif op == "control":
        cmd = get_str(s, "command", "\0")
        if cmd == "signal":
            if not isinstance(s.get("name"), str):
                raise CaseError('signal needs a "name"')
        elif cmd != "graceful_shutdown":
            raise CaseError('control: command must be "graceful_shutdown" or "signal"')
    elif op == "await_event":
        if "match" not in s:
            raise CaseError('await_event needs "match"')
    x = s.get("expect")
    if x is not None and not isinstance(x, list):
        raise CaseError("expect: expected an array of assertions")
    t = s.get("timing")
    if t is not None:
        if not isinstance(t, dict):
            raise CaseError("timing: expected an object")
        check_keys(t, ["since", "min_ms", "max_ms"])


def validate_case(c) -> None:
    """Raises CaseError with the reason the case is invalid."""
    if not isinstance(c, dict):
        raise CaseError("case must be an object")
    check_keys(c, CASE_KEYS)
    if not isinstance(c.get("name"), str):
        raise CaseError('case needs a string "name"')
    x = c.get("via_proxy")
    if x is not None and x != "h1":
        raise CaseError(f'via_proxy: only "h1" is supported, found {json_text(x)}')
    steps = c.get("steps")
    if not isinstance(steps, list):
        raise CaseError('case needs a "steps" array')
    for k, s in enumerate(steps):
        try:
            validate_step(s)
        except CaseError as e:
            raise CaseError(f"step {k}: {e}") from None
    for key in ("expect_events", "forbid_events"):
        x = c.get(key)
        if x is not None and not isinstance(x, list):
            raise CaseError(f"{key}: expected an array")


def pending_reason(c: dict):
    """The pending reason, or None when the case runs."""
    p = c.get("pending")
    if p is None or p is False:
        return None
    return p if isinstance(p, str) else json_text(p)


# ---- execution ----

@dataclass
class CaseOutcome:
    failures: list = field(default_factory=list)
    events: list = field(default_factory=list)     # JSON text of every server event
    stderr: bytes = b""
    elapsed_ms: int = 0


def _ms_of(s: dict, key: str, default: int) -> int:
    v = get_u64(s, key)
    return default if v is None else v


class Exec:
    def __init__(self, name: str, verbose: bool):
        self.name = name
        self.verbose = verbose
        self.server = None
        self.proxy = None
        self.target_port = 0
        self.conns = {}
        self.marks = {}
        self.variables = {}
        self.cursor = 0

    def conn(self, name: str) -> Conn:
        c = self.conns.get(name)
        if c is None:
            raise CaseError(f"connection {json_str(name)} is not connected (add a connect step)")
        return c

    def close_conns(self) -> None:
        for c in self.conns.values():
            c.close()
        self.conns = {}

    def check_timing(self, t: dict, cname: str, started: int, done_at: int) -> None:
        since = get_str(t, "since", "step")
        if since == "step":
            base = started
        elif since == "connect":
            base = self.marks.get("connect:" + cname)
            if base is None:
                raise CaseError("timing: connection has no connect time")
        else:
            base = self.marks.get(since)
            if base is None:
                raise CaseError(f"timing: unknown mark {json_str(since)}")
        elapsed = max((done_at - base) // 1000, 0)
        mn = get_u64(t, "min_ms")
        mx = get_u64(t, "max_ms")
        if mn is not None and elapsed < mn:
            raise CaseError(f"timing: completed {elapsed} ms after {since}, expected >= {mn} ms")
        if mx is not None and elapsed > mx:
            raise CaseError(f"timing: completed {elapsed} ms after {since}, expected <= {mx} ms")

    def exec_read(self, op: str, cname: str, s: dict, timeout_ms: int, allow_reset: bool):
        """The read steps: (Capture, done_at)."""
        c = self.conn(cname)
        if c.closed_locally:
            raise CaseError(f"connection {json_str(cname)} was closed by a close step")

        def reset_err(what):
            return f"connection reset by peer during {what} (set allow_reset to accept)"

        def timeout_err(what, have):
            return f"timed out after {timeout_ms} ms during {what} ({have} bytes received in this step)"

        if op == "read_once":
            maximum = _ms_of(s, "max", 4096)
            allow_timeout = get_bool(s, "allow_timeout")
            timed_out = False
            if not c.buf:
                r = c.read_some(timeout_ms)
                if r == RESET and not allow_reset:
                    raise CaseError(reset_err("read_once"))
                if r == TIMEOUT:
                    if not allow_timeout:
                        raise CaseError(timeout_err("read_once", 0))
                    timed_out = True
            cap = Capture(raw=c.take(maximum), end=c.end)
            cap.read_result = ("data" if cap.raw else "timeout" if timed_out
                               else "reset" if c.end == RESET else "eof")
            return cap, now_us()
        if op == "read_exact":
            n = get_u64(s, "len")
            while True:
                if len(c.buf) >= n:
                    return Capture(raw=c.take(n), end=c.end), now_us()
                r = c.read_some(timeout_ms)
                if r == EOF:
                    raise CaseError(f"EOF after {len(c.buf)} of {n} bytes: {show(c.buf, 300)}")
                if r == RESET:
                    raise CaseError(reset_err("read_exact"))
                if r == TIMEOUT:
                    raise CaseError(timeout_err("read_exact", len(c.buf)))
        if op == "read_until":
            maximum = _ms_of(s, "max", 8192)
            (kind, val), = s["until"].items()
            needle = b"" if kind == "min_len" else decode_bytes(val, self.variables)
            min_len = val if is_u64(val) else 0
            cap = b""
            while True:
                cap += c.take(maximum - len(cap))
                norm = normalize(cap)
                if kind == "ends_with":
                    ok = norm.endswith(needle)
                elif kind == "starts_with":
                    ok = norm.startswith(needle)
                elif kind == "contains":
                    ok = needle in norm
                else:
                    ok = len(cap) >= min_len
                if ok:
                    return Capture(raw=cap, end=c.end), now_us()
                if len(cap) >= maximum:
                    raise CaseError(f"read_until: {maximum} bytes received without a match (buffer filled): "
                                    f"{show(norm, 600)}")
                r = c.read_some(timeout_ms)
                if r == EOF:
                    raise CaseError(f"read_until: EOF before match; received {show(norm, 600)}")
                if r == RESET:
                    raise CaseError(f"{reset_err('read_until')}; received {show(norm, 600)}")
                if r == TIMEOUT:
                    raise CaseError(f"{timeout_err('read_until', len(cap))}; received {show(norm, 600)}")
        if op == "read_to_eof":
            maximum = _ms_of(s, "max", 64 << 20)
            has_deadline = "deadline_ms" in s
            deadline = now_us() + _ms_of(s, "deadline_ms", 0) * 1000
            cap = b""
            while True:
                cap += c.take(sys.maxsize)
                if len(cap) > maximum:
                    raise CaseError(f"read_to_eof: more than {maximum} bytes received")
                if c.end == EOF:
                    return Capture(raw=cap, end=EOF), now_us()
                if c.end == RESET:
                    if allow_reset:
                        return Capture(raw=cap, end=RESET), now_us()
                    raise CaseError(f"{reset_err('read_to_eof')}; received {show(normalize(cap), 600)}")
                wait = timeout_ms
                if has_deadline:
                    now = now_us()
                    if now >= deadline:
                        raise CaseError(f"read_to_eof: deadline passed without EOF; received "
                                        f"{show(normalize(cap), 600)}")
                    wait = min(wait, (deadline - now + 999) // 1000)
                if c.read_some(wait) == TIMEOUT and (not has_deadline or now_us() < deadline):
                    raise CaseError(f"{timeout_err('read_to_eof', len(cap))}; received "
                                    f"{show(normalize(cap), 600)}")
        if op == "read_response":
            is_head = get_str(s, "method").lower() == "head"
            resp, end, done_at = read_response(c, is_head, timeout_ms, allow_reset)
            return Capture(raw=resp.raw, end=end, resp=resp), done_at
        if op == "expect_open":
            for_ms = _ms_of(s, "for_ms", 0)
            until = now_us() + for_ms * 1000
            cap = b""
            while True:
                cap += c.take(sys.maxsize)
                if c.end != OPEN:
                    what = "reached EOF" if c.end == EOF else "was reset"
                    raise CaseError(f"expect_open: connection {what} before {for_ms} ms; received "
                                    f"{show(normalize(cap), 600)}")
                now = now_us()
                if now >= until:
                    return Capture(raw=cap, end=OPEN), now
                c.read_some((until - now + 999) // 1000)
        raise CaseError(f"unknown op {op}")

    def wait_event(self, deadline: int, found):
        """Polls the event log until found(events) is true or the deadline."""
        while True:
            with self.server.events.cond:
                r = found(self.server.events.events)
            if r or now_us() >= deadline:
                return r
            self.server.events.wait_change((deadline - now_us()) // 1000 + 1)

    def run_step(self, i: int, s: dict) -> None:
        op = get_str(s, "op")
        cname = get_str(s, "conn", "main")
        started = now_us()
        timeout_ms = _ms_of(s, "timeout_ms", DEFAULT_TIMEOUT_MS)
        allow_reset = get_bool(s, "allow_reset")
        err = ""
        try:
            if op == "connect":
                if cname in self.conns:
                    raise CaseError(f"connection {json_str(cname)} already exists")
                c = Conn(self.target_port, get_bool(s, "nodelay"))
                self.marks["connect:" + cname] = c.connected_at
                self.conns[cname] = c
            elif op == "write":
                data = decode_bytes(s["data"], self.variables)
                c = self.conn(cname)
                write_err = ""
                try:
                    c.write_all(data, timeout_ms)
                except CaseError as e:
                    write_err = str(e)
                if get_bool(s, "expect_fail"):
                    if not write_err:
                        raise CaseError("write succeeded but expect_fail is set")
                elif write_err and not get_bool(s, "may_fail"):
                    raise CaseError(write_err)
            elif op == "sleep":
                sleep_ms(_ms_of(s, "ms", 0))
            elif op == "shutdown_write":
                self.conn(cname).shutdown_write()
            elif op == "close":
                self.conn(cname).close()
            elif op == "control":
                cmd = get_str(s, "command")
                name = get_str(s, "name") if cmd == "signal" else ""
                line = "signal " + name if cmd == "signal" else cmd
                start = self.server.events.count()
                self.server.send_line(line)

                def acked(events):
                    return any(get_str(ev, "event") == "control_ack" and get_str(ev, "command") == cmd
                               and (cmd != "signal" or get_str(ev, "name") == name)
                               for ev in events[start:])
                if not self.wait_event(now_us() + 2_000_000, acked):
                    raise CaseError(f"no control_ack for {json_str(line)} within 2 s")
            elif op == "await_event":
                pat = s["match"]
                deadline = now_us() + _ms_of(s, "timeout_ms", DEFAULT_TIMEOUT_MS) * 1000

                def seen(events):
                    for k in range(self.cursor, len(events)):
                        if matches(pat, events[k], self.variables):
                            self.cursor = k + 1
                            return True
                    return False
                if not self.wait_event(deadline, seen):
                    raise CaseError(f"no event matching {json_text(pat)} within the timeout")
            else:
                cap, done_at = self.exec_read(op, cname, s, timeout_ms, allow_reset)
                cap.norm = normalize(cap.raw)
                t = s.get("timing")
                if isinstance(t, dict):
                    self.check_timing(t, cname, started, done_at)
                x = s.get("expect")
                if isinstance(x, list):
                    for k, a in enumerate(x):
                        try:
                            check(a, cap, self.variables)
                        except CaseError as e:
                            raise CaseError(f"expect[{k}]: {e}") from None
        except CaseError as e:
            err = str(e)
        finally:
            mark = s.get("mark")
            if isinstance(mark, str):
                self.marks[mark] = now_us()
        if self.verbose:
            print(f"  [{self.name}] step {i} {op}: {err or 'ok'}", file=sys.stderr)
        if err:
            raise CaseError(err)


def run_case(c: dict, server_cmd: str, verbose: bool) -> CaseOutcome:
    start = now_us()
    result = CaseOutcome()
    ex = Exec(get_str(c, "name"), verbose)
    ex.marks["case"] = start
    try:
        try:
            ex.server = ServerProc(server_cmd, c.get("server") or {})
        except CaseError as e:
            result.failures.append(f"server start failed: {e}")
            return result
        ex.target_port = ex.server.port
        if get_str(c, "via_proxy") == "h1":
            try:
                ex.proxy = Proxy(ex.server.port)
            except CaseError as e:
                result.failures.append(f"proxy start failed: {e}")
                result.stderr = ex.server.stderr_text()
                return result
            ex.target_port = ex.proxy.port
        ex.variables["port"] = str(ex.target_port)
        ex.variables["server_port"] = str(ex.server.port)
        if ex.proxy is not None:
            ex.variables["proxy_port"] = str(ex.proxy.port)

        steps = c["steps"]
        for k, s in enumerate(steps):
            try:
                ex.run_step(k, s)
            except CaseError as e:
                result.failures.append(f"step {k} ({get_str(s, 'op')}): {e}")
                break

        if not result.failures:
            wait_ms = _ms_of(c, "events_timeout_ms", 1000)
            pats = c.get("expect_events")
            if isinstance(pats, list):
                state = {"unmatched": 0, "error": ""}

                def all_matched(events):
                    cur = 0
                    try:
                        for pi, pat in enumerate(pats):
                            for k in range(cur, len(events)):
                                if matches(pat, events[k], ex.variables):
                                    cur = k + 1
                                    break
                            else:
                                state["unmatched"] = pi
                                return False
                    except CaseError as e:
                        state["error"] = str(e)
                        return True
                    return True
                ok = ex.wait_event(now_us() + wait_ms * 1000, all_matched)
                if state["error"]:
                    result.failures.append("expect_events: " + state["error"])
                elif not ok:
                    u = state["unmatched"]
                    result.failures.append(f"expect_events[{u}] {json_text(pats[u])} not matched "
                                           f"(in order) within {wait_ms} ms")
            pats = c.get("forbid_events")
            if isinstance(pats, list):
                sleep_ms(_ms_of(c, "events_settle_ms", 200))
                for ev in ex.server.events.snapshot():
                    for pi, p in enumerate(pats):
                        try:
                            if matches(p, ev, ex.variables):
                                result.failures.append(f"forbid_events[{pi}] {json_text(p)} matched event "
                                                       f"{json_text(ev)}")
                        except CaseError as e:
                            result.failures.append(f"forbid_events[{pi}]: {e}")

        st = ex.server.exited()
        if st:
            result.failures.append(f"server process exited during the case ({st})")
        ex.close_conns()
        ex.server.stop()
        result.events = [json_text(ev) for ev in ex.server.events.snapshot()]
        result.stderr = ex.server.stderr_text()
    finally:
        ex.close_conns()
        if ex.proxy is not None:
            ex.proxy.destroy()
        if ex.server is not None:
            ex.server.destroy()
        result.elapsed_ms = (now_us() - start) // 1000
    return result
