//! Differential stream fuzz (docs/design.md section 9). Test
//! tooling only, never shipped.
//!
//! Generated request streams (src/gen.rs) are written, with random write
//! splits, 0-5 ms gaps and (in 30 % of the streams) a half-close after the
//! last byte, to two conformance servers started with the same spec (SPEC.md
//! 3): `--a` (default: target/release/reference-server, hyper 1.12) and
//! `--b` (beconf). Each job owns one pair of server processes and runs its
//! streams one at a time on a fresh connection, so connection k of both
//! servers is the job's k-th stream; both servers get the stream at the same
//! time (two client threads).
//!
//! Compared per stream (T1: outcomes, not bytes): the responses the client
//! received (status, header fields without `date` and without their order,
//! body), bytes after the last complete response, how the connection ended
//! for the client (EOF, reset, or still open after `--quiet-ms` without
//! data), and the server's events of that connection (SPEC 7) without
//! `message`/`detail` texts and `bytes_read`: what each request was parsed
//! as, its body and trailers or body error kind, the handler's result, the
//! connection outcome. Write segmentation and timing are not compared.
//!
//! A stream that differs is run 9 more times on both servers. When every run
//! of bearings (`--b`) gives what some run of hyper (`--a`) gave (or what a
//! documented deviation, `known_deviation`, explains), the outcome depends
//! on timing (how the kernel segmented the writes, a FIN racing the
//! response): counted as `timing`, the first 200 written as
//! `--out`/timing-<n>.json. Otherwise it is a `difference`: written as a
//! case file (`--out`/fail-<n>.json: the server spec and the write plan as
//! steps, both servers' outcomes in `notes`; `runner diff --a ... --b ...
//! <file>` replays it). A server process that exits is a crash
//! (`crash-<n>.json`, the server is started again).
//!
//! Usage: fuzz-diff --b CMD [--a CMD] [--streams N] [--seed S] [--jobs J]
//!                  [--quiet-ms MS] [--out DIR] [--inputs FILE]... [--corpus FILE]...
//!   --inputs: case inputs from tests/unit/test_split_fuzz_cases.py (name, spec, input);
//!   --corpus: (u32 length, bytes) records, e.g. tests/unit/test_parser_corpus.py output.
//! Exit status 0 when no stable difference and no server crash was found.

mod gen;

use harness_common::latin1;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Server specs, one per job (job j uses PROFILES[j % len]).
fn profiles() -> Vec<Value> {
    vec![
        json!({}),
        json!({"handler": "hello_world"}),
        json!({"config": {"half_close": true}}),
        json!({"config": {"timer": true, "pipeline_flush": true, "conn_mode": "with_upgrades"}}),
        json!({"config": {"max_headers": 10, "max_header_size": 2048, "max_buf_size": 8192}}),
        json!({"config": {"keep_alive": false}}),
        json!({"config": {"ignore_invalid_headers": true, "allow_multiple_spaces_in_request_line_delimiters": true}}),
        json!({"config": {"title_case_headers": true, "auto_date_header": false}}),
    ]
}

// ---------------------------------------------------------------- servers

#[derive(Default)]
struct Events {
    by_conn: Mutex<HashMap<u64, Vec<Value>>>,
    cond: Condvar,
}

struct Server {
    child: Child,
    port: u16,
    events: Arc<Events>,
    stderr: Arc<Mutex<Vec<u8>>>,
    cmd: String,
    spec: Value,
    _cfg: std::path::PathBuf,
}

static FILE_NO: AtomicU64 = AtomicU64::new(0);

