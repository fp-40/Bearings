//! Execution of one case: spawn the server, run the steps, check events.

use crate::assert::{check, matches, normalize, show, Capture};
use crate::conn::{Conn, End, ReadOutcome, DEFAULT_TIMEOUT};
use crate::proxy::Proxy;
use crate::response::{read_response, Parsed};
use crate::server::{Event, ServerProc};
use harness_common::{check_keys, decode_bytes, latin1, Vars};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Stop at the first failure (run mode).
    Assert,
    /// Execute every step, recording failures in the transcript (diff mode).
    Transcript,
}

pub struct CaseResult {
    /// Variables of this run (port numbers), used to scrub transcripts in diff mode.
    pub vars: Vars,
    pub failures: Vec<String>,
    pub transcript: Vec<Value>,
    pub events: Vec<Value>,
    pub stderr: String,
    pub elapsed: Duration,
}

const CASE_KEYS: &[&str] = &[
    "name",
    "source",
    "pending",
    "notes",
    "comment",
    "server",
    "via_proxy",
    "steps",
    "expect_events",
    "forbid_events",
    "events_timeout_ms",
    "events_settle_ms",
];

pub fn validate_case(case: &Value) -> Result<(), String> {
    let m = case.as_object().ok_or("case must be an object")?;
    check_keys(m, CASE_KEYS)?;
    m.get("name").and_then(Value::as_str).ok_or("case needs a string \"name\"")?;
    if let Some(v) = m.get("via_proxy") {
        if v != "h1" && !v.is_null() {
            return Err(format!("via_proxy: only \"h1\" is supported, found {v}"));
        }
    }
    let steps = m
        .get("steps")
        .and_then(Value::as_array)
        .ok_or("case needs a \"steps\" array")?;
    for (i, s) in steps.iter().enumerate() {
        validate_step(s).map_err(|e| format!("step {i}: {e}"))?;
    }
    for k in ["expect_events", "forbid_events"] {
        if let Some(v) = m.get(k) {
            v.as_array().ok_or_else(|| format!("{k}: expected an array"))?;
        }
    }
    Ok(())
}

const READ_COMMON: &[&str] = &[
    "op", "conn", "comment", "mark", "expect", "timing", "timeout_ms", "allow_reset", "diff_capture",
];

fn validate_step(s: &Value) -> Result<(), String> {
    let m = s.as_object().ok_or("step must be an object")?;
    let op = m.get("op").and_then(Value::as_str).ok_or("step needs a string \"op\"")?;
    let base = ["op", "conn", "comment", "mark"];
    let mut allowed: Vec<&str> = match op {
        "connect" => vec!["nodelay"],
        "write" => vec!["data", "may_fail", "expect_fail", "timeout_ms"],
        "sleep" => vec!["ms"],
        "shutdown_write" | "close" => vec![],
        "read_once" => vec!["max", "allow_timeout"],
        "read_exact" => vec!["len"],
        "read_until" => vec!["until", "max"],
        "read_to_eof" => vec!["max", "deadline_ms"],
        "read_response" => vec!["method"],
        "expect_open" => vec!["for_ms", "expect", "timing", "diff_capture"],
        "control" => vec!["command", "name"],
        "await_event" => vec!["match", "timeout_ms"],
        other => return Err(format!("unknown op {other:?}")),
    };
    if op.starts_with("read_") {
        allowed.extend_from_slice(READ_COMMON);
    }
    allowed.extend_from_slice(&base);
    check_keys(m, &allowed)?;
    match op {
        "write" => {
            m.get("data").ok_or("write needs \"data\"")?;
        }
        "sleep" => {
            m.get("ms").and_then(Value::as_u64).ok_or("sleep needs integer \"ms\"")?;
        }
        "read_exact" => {
            m.get("len").and_then(Value::as_u64).ok_or("read_exact needs integer \"len\"")?;
        }
        "read_until" => {
            let u = m.get("until").and_then(Value::as_object).ok_or("read_until needs an \"until\" object")?;
            check_keys(u, &["ends_with", "contains", "starts_with", "min_len"])?;
            if u.len() != 1 {
                return Err("until: exactly one of ends_with, contains, starts_with, min_len".into());
            }
        }
        "expect_open" => {
            m.get("for_ms").and_then(Value::as_u64).ok_or("expect_open needs integer \"for_ms\"")?;
        }
        "control" => match m.get("command").and_then(Value::as_str) {
            Some("graceful_shutdown") => {}
            Some("signal") => {
                m.get("name").and_then(Value::as_str).ok_or("signal needs a \"name\"")?;
            }
            _ => return Err("control: command must be \"graceful_shutdown\" or \"signal\"".into()),
        },
        "await_event" => {
            m.get("match").ok_or("await_event needs \"match\"")?;
        }
        _ => {}
    }
    if let Some(e) = m.get("expect") {
        e.as_array().ok_or("expect: expected an array of assertions")?;
    }
    if let Some(t) = m.get("timing") {
        let t = t.as_object().ok_or("timing: expected an object")?;
        check_keys(t, &["since", "min_ms", "max_ms"])?;
    }
    Ok(())
}