impl Server {
    fn spawn(cmd: &str, spec: &Value) -> Result<Server, String> {
        let n = FILE_NO.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("bearings-fuzz-diff-{}-{}.json", std::process::id(), n));
        std::fs::write(&path, serde_json::to_vec(spec).unwrap()).map_err(|e| e.to_string())?;
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(format!("exec {cmd} \"$@\""))
            .arg("sh")
            .arg("--config")
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("cannot spawn {cmd}: {e}"))?;
        let stderr = Arc::new(Mutex::new(Vec::new()));
        {
            let mut err = child.stderr.take().unwrap();
            let sink = stderr.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 4096];
                while let Ok(n) = err.read(&mut buf) {
                    if n == 0 {
                        break;
                    }
                    let mut s = sink.lock().unwrap();
                    s.extend_from_slice(&buf[..n]);
                    // keep the tail only
                    if s.len() > 1 << 20 {
                        let cut = s.len() - (1 << 19);
                        s.drain(..cut);
                    }
                }
            });
        }
        let events = Arc::new(Events::default());
        let (tx, rx) = std::sync::mpsc::channel();
        {
            let out = child.stdout.take().unwrap();
            let ev = events.clone();
            std::thread::spawn(move || {
                let mut rd = BufReader::new(out);
                let mut first = String::new();
                if rd.read_line(&mut first).unwrap_or(0) == 0 {
                    let _ = tx.send(None);
                    return;
                }
                let _ = tx.send(first.trim_end().strip_prefix("LISTENING ").and_then(|p| p.parse::<u16>().ok()));
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match rd.read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    let text = String::from_utf8_lossy(&line);
                    let v: Value = match serde_json::from_str(text.trim_end()) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };
                    if let Some(c) = v.get("conn").and_then(Value::as_u64) {
                        ev.by_conn.lock().unwrap().entry(c).or_default().push(v);
                        ev.cond.notify_all();
                    }
                }
            });
        }
        let port = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Some(p)) => p,
            _ => {
                let _ = child.kill();
                return Err(format!("{cmd}: no LISTENING line"));
            }
        };
        // keep stdin open (end of stdin = exit, SPEC 3.4)
        Ok(Server { child, port, events, stderr, cmd: cmd.to_string(), spec: spec.clone(), _cfg: path })
    }

    fn exited(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(st)) => Some(st.to_string()),
            _ => None,
        }
    }

    /// The events of `conn` once its conn_close arrived (or after `wait`).
    fn take_conn(&self, conn: u64, wait: Duration) -> (Vec<Value>, bool) {
        let deadline = Instant::now() + wait;
        let mut g = self.events.by_conn.lock().unwrap();
        loop {
            let closed = g
                .get(&conn)
                .map(|v| v.iter().any(|e| e["event"] == "conn_close"))
                .unwrap_or(false);
            if closed {
                // events that follow conn_close (upgrade task) may come later; give them a moment
                drop(g);
                std::thread::sleep(Duration::from_millis(2));
                g = self.events.by_conn.lock().unwrap();
                return (g.remove(&conn).unwrap_or_default(), true);
            }
            let now = Instant::now();
            if now >= deadline {
                return (g.remove(&conn).unwrap_or_default(), false);
            }
            g = self.events.cond.wait_timeout(g, deadline - now).unwrap().0;
        }
    }

    fn stderr_tail(&self) -> String {
        let s = self.stderr.lock().unwrap();
        let start = s.len().saturating_sub(2000);
        String::from_utf8_lossy(&s[start..]).into_owned()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self._cfg);
    }
}

// ---------------------------------------------------------------- client

struct ClientRun {
    raw: Vec<u8>,
    end: &'static str, // eof | reset | open | connect-failed
}

fn run_client(port: u16, plan: &gen::Plan, quiet: Duration) -> ClientRun {
    let mut s = match TcpStream::connect(("127.0.0.1", port)) {
        Ok(s) => s,
        Err(_) => return ClientRun { raw: Vec::new(), end: "connect-failed" },
    };
    let _ = s.set_nodelay(true);
    let mut raw = Vec::new();
    let mut end: Option<&'static str> = None;
    let mut buf = vec![0u8; 65536];
    // write the pieces; read what is already there between them (a server
    // that answers early must not block on a full socket buffer)
    let _ = s.set_nonblocking(true);
    for (piece, gap) in &plan.pieces {
        if *gap > 0 {
            std::thread::sleep(Duration::from_millis(*gap));
        }
        let mut off = 0;
        let t0 = Instant::now();
        while off < piece.len() {
            match s.write(&piece[off..]) {
                Ok(n) => off += n,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    drain(&mut s, &mut buf, &mut raw, &mut end);
                    if t0.elapsed() > Duration::from_secs(3) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(_) => break, // the server closed: keep reading what it sent
            }
        }
        drain(&mut s, &mut buf, &mut raw, &mut end);
        if end.is_some() {
            break;
        }
    }
    let _ = s.set_nonblocking(false);
    if plan.half_close && end.is_none() {
        let _ = s.shutdown(Shutdown::Write);
    }
    // read until EOF / reset, or until `quiet` passes without data (3 s with a half-close)
    let idle = if plan.half_close { Duration::from_secs(3) } else { quiet };
    let _ = s.set_read_timeout(Some(idle));
    while end.is_none() {
        match s.read(&mut buf) {
            Ok(0) => end = Some("eof"),
            Ok(n) => raw.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                end = Some("open")
            }
            Err(_) => end = Some("reset"),
        }
    }
    ClientRun { raw, end: end.unwrap() }
}

fn drain(s: &mut TcpStream, buf: &mut [u8], raw: &mut Vec<u8>, end: &mut Option<&'static str>) {
    loop {
        match s.read(buf) {
            Ok(0) => {
                *end = Some("eof");
                return;
            }
            Ok(n) => raw.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return,
            Err(_) => {
                *end = Some("reset");
                return;
            }
        }
    }
}

// ---------------------------------------------------------------- outcome

#[derive(PartialEq, Clone, Debug)]
struct Response {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

#[derive(PartialEq, Clone, Debug)]
struct Outcome {
    responses: Vec<Response>,
    rest: Vec<u8>,
    end: String,
    events: Vec<Value>,
    closed: bool, // conn_close seen
}

fn find(h: &[u8], pat: &[u8]) -> Option<usize> {
    h.windows(pat.len()).position(|w| w == pat)
}

/// Splits the client's bytes into responses (RFC 9112 framing; `methods`:
/// the request methods in order, for HEAD).
fn parse_responses(raw: &[u8], methods: &[String]) -> (Vec<Response>, Vec<u8>) {
    let mut out = Vec::new();
    let mut p = 0;
    let mut req = 0;
    while p < raw.len() {
        let Some(he) = find(&raw[p..], b"\r\n\r\n") else { break };
        let head = &raw[p..p + he];
        let mut lines = head.split(|&b| b == b'\n');
        let status_line = lines.next().unwrap_or(b"");
        let status: u16 = std::str::from_utf8(status_line.get(9..12).unwrap_or(b"0"))
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let mut headers = Vec::new();
        let mut cl: Option<usize> = None;
        let mut chunked = false;
        for l in lines {
            let l = l.strip_suffix(b"\r").unwrap_or(l);
            let Some(c) = l.iter().position(|&b| b == b':') else { continue };
            let name = latin1(&l[..c]).to_ascii_lowercase();
            let value = latin1(&l[c + 1..]).trim().to_string();
            if name == "content-length" {
                cl = value.parse().ok();
            }
            if name == "transfer-encoding" && value.to_ascii_lowercase().ends_with("chunked") {
                chunked = true;
            }
            if name != "date" {
                headers.push((name, value));
            }
        }
        headers.sort();
        let mut q = p + he + 4;
        let informational = (100..200).contains(&status);
        let method = methods.get(req).map(String::as_str).unwrap_or("GET");
        let mut body = Vec::new();
        if informational || status == 204 || status == 304 || method == "HEAD" {
            // no body
        } else if chunked {
            loop {
                let Some(le) = find(&raw[q..], b"\r\n") else { return (out, raw[p..].to_vec()) };
                let size_txt = latin1(&raw[q..q + le]);
                let size = usize::from_str_radix(size_txt.split(';').next().unwrap_or("").trim(), 16).unwrap_or(0);
                q += le + 2;
                if size == 0 {
                    // trailers until an empty line
                    loop {
                        let Some(te) = find(&raw[q..], b"\r\n") else { return (out, raw[p..].to_vec()) };
                        q += te + 2;
                        if te == 0 {
                            break;
                        }
                    }
                    break;
                }
                if q + size + 2 > raw.len() {
                    return (out, raw[p..].to_vec());
                }
                body.extend_from_slice(&raw[q..q + size]);
                q += size + 2;
            }
        } else if let Some(n) = cl {
            if q + n > raw.len() {
                return (out, raw[p..].to_vec());
            }
            body.extend_from_slice(&raw[q..q + n]);
            q += n;
        } else {
            body.extend_from_slice(&raw[q..]);
            q = raw.len();
        }
        if !informational {
            req += 1;
        }
        out.push(Response { status, headers, body });
        p = q;
    }
    (out, raw[p..].to_vec())
}

/// `reference`: the events come from reference-server, which writes the
/// request target as `uri().to_string()` (the target's bytes as a UTF-8
/// string) where SPEC 2 asks for one character per byte (latin-1); both are
/// turned back into the bytes, so the comparison is about what was parsed.
fn normalize_events(ev: Vec<Value>, reference: bool) -> Vec<Value> {
    ev.into_iter()
        .filter(|e| e["event"] != "bytes_read" && e["event"] != "conn_open")
        .map(|mut e| {
            if let Some(m) = e.as_object_mut() {
                m.remove("conn");
                m.remove("message");
                m.remove("detail");
                // header fields by name (stable: the values of one name keep
                // their order). hyper's HeaderMap::remove (content-length
                // dropped next to transfer-encoding) moves the last field
                // into the removed slot; field order across names is not an
                // outcome (T1)
                for key in ["headers", "trailers"] {
                    if let Some(Value::Array(h)) = m.get_mut(key) {
                        h.sort_by(|x, y| x[0].as_str().unwrap_or("").cmp(y[0].as_str().unwrap_or("")));
                    }
                }
                if let Some(Value::String(t)) = m.get("target") {
                    let bytes: Vec<u8> = if reference {
                        t.as_bytes().to_vec()
                    } else {
                        harness_common::from_latin1(t).unwrap_or_else(|_| t.as_bytes().to_vec())
                    };
                    m.insert("target".into(), Value::String(latin1(&bytes)));
                }
            }
            e
        })
        .collect()
}

fn outcome(run: ClientRun, events: Vec<Value>, closed: bool, reference: bool) -> Outcome {
    let methods: Vec<String> = events
        .iter()
        .filter(|e| e["event"] == "request")
        .map(|e| e["method"].as_str().unwrap_or("").to_string())
        .collect();
    let (responses, rest) = parse_responses(&run.raw, &methods);
    // EOF or reset: both say the server closed (a reset only means it closed
    // with unread bytes of ours, which depends on timing)
    let end = if run.end == "reset" { "eof" } else { run.end };
    Outcome { responses, rest, end: end.to_string(), events: normalize_events(events, reference), closed }
}

// ---------------------------------------------------------------- jobs

struct Pair {
    a: Server,
    b: Server,
    next_conn: u64,
}

struct Shared {
    a_cmd: String,
    b_cmd: String,
    seed: u64,
    quiet: Duration,
    corpus: Vec<Vec<u8>>,
    out: std::path::PathBuf,
    stats: Mutex<Stats>,
    report: Mutex<std::fs::File>,
}

#[derive(Default)]
struct Stats {
    streams: u64,
    same: u64,
    deviation: u64,
    deviations: HashMap<&'static str, u64>,
    stable: u64,
    timing: u64,
    crashes: u64,
    kinds: HashMap<&'static str, u64>,
    files: u64,
}

impl Pair {
    fn spawn(sh: &Shared, spec: &Value) -> Result<Pair, String> {
        Ok(Pair { a: Server::spawn(&sh.a_cmd, spec)?, b: Server::spawn(&sh.b_cmd, spec)?, next_conn: 0 })
    }