struct Exec<'a> {
    server: ServerProc,
    _proxy: Option<Proxy>,
    target: SocketAddr,
    conns: HashMap<String, Conn>,
    marks: HashMap<String, Instant>,
    vars: Vars,
    cursor: usize,
    transcript: Vec<Value>,
    verbose: bool,
    case_name: &'a str,
}

fn ms(m: &Map<String, Value>, k: &str) -> Option<Duration> {
    m.get(k).and_then(Value::as_u64).map(Duration::from_millis)
}

fn flag(m: &Map<String, Value>, k: &str) -> bool {
    m.get(k).and_then(Value::as_bool).unwrap_or(false)
}

struct ReadResult {
    raw: Vec<u8>,
    end: End,
    done_at: Instant,
    resp: Option<Parsed>,
    /// read_once only: "data", "eof", "reset" or "timeout" (SPEC 9.2).
    read_result: Option<&'static str>,
}

impl<'a> Exec<'a> {
    fn conn(&mut self, name: &str) -> Result<&mut Conn, String> {
        self.conns
            .get_mut(name)
            .ok_or_else(|| format!("connection {name:?} is not connected (add a connect step)"))
    }

    fn run_step(&mut self, i: usize, s: &Map<String, Value>) -> Result<(), String> {
        let op = s["op"].as_str().unwrap();
        let cname = s.get("conn").and_then(Value::as_str).unwrap_or("main").to_string();
        let started = Instant::now();
        let mut entry = json!({"step": i, "op": op});
        if s.contains_key("conn") || op != "sleep" && op != "control" && op != "await_event" {
            entry["conn"] = json!(cname);
        }
        let result = self.exec_op(op, &cname, s, started, &mut entry);
        if let Err(e) = &result {
            entry["error"] = json!(e);
        }
        if let Some(mark) = s.get("mark").and_then(Value::as_str) {
            self.marks.insert(mark.to_string(), Instant::now());
        }
        if self.verbose {
            eprintln!("  [{}] step {i} {op}: {}", self.case_name, entry);
        }
        self.transcript.push(entry);
        result
    }