    /// One run of the stream on both servers.
    fn run(&mut self, plan: &gen::Plan, quiet: Duration) -> (Outcome, Outcome) {
        self.next_conn += 1;
        let conn = self.next_conn;
        let (pa, pb) = (self.a.port, self.b.port);
        let (ra, rb) = std::thread::scope(|s| {
            let ha = s.spawn(|| run_client(pa, plan, quiet));
            let hb = s.spawn(|| run_client(pb, plan, quiet));
            (ha.join().unwrap(), hb.join().unwrap())
        });
        let (ea, ca) = self.a.take_conn(conn, Duration::from_secs(3));
        let (eb, cb) = self.b.take_conn(conn, Duration::from_secs(3));
        (outcome(ra, ea, ca, true), outcome(rb, eb, cb, false))
    }
}

/// Documented deviations (docs/design.md section 10) that
/// make a difference on purpose. S6-15 (decision 14): with pipeline_flush,
/// hyper 1.12 drops what is left in its write buffer when the connection
/// ends while unparsed bytes are still in its read buffer (io.rs
/// poll_flush skips the flush, into_inner / shutdown drop the buffer): a
/// 400 for a bad pipelined head, a 101. bearings flushes it before it closes.
/// Recognized when the profile has pipeline_flush, the events and the
/// connection's end are the same, and hyper's responses are a strict
/// prefix of bearings' with nothing after them.
///
/// S9-3 (timing): the client half-closes right after its last request and
/// half_close is off. If the FIN is there when the server reads the request,
/// the request is dropped (handler_dropped, outcome incomplete, no
/// response); if it comes a little later, the request is answered and the
/// connection then ends ok. Both servers do both (bench probe in S9-3);
/// which one wins depends on how fast the server reads after the data
/// arrives. Recognized when one side dropped the last request and the other
/// answered it, with the same requests and earlier responses.
/// End-of-head markers in a stream (CRLF CRLF or LF LF, hyper's
/// is_complete_fast patterns, counted without overlap), after the leading
/// CR/LF bytes (empty lines before a request, which hyper skips). Body bytes
/// may add markers, which only makes the S9-1 check stricter.
fn end_of_head_markers(data: &[u8]) -> usize {
    let mut i = data.iter().position(|&c| c != b'\r' && c != b'\n').unwrap_or(data.len());
    let mut n = 0;
    while i < data.len() {
        if data[i..].starts_with(b"\r\n\r\n") {
            n += 1;
            i += 4;
        } else if data[i..].starts_with(b"\n\n") {
            n += 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    n
}

fn known_deviation(spec: &Value, half_close: bool, data: &[u8], a: &Outcome, b: &Outcome) -> Option<&'static str> {
    if half_close && spec["config"]["half_close"] != json!(true) {
        for (x, y) in [(a, b), (b, a)] {
            let reqs = |o: &Outcome| -> Vec<Value> {
                o.events.iter().filter(|e| e["event"] == "request").cloned().collect()
            };
            let last = |o: &Outcome| o.events.last().map(|e| e["outcome"].clone()).unwrap_or(Value::Null);
            if x.events.iter().any(|e| e["event"] == "handler_dropped")
                && last(x) == json!("incomplete")
                && last(y) == json!("ok")
                && reqs(x) == reqs(y)
                && x.responses.len() < y.responses.len()
                && y.responses[..x.responses.len()] == x.responses[..]
            {
                return Some("S9-3");
            }
        }
    }
    // S9-1 (segmentation): an invalid head without an end of head is
    // rejected (400, parse) by a server whose first read held the bytes that
    // show the error, and never parsed again (incomplete at the client's
    // close) by one whose first read held fewer: hyper re-parses a partial
    // head only once an end of head may have arrived (is_complete_fast).
    // Recognized when one side ended `parse`, the other `incomplete`, with
    // the same requests and the incomplete side's responses a prefix of the
    // other's, and only when the head that was never parsed cannot have had
    // an end of head: the stream holds no more end-of-head markers than
    // requests were parsed (conservative: a complete invalid head, or a body
    // with CRLF CRLF, makes it fall through to the rerun rule).
    let markers = end_of_head_markers(data);
    for (x, y) in [(a, b), (b, a)] {
        let reqs = |o: &Outcome| -> Vec<Value> { o.events.iter().filter(|e| e["event"] == "request").cloned().collect() };
        let last = |o: &Outcome| o.events.last().map(|e| e["outcome"].clone()).unwrap_or(Value::Null);
        if last(x) == json!("incomplete")
            && last(y) == json!("parse")
            && reqs(x) == reqs(y)
            && x.responses.len() <= y.responses.len()
            && y.responses[..x.responses.len()] == x.responses[..]
            && markers <= reqs(x).len()
        {
            return Some("S9-1");
        }
    }
    let last = |o: &Outcome| o.events.last().map(|e| e["outcome"].clone()).unwrap_or(Value::Null);
    let reqs = |o: &Outcome| -> usize { o.events.iter().filter(|e| e["event"] == "request").count() };
    // S9-2 (segmentation): the HTTP/2 preface is recognized only with its 24
    // bytes buffered when the version error is found; a server whose first
    // read held only `PRI * HTTP/2` answers 400 (parse).
    if data.starts_with(b"PRI * HTTP/2") {
        for (x, y) in [(a, b), (b, a)] {
            if last(x) == json!("parse_version_h2")
                && x.responses.is_empty()
                && last(y) == json!("parse")
                && y.responses.len() == 1
                && y.responses[0].status == 400
                && reqs(x) == 0
                && reqs(y) == 0
            {
                return Some("S9-2");
            }
        }
    }
    // S9-1, which limit wins: with max_header_size / max_buf_size, a head
    // that reaches the limit before its end arrives is 431, one whose end
    // arrives in the read that crosses it is parsed (400 for an invalid
    // one). Same requests and responses but the last, 431 (or 414) vs 400.
    // Only when the stream is long enough to have reached the smaller limit:
    // a 431 on a shorter stream is a bearings bug, not this race.
    let limit = ["max_header_size", "max_buf_size"]
        .iter()
        .filter_map(|k| spec["config"][*k].as_u64())
        .min();
    if limit.map_or(false, |l| data.len() as u64 >= l) {
        for (x, y) in [(a, b), (b, a)] {
            let n = x.responses.len();
            if last(x) == json!("parse_too_large")
                && last(y) == json!("parse")
                && n >= 1
                && n == y.responses.len()
                && x.responses[..n - 1] == y.responses[..n - 1]
                && matches!(x.responses[n - 1].status, 431 | 414)
                && y.responses[n - 1].status == 400
                && reqs(x) == reqs(y)
            {
                return Some("S9-1");
            }
        }
    }
    // S6-15 (decision 14): with pipeline_flush, hyper drops what is left in
    // its write buffer when the connection ends while unparsed bytes remain
    // in its read buffer; bearings flushes it. Recognized only when the events
    // and the end are the same, hyper's responses are a strict prefix of
    // bearings', and bearings' final responses are exactly what the events say
    // the server answered: the handler_done statuses in order, then the
    // automatic error response of the connection's outcome (parse: 400,
    // parse_too_large: 431 or 414); 1xx interim responses (100 Continue)
    // may be among them.
    let pf = spec["config"]["pipeline_flush"] == json!(true);
    if pf
        && a.events == b.events
        && a.end == b.end
        && a.rest.is_empty()
        && b.rest.is_empty()
        && a.responses.len() < b.responses.len()
        && b.responses[..a.responses.len()] == a.responses[..]
    {
        let done: Vec<u64> = b
            .events
            .iter()
            .filter(|e| e["event"] == "handler_done" && e["result"] == "response")
            .map(|e| e["status"].as_u64().unwrap_or(0))
            .collect();
        let finals: Vec<u64> = b.responses.iter().map(|r| r.status as u64).filter(|s| !(100..200).contains(s) || *s == 101).collect();
        let tail_ok = match last(b).as_str() {
            Some("parse") => finals.len() == done.len() + 1 && finals[done.len()] == 400,
            Some("parse_too_large") => finals.len() == done.len() + 1 && matches!(finals[done.len()], 431 | 414),
            _ => finals.len() == done.len(),
        };
        if tail_ok && finals[..done.len()] == done[..] {
            return Some("S6-15");
        }
    }
    // BODY-ERR (docs/design.md section 10): a request body error (framing,
    // socket, the body rate rule), whether the handler reads it or the
    // server drains the body, ends the connection Ok on hyper (the error
    // goes to the body receiver only) and io on bearings (the connection
    // keeps it). Recognized when everything but the last outcome is the
    // same, hyper's outcome is ok, bearings' is io, and the last request has
    // a body (content-length or transfer-encoding).
    let has_body = |o: &Outcome| {
        o.events.iter().rev().find(|e| e["event"] == "request").map_or(false, |e| {
            e["headers"].as_array().map_or(false, |h| {
                h.iter().any(|f| {
                    let n = f[0].as_str().unwrap_or("").to_ascii_lowercase();
                    n == "content-length" || n == "transfer-encoding"
                })
            })
        })
    };
    if a.responses == b.responses
        && a.rest == b.rest
        && a.end == b.end
        && a.events.len() == b.events.len()
        && !a.events.is_empty()
        && a.events[..a.events.len() - 1] == b.events[..b.events.len() - 1]
        && has_body(b)
        && last(a) == json!("ok")
        && last(b) == json!("io")
    {
        let strip = |e: &Value| {
            let mut e = e.clone();
            if let Some(m) = e.as_object_mut() {
                m.remove("outcome");
            }
            e
        };
        if strip(a.events.last().unwrap()) == strip(b.events.last().unwrap()) {
            return Some("BODY-ERR");
        }
    }
    // S9-11: a 100 Continue that hyper leaves in its write buffer when the
    // body read then fails at the client's EOF (the handler fails, outcome
    // user, nothing flushed); bearings writes it before it closes. Recognized
    // when the events and the end are the same, the outcome is user, and
    // bearings' responses are hyper's plus one 100.
    if a.events == b.events
        && a.end == b.end
        && last(a) == json!("user")
        && b.responses.len() == a.responses.len() + 1
        && b.responses[..a.responses.len()] == a.responses[..]
        && b.responses[a.responses.len()].status == 100
    {
        return Some("S9-11");
    }
    None
}

fn plan_json(plan: &gen::Plan) -> Vec<Value> {
    let mut steps = vec![json!({"op": "connect", "nodelay": true})];
    for (piece, gap) in &plan.pieces {
        if *gap > 0 {
            steps.push(json!({"op": "sleep", "ms": gap}));
        }
        steps.push(json!({"op": "write", "data": latin1(piece), "may_fail": true}));
    }
    if plan.half_close {
        steps.push(json!({"op": "shutdown_write"}));
        steps.push(json!({"op": "read_to_eof", "allow_reset": true, "timeout_ms": 3000}));
    } else {
        steps.push(json!({"op": "sleep", "ms": 200}));
        steps.push(json!({"op": "close"}));
    }
    steps
}

fn write_case(sh: &Shared, prefix: &str, name: &str, spec: &Value, plan: &gen::Plan, a: &[Outcome], b: &[Outcome]) -> String {
    let n = {
        let mut st = sh.stats.lock().unwrap();
        st.files += 1;
        st.files
    };
    let file = sh.out.join(format!("{prefix}-{n}.json"));
    let dbg = |o: &[Outcome]| -> Vec<Value> {
        o.iter()
            .map(|x| {
                json!({
                    "responses": x.responses.iter().map(|r| json!({"status": r.status, "headers": r.headers, "body": latin1(&r.body)})).collect::<Vec<_>>(),
                    "rest": latin1(&x.rest), "end": x.end, "events": x.events, "conn_close_seen": x.closed,
                })
            })
            .collect()
    };
    let doc = json!({
        "description": format!("fuzz-diff {prefix}: {name} (M3 S9; replay with runner diff)"),
        "cases": [{"name": name, "server": spec, "steps": plan_json(plan),
                   "notes": {"a": dbg(a), "b": dbg(b)}}],
    });
    let _ = std::fs::write(&file, serde_json::to_vec_pretty(&doc).unwrap());
    file.display().to_string()
}

fn job(sh: Arc<Shared>, j: usize, jobs: usize, streams: u64) {
    let profs = profiles();
    let spec = profs[j % profs.len()].clone();
    let mut pair = match Pair::spawn(&sh, &spec) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("fuzz-diff: job {j}: {e}");
            sh.stats.lock().unwrap().crashes += 1;
            return;
        }
    };
    let mut i = j as u64;
    while i < streams {
        let mut r = gen::Rng::new(sh.seed.wrapping_mul(1_000_003).wrapping_add(i));
        let (data, kind) = gen::stream(&mut r, &sh.corpus);
        let plan = gen::plan(&mut r, &data);
        let name = format!("seed{}-stream{}-{}-profile{}", sh.seed, i, kind, j % profs.len());
        let (a, b) = pair.run(&plan, sh.quiet);
        let mut verdict = "same";
        if a != b && known_deviation(&spec, plan.half_close, &data, &a, &b).is_some() {
            verdict = "deviation";
            let mut st = sh.stats.lock().unwrap();
            *st.deviations.entry(known_deviation(&spec, plan.half_close, &data, &a, &b).unwrap()).or_default() += 1;
        } else if a != b {
            // a difference: 9 more runs on both servers. If some run of one
            // server gives what some run of the other gave, the outcome
            // depends on timing (segmentation, the client's FIN racing the
            // response): counted as `timing`. Else it is a difference.
            let mut runs_a = vec![a];
            let mut runs_b = vec![b];
            for _ in 0..9 {
                let (a2, b2) = pair.run(&plan, sh.quiet);
                runs_a.push(a2);
                runs_b.push(b2);
            }
            // timing only when every bearings run gave an outcome that some hyper
            // run gave too (or that a documented deviation explains next to
            // one); a bearings outcome never seen from hyper is a difference
            let any_equal = runs_b.iter().all(|y| {
                runs_a.contains(y) || runs_a.iter().any(|x| known_deviation(&spec, plan.half_close, &data, x, y).is_some())
            });
            if !any_equal {
                verdict = "stable";
                let f = write_case(&sh, "fail", &name, &spec, &plan, &runs_a, &runs_b);
                let _ = writeln!(sh.report.lock().unwrap(), "DIFFERENCE {name} {f}");
                eprintln!("fuzz-diff: DIFFERENCE {name}: {f}");
            } else {
                verdict = "timing";
                let n = sh.stats.lock().unwrap().timing;
                if n < 200 {
                    let f = write_case(&sh, "timing", &name, &spec, &plan, &runs_a, &runs_b);
                    let _ = writeln!(sh.report.lock().unwrap(), "TIMING {name} {f}");
                }
            }
        }
        for (srv, which) in [(&mut pair.a, "a"), (&mut pair.b, "b")] {
            if let Some(st) = srv.exited() {
                let msg = format!("CRASH server {which} ({}) exited ({st}) after {name}; stderr tail:\n{}", srv.cmd, srv.stderr_tail());
                eprintln!("fuzz-diff: {msg}");
                let _ = writeln!(sh.report.lock().unwrap(), "{msg}");
                sh.stats.lock().unwrap().crashes += 1;
                let f = write_case(&sh, "crash", &name, &spec, &plan, &[], &[]);
                let _ = writeln!(sh.report.lock().unwrap(), "CRASH-CASE {f}");
            }
        }
        if pair.a.exited().is_some() || pair.b.exited().is_some() {
            match Pair::spawn(&sh, &spec) {
                Ok(p) => pair = p,
                Err(e) => {
                    eprintln!("fuzz-diff: job {j}: respawn failed: {e}");
                    return;
                }
            }
        }
        {
            let mut st = sh.stats.lock().unwrap();
            st.streams += 1;
            *st.kinds.entry(kind).or_default() += 1;
            match verdict {
                "same" => st.same += 1,
                "deviation" => st.deviation += 1,
                "stable" => st.stable += 1,
                _ => st.timing += 1,
            }
            if st.streams % 5000 == 0 {
                eprintln!(
                    "fuzz-diff: {} streams, same {}, documented deviations {}, timing {}, differences {}, crashes {}",
                    st.streams, st.same, st.deviation, st.timing, st.stable, st.crashes
                );
            }
        }
        i += jobs as u64;
    }
    let _ = pair.a.spec.clone();
}

fn read_records(path: &str, fields: usize, take: usize, out: &mut Vec<Vec<u8>>) {
    let data = std::fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let mut p = 0;
    let mut k = 0;
    while p + 4 <= data.len() {
        let n = u32::from_le_bytes(data[p..p + 4].try_into().unwrap()) as usize;
        let rec = data[p + 4..p + 4 + n].to_vec();
        p += 4 + n;
        if k % fields == take {
            out.push(rec);
        }
        k += 1;
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let exe_dir = std::env::current_exe().unwrap().parent().unwrap().to_path_buf();
    let mut a_cmd = exe_dir.join("reference-server").display().to_string();
    let mut b_cmd = String::new();
    let mut streams: u64 = 2000;
    let mut seed: u64 = 1;
    let mut jobs: usize = 8;
    let mut quiet_ms: u64 = 100;
    let mut out = std::path::PathBuf::from("fuzz-diff-out");
    let mut corpus = Vec::new();
    let mut i = 1;
    while i < args.len() {
        let v = args.get(i + 1).cloned().unwrap_or_default();
        match args[i].as_str() {
            "--a" => a_cmd = v,
            "--b" => b_cmd = v,
            "--streams" => streams = v.parse().expect("--streams"),
            "--seed" => seed = v.parse().expect("--seed"),
            "--jobs" => jobs = v.parse().expect("--jobs"),
            "--quiet-ms" => quiet_ms = v.parse().expect("--quiet-ms"),
            "--out" => out = v.into(),
            "--inputs" => read_records(&v, 3, 2, &mut corpus),
            "--corpus" => read_records(&v, 1, 0, &mut corpus),
            other => {
                eprintln!("fuzz-diff: unknown argument {other}");
                std::process::exit(2);
            }
        }
        i += 2;
    }
    if b_cmd.is_empty() {
        eprintln!("usage: fuzz-diff --b CMD [--a CMD] [--streams N] [--seed S] [--jobs J] [--quiet-ms MS] [--out DIR] [--inputs FILE]... [--corpus FILE]...");
        std::process::exit(2);
    }
    // the parser corpus is large: keep inputs up to 64 KiB
    corpus.retain(|c| c.len() <= 65536);
    std::fs::create_dir_all(&out).unwrap();
    let report = std::fs::File::create(out.join("report.txt")).unwrap();
    let sh = Arc::new(Shared {
        a_cmd,
        b_cmd,
        seed,
        quiet: Duration::from_millis(quiet_ms),
        corpus,
        out: out.clone(),
        stats: Mutex::new(Stats::default()),
        report: Mutex::new(report),
    });
    let t0 = Instant::now();
    eprintln!(
        "fuzz-diff: {streams} streams, seed {seed}, {jobs} jobs, {} profiles, corpus {} inputs, a = {}, b = {}",
        profiles().len(),
        sh.corpus.len(),
        sh.a_cmd,
        sh.b_cmd
    );
    let hs: Vec<_> = (0..jobs)
        .map(|j| {
            let sh = sh.clone();
            std::thread::spawn(move || job(sh, j, jobs, streams))
        })
        .collect();
    for h in hs {
        let _ = h.join();
    }
    let st = sh.stats.lock().unwrap();
    let mut kinds: Vec<_> = st.kinds.iter().collect();
    kinds.sort();
    let line = format!(
        "SUMMARY streams={} same={} documented_deviations={} {:?} timing={} differences={} crashes={} seconds={:.0} kinds={:?}",
        st.streams,
        st.same,
        st.deviation,
        st.deviations,
        st.timing,
        st.stable,
        st.crashes,
        t0.elapsed().as_secs_f64(),
        kinds
    );
    println!("{line}");
    let _ = writeln!(sh.report.lock().unwrap(), "{line}");
    std::process::exit(if st.stable == 0 && st.crashes == 0 && st.streams == streams { 0 } else { 1 });
}