    fn exec_op(
        &mut self,
        op: &str,
        cname: &str,
        s: &Map<String, Value>,
        started: Instant,
        entry: &mut Value,
    ) -> Result<(), String> {
        let timeout = ms(s, "timeout_ms").unwrap_or(DEFAULT_TIMEOUT);
        let allow_reset = flag(s, "allow_reset");
        match op {
            "connect" => {
                if self.conns.contains_key(cname) {
                    return Err(format!("connection {cname:?} already exists"));
                }
                let c = Conn::connect(self.target, flag(s, "nodelay"))?;
                self.marks.insert(format!("connect:{cname}"), c.connected_at);
                self.conns.insert(cname.to_string(), c);
                Ok(())
            }
            "write" => {
                let data = decode_bytes(&s["data"], Some(&self.vars))?;
                entry["bytes"] = json!(data.len());
                let r = self.conn(cname)?.write_all(&data, timeout);
                entry["result"] = json!(if r.is_ok() { "ok" } else { "error" });
                match (r, flag(s, "expect_fail"), flag(s, "may_fail")) {
                    (Ok(()), true, _) => Err("write succeeded but expect_fail is set".into()),
                    (Err(_), true, _) => Ok(()),
                    (Err(_), false, true) => Ok(()),
                    (r, _, _) => r,
                }
            }
            "sleep" => {
                std::thread::sleep(ms(s, "ms").unwrap());
                Ok(())
            }
            "shutdown_write" => self.conn(cname)?.shutdown_write(),
            "close" => {
                self.conn(cname)?.close();
                Ok(())
            }
            "control" => {
                let cmd = s["command"].as_str().unwrap();
                let (line, name) = match cmd {
                    "signal" => {
                        let n = s["name"].as_str().unwrap();
                        (format!("signal {n}"), Some(n.to_string()))
                    }
                    _ => (cmd.to_string(), None),
                };
                let from = self.server.events.events.lock().unwrap().len();
                self.server.send_line(&line)?;
                let deadline = Instant::now() + Duration::from_secs(2);
                let found = self.server.events.wait_for(deadline, |evs| {
                    evs[from.min(evs.len())..].iter().find_map(|e| {
                        let v = &e.v;
                        let ok = v["event"] == "control_ack"
                            && v["command"] == cmd
                            && name.as_deref().map_or(true, |n| v["name"] == n);
                        ok.then_some(())
                    })
                });
                found.ok_or_else(|| format!("no control_ack for {line:?} within 2 s"))
            }
            "await_event" => {
                let pat = s["match"].clone();
                let deadline = Instant::now() + ms(s, "timeout_ms").unwrap_or(DEFAULT_TIMEOUT);
                let vars = self.vars.clone();
                let cursor = self.cursor;
                let mut err = None;
                let found = self.server.events.wait_for(deadline, |evs| {
                    for (idx, e) in evs.iter().enumerate().skip(cursor) {
                        match matches(&pat, Some(&e.v), &vars) {
                            Ok(true) => return Some(idx),
                            Ok(false) => {}
                            Err(x) => {
                                err = Some(x);
                                return Some(usize::MAX);
                            }
                        }
                    }
                    None
                });
                if let Some(e) = err {
                    return Err(e);
                }
                match found {
                    Some(idx) => {
                        self.cursor = idx + 1;
                        entry["event"] = self.server.events.events.lock().unwrap()[idx].v.clone();
                        Ok(())
                    }
                    None => Err(format!("no event matching {pat} within the timeout")),
                }
            }
            _ => {
                let rr = self.exec_read(op, cname, s, timeout, allow_reset)?;
                let norm = normalize(&rr.raw);
                entry["received"] = json!(latin1(&norm));
                entry["end"] = json!(rr.end.as_str());
                if let Some(r) = rr.read_result {
                    entry["read_result"] = json!(r);
                }
                if let Some(p) = &rr.resp {
                    entry["status"] = json!(p.status);
                    entry["body"] = json!(latin1(&p.body));
                    entry["framing"] = json!(p.framing);
                }
                if s.get("diff_capture").and_then(Value::as_bool) == Some(false) {
                    entry["diff_capture"] = json!(false);
                }
                let cap = Capture {
                    raw: &rr.raw,
                    norm: &norm,
                    end: rr.end,
                    resp: rr.resp.as_ref(),
                    read_result: rr.read_result,
                };
                if let Some(t) = s.get("timing").and_then(Value::as_object) {
                    self.check_timing(t, cname, started, rr.done_at)?;
                }
                if let Some(list) = s.get("expect").and_then(Value::as_array) {
                    for (k, a) in list.iter().enumerate() {
                        check(a, &cap, &self.vars).map_err(|e| format!("expect[{k}]: {e}"))?;
                    }
                }
                Ok(())
            }
        }
    }

    fn check_timing(
        &self,
        t: &Map<String, Value>,
        cname: &str,
        started: Instant,
        done_at: Instant,
    ) -> Result<(), String> {
        let since = t.get("since").and_then(Value::as_str).unwrap_or("step");
        let base = match since {
            "step" => started,
            "connect" => *self
                .marks
                .get(&format!("connect:{cname}"))
                .ok_or("timing: connection has no connect time")?,
            mark => *self
                .marks
                .get(mark)
                .ok_or_else(|| format!("timing: unknown mark {mark:?}"))?,
        };
        let elapsed = done_at.saturating_duration_since(base).as_millis() as u64;
        if let Some(min) = t.get("min_ms").and_then(Value::as_u64) {
            if elapsed < min {
                return Err(format!("timing: completed {elapsed} ms after {since}, expected >= {min} ms"));
            }
        }
        if let Some(max) = t.get("max_ms").and_then(Value::as_u64) {
            if elapsed > max {
                return Err(format!("timing: completed {elapsed} ms after {since}, expected <= {max} ms"));
            }
        }
        Ok(())
    }

    fn exec_read(
        &mut self,
        op: &str,
        cname: &str,
        s: &Map<String, Value>,
        timeout: Duration,
        allow_reset: bool,
    ) -> Result<ReadResult, String> {
        let vars = self.vars.clone();
        let c = self.conn(cname)?;
        if c.is_closed_locally() {
            return Err(format!("connection {cname:?} was closed by a close step"));
        }
        let reset_err = |what: &str| format!("connection reset by peer during {what} (set allow_reset to accept)");
        let timeout_err = |what: &str, have: usize| {
            format!("timed out after {} ms during {what} ({have} bytes received in this step)", timeout.as_millis())
        };
        match op {
            "read_once" => {
                let max = s.get("max").and_then(Value::as_u64).unwrap_or(4096) as usize;
                let allow_timeout = flag(s, "allow_timeout");
                let mut timed_out = false;
                if c.buf.is_empty() {
                    match c.read_some(timeout)? {
                        ReadOutcome::Data | ReadOutcome::Eof => {}
                        ReadOutcome::Reset if allow_reset => {}
                        ReadOutcome::Reset => return Err(reset_err("read_once")),
                        ReadOutcome::Timeout if allow_timeout => timed_out = true,
                        ReadOutcome::Timeout => return Err(timeout_err("read_once", 0)),
                    }
                }
                let raw = c.take(max);
                let read_result = if !raw.is_empty() {
                    "data"
                } else if timed_out {
                    "timeout"
                } else if c.end == End::Reset {
                    "reset"
                } else {
                    "eof"
                };
                Ok(ReadResult { raw, end: c.end, done_at: Instant::now(), resp: None, read_result: Some(read_result) })
            }
            "read_exact" => {
                let len = s["len"].as_u64().unwrap() as usize;
                loop {
                    if c.buf.len() >= len {
                        let raw = c.take(len);
                        return Ok(ReadResult { raw, end: c.end, done_at: Instant::now(), resp: None, read_result: None });
                    }
                    match c.read_some(timeout)? {
                        ReadOutcome::Data => {}
                        ReadOutcome::Eof => {
                            return Err(format!(
                                "EOF after {} of {len} bytes: {}",
                                c.buf.len(),
                                show(&c.buf, 300)
                            ))
                        }
                        ReadOutcome::Reset => return Err(reset_err("read_exact")),
                        ReadOutcome::Timeout => return Err(timeout_err("read_exact", c.buf.len())),
                    }
                }
            }
            "read_until" => {
                let max = s.get("max").and_then(Value::as_u64).unwrap_or(8192) as usize;
                let u = s["until"].as_object().unwrap();
                let (kind, val) = u.iter().next().unwrap();
                let needle = if kind == "min_len" { Vec::new() } else { decode_bytes(val, Some(&vars))? };
                let min_len = val.as_u64().unwrap_or(0) as usize;
                let pred = |cap: &[u8]| -> bool {
                    let n = normalize(cap);
                    match kind.as_str() {
                        "ends_with" => n.ends_with(&needle),
                        "starts_with" => n.len() >= needle.len() && n.starts_with(&needle),
                        "contains" => n.windows(needle.len().max(1)).any(|w| w == needle.as_slice()),
                        _ => cap.len() >= min_len,
                    }
                };
                let mut cap = Vec::new();
                loop {
                    let room = max - cap.len();
                    cap.extend(c.take(room));
                    if pred(&cap) {
                        return Ok(ReadResult { raw: cap, end: c.end, done_at: Instant::now(), resp: None, read_result: None });
                    }
                    if cap.len() >= max {
                        return Err(format!(
                            "read_until: {max} bytes received without a match (buffer filled): {}",
                            show(&normalize(&cap), 600)
                        ));
                    }
                    match c.read_some(timeout)? {
                        ReadOutcome::Data => {}
                        ReadOutcome::Eof => {
                            return Err(format!("read_until: EOF before match; received {}", show(&normalize(&cap), 600)))
                        }
                        ReadOutcome::Reset => {
                            return Err(format!("{}; received {}", reset_err("read_until"), show(&normalize(&cap), 600)))
                        }
                        ReadOutcome::Timeout => {
                            return Err(format!(
                                "{}; received {}",
                                timeout_err("read_until", cap.len()),
                                show(&normalize(&cap), 600)
                            ))
                        }
                    }
                }
            }
            "read_to_eof" => {
                let max = s.get("max").and_then(Value::as_u64).unwrap_or(64 << 20) as usize;
                let deadline = ms(s, "deadline_ms").map(|d| Instant::now() + d);
                let mut cap = Vec::new();
                loop {
                    cap.extend(c.take(usize::MAX));
                    if cap.len() > max {
                        return Err(format!("read_to_eof: more than {max} bytes received"));
                    }
                    match c.end {
                        End::Eof => return Ok(ReadResult { raw: cap, end: End::Eof, done_at: Instant::now(), resp: None, read_result: None }),
                        End::Reset if allow_reset => {
                            return Ok(ReadResult { raw: cap, end: End::Reset, done_at: Instant::now(), resp: None, read_result: None })
                        }
                        End::Reset => {
                            return Err(format!("{}; received {}", reset_err("read_to_eof"), show(&normalize(&cap), 600)))
                        }
                        End::Open => {}
                    }
                    let mut wait = timeout;
                    if let Some(d) = deadline {
                        let now = Instant::now();
                        if now >= d {
                            return Err(format!(
                                "read_to_eof: deadline passed without EOF; received {}",
                                show(&normalize(&cap), 600)
                            ));
                        }
                        wait = wait.min(d - now);
                    }
                    if let ReadOutcome::Timeout = c.read_some(wait)? {
                        if deadline.map_or(true, |d| Instant::now() < d) {
                            return Err(format!(
                                "{}; received {}",
                                timeout_err("read_to_eof", cap.len()),
                                show(&normalize(&cap), 600)
                            ));
                        }
                    }
                }
            }
            "read_response" => {
                let is_head = s
                    .get("method")
                    .and_then(Value::as_str)
                    .map_or(false, |m| m.eq_ignore_ascii_case("HEAD"));
                let (p, end, done_at) = read_response(c, is_head, timeout, allow_reset)?;
                Ok(ReadResult { raw: p.raw.clone(), end, done_at, resp: Some(p), read_result: None })
            }
            "expect_open" => {
                let until = Instant::now() + ms(s, "for_ms").unwrap();
                let mut cap = Vec::new();
                loop {
                    cap.extend(c.take(usize::MAX));
                    if c.end != End::Open {
                        return Err(format!(
                            "expect_open: connection {} before {} ms; received {}",
                            if c.end == End::Eof { "reached EOF" } else { "was reset" },
                            s["for_ms"],
                            show(&normalize(&cap), 600)
                        ));
                    }
                    let now = Instant::now();
                    if now >= until {
                        return Ok(ReadResult { raw: cap, end: End::Open, done_at: now, resp: None, read_result: None });
                    }
                    c.read_some(until - now)?;
                }
            }
            other => Err(format!("unknown op {other}")),
        }
    }
}

fn events_values(evs: &[Event]) -> Vec<Value> {
    evs.iter().map(|e| e.v.clone()).collect()
}

/// Run one case against `server_cmd`.
pub fn run_case(case: &Value, server_cmd: &str, mode: Mode, verbose: bool) -> CaseResult {
    let start = Instant::now();
    let m = case.as_object().unwrap();
    let name = m["name"].as_str().unwrap();
    let mut failures = Vec::new();
    let empty_spec = json!({});
    let spec = m.get("server").unwrap_or(&empty_spec);

    let server = match ServerProc::spawn(server_cmd, spec) {
        Ok(s) => s,
        Err(e) => {
            return CaseResult {
                vars: Vars::new(),
                failures: vec![format!("server start failed: {e}")],
                transcript: vec![],
                events: vec![],
                stderr: String::new(),
                elapsed: start.elapsed(),
            }
        }
    };
    let server_addr: SocketAddr = ([127, 0, 0, 1], server.port).into();
    let proxy = if m.get("via_proxy").and_then(Value::as_str) == Some("h1") {
        match Proxy::start(server_addr) {
            Ok(p) => Some(p),
            Err(e) => {
                return CaseResult {
                    vars: Vars::new(),
                    failures: vec![format!("proxy start failed: {e}")],
                    transcript: vec![],
                    events: vec![],
                    stderr: server.stderr_text(),
                    elapsed: start.elapsed(),
                }
            }
        }
    } else {
        None
    };
    let target: SocketAddr = match &proxy {
        Some(p) => ([127, 0, 0, 1], p.port).into(),
        None => server_addr,
    };
    let mut vars = Vars::new();
    vars.insert("port".into(), target.port().to_string());
    vars.insert("server_port".into(), server.port.to_string());
    if let Some(p) = &proxy {
        vars.insert("proxy_port".into(), p.port.to_string());
    }

    let mut ex = Exec {
        server,
        _proxy: proxy,
        target,
        conns: HashMap::new(),
        marks: HashMap::new(),
        vars,
        cursor: 0,
        transcript: Vec::new(),
        verbose,
        case_name: name,
    };
    ex.marks.insert("case".into(), start);

    let steps = m["steps"].as_array().unwrap();
    for (i, s) in steps.iter().enumerate() {
        let sm = s.as_object().unwrap();
        if let Err(e) = ex.run_step(i, sm) {
            let op = sm["op"].as_str().unwrap();
            failures.push(format!("step {i} ({op}): {e}"));
            if mode == Mode::Assert {
                break;
            }
        }
    }

    if failures.is_empty() || mode == Mode::Transcript {
        let wait = Duration::from_millis(m.get("events_timeout_ms").and_then(Value::as_u64).unwrap_or(1000));
        if let Some(pats) = m.get("expect_events").and_then(Value::as_array) {
            let deadline = Instant::now() + wait;
            let vars = ex.vars.clone();
            let mut last_unmatched = 0usize;
            let mut perr = None;
            let ok = ex.server.events.wait_for(deadline, |evs| {
                let mut cursor = 0;
                for (pi, p) in pats.iter().enumerate() {
                    let mut hit = None;
                    for (idx, e) in evs.iter().enumerate().skip(cursor) {
                        match matches(p, Some(&e.v), &vars) {
                            Ok(true) => {
                                hit = Some(idx);
                                break;
                            }
                            Ok(false) => {}
                            Err(x) => {
                                perr = Some(x);
                                return Some(());
                            }
                        }
                    }
                    match hit {
                        Some(idx) => cursor = idx + 1,
                        None => {
                            last_unmatched = pi;
                            return None;
                        }
                    }
                }
                Some(())
            });
            if let Some(e) = perr {
                failures.push(format!("expect_events: {e}"));
            } else if ok.is_none() {
                failures.push(format!(
                    "expect_events[{last_unmatched}] {} not matched (in order) within {} ms",
                    pats[last_unmatched],
                    wait.as_millis()
                ));
            }
        }
        if let Some(pats) = m.get("forbid_events").and_then(Value::as_array) {
            let settle = m.get("events_settle_ms").and_then(Value::as_u64).unwrap_or(200);
            std::thread::sleep(Duration::from_millis(settle));
            for e in ex.server.events.snapshot() {
                for (pi, p) in pats.iter().enumerate() {
                    match matches(p, Some(&e.v), &ex.vars) {
                        Ok(true) => failures.push(format!("forbid_events[{pi}] {p} matched event {}", e.v)),
                        Ok(false) => {}
                        Err(x) => failures.push(format!("forbid_events[{pi}]: {x}")),
                    }
                }
            }
        }
    }

    if let Some(st) = ex.server.exited() {
        failures.push(format!("server process exited during the case ({st})"));
    }
    drop(std::mem::take(&mut ex.conns));
    ex.server.stop();
    let events = events_values(&ex.server.events.snapshot());
    CaseResult {
        vars: ex.vars.clone(),
        failures,
        transcript: std::mem::take(&mut ex.transcript),
        events,
        stderr: ex.server.stderr_text(),
        elapsed: start.elapsed(),
    }
}
