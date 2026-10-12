//! Reference HTTP/1 server for the bearings conformance harness.
//!
//! A hyper v1.12.0 server that reproduces the server setups used by hyper's own
//! HTTP/1 server tests (tests/server.rs `serve()`/TestService/ReplyBuilder,
//! HelloWorld, unreachable_service, the per-test `service_fn`s, and the t! macro
//! server in tests/support/mod.rs). The process protocol (config, stdout events,
//! stdin control commands) is specified in ../SPEC.md; this file implements it.

mod tokiort;

use std::collections::{HashSet, VecDeque};
use std::error::Error as StdError;
use std::future::Future;
use std::io::Write as _;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{ready, Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use harness_common::{check_keys, decode_bytes, latin1};
use http_body_util::{combinators::BoxBody, BodyExt, Empty, Full};
use hyper::body::{Body, Frame, Incoming};
use hyper::header::{HeaderMap, HeaderName, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::Service;
use hyper::{Request, Response, StatusCode, Version};
use serde_json::{json, Map, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokiort::TokioTimer;

type BoxError = Box<dyn StdError + Send + Sync>;
type ReplyBody = BoxBody<Bytes, BoxError>;

// ---------------------------------------------------------------------------
// Configuration (SPEC.md "Server spec")
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Debug)]
enum ConnMode {
    /// `serve_connection(io, svc).await`
    Plain,
    /// `serve_connection(io, svc).with_upgrades().await`
    WithUpgrades,
    /// `serve_connection(io, svc).without_shutdown().await`, then `Parts`.
    WithoutShutdown,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Handler {
    TestService,
    HelloWorld,
    Unreachable,
}

#[derive(Clone, Copy, Debug)]
enum HeaderReadTimeout {
    /// Field absent: hyper's default (30 s, only active when a timer is set).
    Default,
    /// `null`: `header_read_timeout(None)`.
    Disabled,
    Ms(u64),
}

#[derive(Clone, Debug)]
struct Config {
    keep_alive: Option<bool>,
    half_close: Option<bool>,
    title_case_headers: Option<bool>,
    preserve_header_case: Option<bool>,
    max_headers: Option<usize>,
    max_header_size: Option<usize>,
    max_buf_size: Option<usize>,
    timer: bool,
    header_read_timeout: HeaderReadTimeout,
    writev: Option<bool>,
    pipeline_flush: Option<bool>,
    auto_date_header: Option<bool>,
    ignore_invalid_headers: Option<bool>,
    allow_multiple_spaces_in_request_line_delimiters: Option<bool>,
    conn_mode: ConnMode,
    graceful_shutdown_on_accept: bool,
}

#[derive(Clone)]
enum StreamItem {
    Data { data: Bytes, delay_ms: u64 },
    Error { message: String, delay_ms: u64 },
}

impl StreamItem {
    fn delay_ms(&self) -> u64 {
        match self {
            StreamItem::Data { delay_ms, .. } | StreamItem::Error { delay_ms, .. } => *delay_ms,
        }
    }
}

#[derive(Clone)]
enum BodySpec {
    Empty,
    Known(Bytes),
    Stream {
        items: Vec<StreamItem>,
        trailers: Option<HeaderMap>,
    },
}

#[derive(Clone)]
struct UpgradeSpec {
    on_upgrade: bool,
    await_signal: Option<String>,
    write: Option<Bytes>,
    read_to_eof: bool,
}

#[derive(Clone)]
struct Reply {
    status: StatusCode,
    reason: Option<hyper::ext::ReasonPhrase>,
    version: Option<Version>,
    headers: Vec<(HeaderName, HeaderValue)>,
    body: BodySpec,
    error: Option<String>,
    read_body: bool,
    delay_ms: u64,
    upgrade: Option<UpgradeSpec>,
}

impl Default for Reply {
    fn default() -> Self {
        Reply {
            status: StatusCode::OK,
            reason: None,
            version: None,
            headers: Vec::new(),
            body: BodySpec::Empty,
            error: None,
            read_body: true,
            delay_ms: 0,
            upgrade: None,
        }
    }
}

fn opt_bool(m: &Map<String, Value>, k: &str) -> Result<Option<bool>, String> {
    match m.get(k) {
        None => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(v) => Err(format!("{k}: expected a boolean, found {v}")),
    }
}

fn opt_u64(m: &Map<String, Value>, k: &str) -> Result<Option<u64>, String> {
    match m.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| format!("{k}: expected a non-negative integer, found {v}")),
    }
}

fn opt_str<'a>(m: &'a Map<String, Value>, k: &str) -> Result<Option<&'a str>, String> {
    match m.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(v) => Err(format!("{k}: expected a string, found {v}")),
    }
}

fn parse_config(v: Option<&Value>) -> Result<Config, String> {
    let empty = Map::new();
    let m = match v {
        None => &empty,
        Some(Value::Object(m)) => m,
        Some(other) => return Err(format!("config: expected an object, found {other}")),
    };
    check_keys(
        m,
        &[
            "keep_alive",
            "half_close",
            "title_case_headers",
            "preserve_header_case",
            "max_headers",
            "max_header_size",
            "max_buf_size",
            "timer",
            "header_read_timeout_ms",
            "writev",
            "pipeline_flush",
            "auto_date_header",
            "ignore_invalid_headers",
            "allow_multiple_spaces_in_request_line_delimiters",
            "conn_mode",
            "graceful_shutdown_on_accept",
        ],
    )
    .map_err(|e| format!("config: {e}"))?;

    let header_read_timeout = match m.get("header_read_timeout_ms") {
        None => HeaderReadTimeout::Default,
        Some(Value::Null) => HeaderReadTimeout::Disabled,
        Some(v) => HeaderReadTimeout::Ms(v.as_u64().ok_or_else(|| {
            format!("header_read_timeout_ms: expected integer or null, found {v}")
        })?),
    };
    let timer = opt_bool(m, "timer")?.unwrap_or(false);
    if let HeaderReadTimeout::Ms(_) = header_read_timeout {
        if !timer {
            // hyper panics in serve_connection in this case ("timeout set, but no timer set").
            return Err("header_read_timeout_ms is set but timer is false (hyper requires a timer)".into());
        }
    }
    let max_buf_size = opt_u64(m, "max_buf_size")?.map(|v| v as usize);
    if let Some(n) = max_buf_size {
        if n < 8192 {
            // hyper panics in Builder::max_buf_size for values below 8192.
            return Err(format!("max_buf_size {n} is below hyper's minimum of 8192"));
        }
    }
    let conn_mode = match opt_str(m, "conn_mode")? {
        None | Some("plain") => ConnMode::Plain,
        Some("with_upgrades") => ConnMode::WithUpgrades,
        Some("without_shutdown") => ConnMode::WithoutShutdown,
        Some(other) => return Err(format!("conn_mode: unknown value {other:?}")),
    };
    Ok(Config {
        keep_alive: opt_bool(m, "keep_alive")?,
        half_close: opt_bool(m, "half_close")?,
        title_case_headers: opt_bool(m, "title_case_headers")?,
        preserve_header_case: opt_bool(m, "preserve_header_case")?,
        max_headers: opt_u64(m, "max_headers")?.map(|v| v as usize),
        max_header_size: opt_u64(m, "max_header_size")?.map(|v| v as usize),
        max_buf_size,
        timer,
        header_read_timeout,
        writev: opt_bool(m, "writev")?,
        pipeline_flush: opt_bool(m, "pipeline_flush")?,
        auto_date_header: opt_bool(m, "auto_date_header")?,
        ignore_invalid_headers: opt_bool(m, "ignore_invalid_headers")?,
        allow_multiple_spaces_in_request_line_delimiters: opt_bool(
            m,
            "allow_multiple_spaces_in_request_line_delimiters",
        )?,
        conn_mode,
        graceful_shutdown_on_accept: opt_bool(m, "graceful_shutdown_on_accept")?.unwrap_or(false),
    })
}

fn parse_header_list(v: &Value, what: &str) -> Result<Vec<(HeaderName, HeaderValue)>, String> {
    let arr = v
        .as_array()
        .ok_or_else(|| format!("{what}: expected an array of [name, value] pairs"))?;
    let mut out = Vec::new();
    for pair in arr {
        let p = pair
            .as_array()
            .filter(|p| p.len() == 2)
            .ok_or_else(|| format!("{what}: each entry must be [name, value], found {pair}"))?;
        let name = decode_bytes(&p[0], None)?;
        let value = decode_bytes(&p[1], None)?;
        let name = HeaderName::from_bytes(&name)
            .map_err(|e| format!("{what}: invalid header name {:?}: {e}", latin1(&name)))?;
        let value = HeaderValue::from_bytes(&value)
            .map_err(|e| format!("{what}: invalid header value {:?}: {e}", latin1(&value)))?;
        out.push((name, value));
    }
    Ok(out)
}

fn parse_body(v: &Value) -> Result<BodySpec, String> {
    let m = v.as_object().ok_or("body: expected an object")?;
    if let Some(k) = m.get("known") {
        check_keys(m, &["known"]).map_err(|e| format!("body: {e}"))?;
        return Ok(BodySpec::Known(Bytes::from(decode_bytes(k, None)?)));
    }
    if let Some(s) = m.get("stream") {
        check_keys(m, &["stream", "trailers"]).map_err(|e| format!("body: {e}"))?;
        let arr = s.as_array().ok_or("body.stream: expected an array")?;
        let mut items = Vec::new();
        for it in arr {
            let im = it.as_object().ok_or("body.stream: each item must be an object")?;
            check_keys(im, &["data", "error", "delay_ms", "times"])
                .map_err(|e| format!("body.stream item: {e}"))?;
            let delay_ms = opt_u64(im, "delay_ms")?.unwrap_or(0);
            let times = opt_u64(im, "times")?.unwrap_or(1);
            let item = match (im.get("data"), im.get("error")) {
                (Some(d), None) => StreamItem::Data {
                    data: Bytes::from(decode_bytes(d, None)?),
                    delay_ms,
                },
                (None, Some(Value::String(e))) => StreamItem::Error {
                    message: e.clone(),
                    delay_ms,
                },
                _ => return Err("body.stream item: needs exactly one of \"data\" or \"error\" (string)".into()),
            };
            for _ in 0..times {
                items.push(item.clone());
            }
        }
        let trailers = match m.get("trailers") {
            None => None,
            Some(t) => {
                let mut map = HeaderMap::new();
                // StreamBodyWithTrailers receives a HeaderMap built with insert().
                for (n, v) in parse_header_list(t, "body.trailers")? {
                    map.insert(n, v);
                }
                Some(map)
            }
        };
        return Ok(BodySpec::Stream { items, trailers });
    }
    Err("body: expected {\"known\": ...} or {\"stream\": [...]}".into())
}

fn parse_upgrade(v: &Value) -> Result<UpgradeSpec, String> {
    let m = v.as_object().ok_or("upgrade: expected an object")?;
    check_keys(m, &["on_upgrade", "await_signal", "write", "read_to_eof"])
        .map_err(|e| format!("upgrade: {e}"))?;
    Ok(UpgradeSpec {
        on_upgrade: opt_bool(m, "on_upgrade")?.unwrap_or(true),
        await_signal: opt_str(m, "await_signal")?.map(str::to_string),
        write: match m.get("write") {
            None => None,
            Some(w) => Some(Bytes::from(decode_bytes(w, None)?)),
        },
        read_to_eof: opt_bool(m, "read_to_eof")?.unwrap_or(true),
    })
}

fn parse_version(s: &str) -> Result<Version, String> {
    Ok(match s {
        "HTTP/0.9" => Version::HTTP_09,
        "HTTP/1.0" => Version::HTTP_10,
        "HTTP/1.1" => Version::HTTP_11,
        "HTTP/2.0" => Version::HTTP_2,
        "HTTP/3.0" => Version::HTTP_3,
        other => return Err(format!("unknown version {other:?}")),
    })
}

fn version_str(v: Version) -> &'static str {
    match v {
        Version::HTTP_09 => "HTTP/0.9",
        Version::HTTP_10 => "HTTP/1.0",
        Version::HTTP_11 => "HTTP/1.1",
        Version::HTTP_2 => "HTTP/2.0",
        Version::HTTP_3 => "HTTP/3.0",
        _ => "unknown",
    }
}

fn parse_reply(v: &Value) -> Result<Reply, String> {
    let m = v.as_object().ok_or("reply: expected an object")?;
    check_keys(
        m,
        &[
            "status", "reason", "version", "headers", "body", "error", "read_body", "delay_ms",
            "upgrade", "comment",
        ],
    )
    .map_err(|e| format!("reply: {e}"))?;
    let mut r = Reply::default();
    if let Some(s) = opt_u64(m, "status")? {
        r.status = StatusCode::from_u16(s as u16)
            .ok()
            .filter(|_| s <= u16::MAX as u64)
            .ok_or_else(|| format!("reply.status: invalid status {s}"))?;
    }
    if let Some(reason) = m.get("reason") {
        let b = decode_bytes(reason, None)?;
        r.reason = Some(
            hyper::ext::ReasonPhrase::try_from(b)
                .map_err(|e| format!("reply.reason: invalid reason phrase: {e}"))?,
        );
    }
    if let Some(ver) = opt_str(m, "version")? {
        r.version = Some(parse_version(ver)?);
    }
    if let Some(h) = m.get("headers") {
        r.headers = parse_header_list(h, "reply.headers")?;
    }
    if let Some(b) = m.get("body") {
        r.body = parse_body(b)?;
    }
    r.error = opt_str(m, "error")?.map(str::to_string);
    r.read_body = opt_bool(m, "read_body")?.unwrap_or(true);
    r.delay_ms = opt_u64(m, "delay_ms")?.unwrap_or(0);
    if let Some(u) = m.get("upgrade") {
        r.upgrade = Some(parse_upgrade(u)?);
    }
    Ok(r)
}

fn parse_server_spec(v: &Value) -> Result<(Config, Handler, Vec<Reply>, bool), String> {
    let m = v.as_object().ok_or("server spec must be a JSON object")?;
    check_keys(m, &["config", "handler", "replies", "bytes_read_events", "comment"])?;
    let bytes_read_events = opt_bool(m, "bytes_read_events")?.unwrap_or(false);
    let cfg = parse_config(m.get("config"))?;
    let handler = match opt_str(m, "handler")? {
        None | Some("test_service") => Handler::TestService,
        Some("hello_world") => Handler::HelloWorld,
        Some("unreachable") => Handler::Unreachable,
        Some(other) => return Err(format!("handler: unknown handler {other:?}")),
    };
    let mut replies = Vec::new();
    if let Some(rs) = m.get("replies") {
        let arr = rs.as_array().ok_or("replies: expected an array")?;
        for r in arr {
            replies.push(parse_reply(r)?);
        }
    }
    if handler != Handler::TestService && !replies.is_empty() {
        return Err("replies are only used by the test_service handler".into());
    }
    Ok((cfg, handler, replies, bytes_read_events))
}

// ---------------------------------------------------------------------------
// Events (SPEC.md "Server events")
// ---------------------------------------------------------------------------

fn emit(v: Value) {
    let line = v.to_string();
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = writeln!(lock, "{line}");
    let _ = lock.flush();
}

fn headers_json(h: &HeaderMap) -> Value {
    Value::Array(
        h.iter()
            .map(|(n, v)| json!([n.as_str(), latin1(v.as_bytes())]))
            .collect(),
    )
}

fn io_kind_class(k: std::io::ErrorKind) -> &'static str {
    match k {
        std::io::ErrorKind::UnexpectedEof => "unexpected_eof",
        std::io::ErrorKind::InvalidData => "invalid_data",
        std::io::ErrorKind::InvalidInput => "invalid_input",
        _ => "io",
    }
}

fn error_chain(e: &dyn StdError) -> String {
    let mut s = e.to_string();
    let mut cur = e.source();
    while let Some(c) = cur {
        s.push_str(": ");
        s.push_str(&c.to_string());
        cur = c.source();
    }
    s
}

fn conn_outcome(r: &Result<(), hyper::Error>) -> (&'static str, Option<String>) {
    let e = match r {
        Ok(()) => return ("ok", None),
        Err(e) => e,
    };
    let class = if e.is_timeout() {
        "timeout"
    } else if e.is_parse_too_large() {
        "parse_too_large"
    } else if e.is_parse_version_h2() {
        "parse_version_h2"
    } else if e.is_parse() {
        "parse"
    } else if e.is_incomplete_message() {
        "incomplete"
    } else if e.is_user() {
        "user"
    } else if e.is_canceled() {
        "canceled"
    } else if e.is_closed() {
        "closed"
    } else if e.is_body_write_aborted() {
        "body_write_aborted"
    } else if e.is_shutdown() {
        "shutdown"
    } else if e
        .source()
        .and_then(|s| s.downcast_ref::<std::io::Error>())
        .is_some()
    {
        "io"
    } else {
        "other"
    };
    (class, Some(error_chain(e)))
}

fn emit_conn_close(conn: u64, r: &Result<(), hyper::Error>) {
    let (outcome, detail) = conn_outcome(r);
    let mut ev = json!({"event": "conn_close", "conn": conn, "outcome": outcome});
    if let Some(d) = detail {
        eprintln!("reference-server: conn {conn} closed: {outcome}: {d}");
        ev["detail"] = Value::String(d);
    }
    emit(ev);
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

struct Ctx {
    cfg: Config,
    handler: Handler,
    replies: Mutex<VecDeque<Reply>>,
    shutdown_tx: tokio::sync::watch::Sender<u64>,
    signals: Mutex<HashSet<String>>,
    signal_notify: tokio::sync::Notify,
    /// Server spec `bytes_read_events`: emit `bytes_read` after each socket read.
    bytes_read_events: bool,
}

impl Ctx {
    /// TestService reply queue: one entry per service call, in call order;
    /// an exhausted queue yields the default reply (200, empty body).
    fn next_reply(&self) -> Reply {
        self.replies.lock().unwrap().pop_front().unwrap_or_default()
    }

    async fn wait_signal(&self, name: &str) {
        loop {
            let notified = self.signal_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.signals.lock().unwrap().contains(name) {
                return;
            }
            notified.await;
        }
    }

    fn builder(&self) -> http1::Builder {
        let c = &self.cfg;
        let mut b = http1::Builder::new();
        if let Some(v) = c.keep_alive {
            b.keep_alive(v);
        }
        if let Some(v) = c.half_close {
            b.half_close(v);
        }
        if let Some(v) = c.title_case_headers {
            b.title_case_headers(v);
        }
        if let Some(v) = c.preserve_header_case {
            b.preserve_header_case(v);
        }
        if let Some(v) = c.max_headers {
            b.max_headers(v);
        }
        if let Some(v) = c.max_header_size {
            b.max_header_size(v);
        }
        if let Some(v) = c.max_buf_size {
            b.max_buf_size(v);
        }
        if c.timer {
            b.timer(TokioTimer::new());
        }
        match c.header_read_timeout {
            HeaderReadTimeout::Default => {}
            HeaderReadTimeout::Disabled => {
                b.header_read_timeout(None);
            }
            HeaderReadTimeout::Ms(ms) => {
                b.header_read_timeout(Duration::from_millis(ms));
            }
        }
        if let Some(v) = c.writev {
            b.writev(v);
        }
        if let Some(v) = c.pipeline_flush {
            b.pipeline_flush(v);
        }
        if let Some(v) = c.auto_date_header {
            b.auto_date_header(v);
        }
        if let Some(v) = c.ignore_invalid_headers {
            b.ignore_invalid_headers(v);
        }
        if let Some(v) = c.allow_multiple_spaces_in_request_line_delimiters {
            b.allow_multiple_spaces_in_request_line_delimiters(v);
        }
        b
    }
}

// ---------------------------------------------------------------------------
// Response bodies
// ---------------------------------------------------------------------------

/// Unknown-length body that yields scripted frames, optionally delayed, then
/// optional trailers. Like http_body_util::StreamBody (and the tests'
/// StreamBodyWithTrailers) it keeps the default size_hint (no exact length)
/// and the default is_end_stream (false).
struct ScriptBody {
    items: VecDeque<StreamItem>,
    trailers: Option<HeaderMap>,
    sleep: Option<Pin<Box<tokio::time::Sleep>>>,
    slept: bool,
}

impl Body for ScriptBody {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        let this = self.get_mut();
        loop {
            if let Some(s) = this.sleep.as_mut() {
                ready!(s.as_mut().poll(cx));
                this.sleep = None;
                this.slept = true;
            }
            let delay = match this.items.front() {
                None => return Poll::Ready(this.trailers.take().map(|t| Ok(Frame::trailers(t)))),
                Some(item) => item.delay_ms(),
            };
            if delay > 0 && !this.slept {
                this.sleep = Some(Box::pin(tokio::time::sleep(Duration::from_millis(delay))));
                continue;
            }
            this.slept = false;
            return Poll::Ready(Some(match this.items.pop_front().unwrap() {
                StreamItem::Data { data, .. } => Ok(Frame::data(data)),
                StreamItem::Error { message, .. } => Err(message.into()),
            }));
        }
    }
}

fn make_body(spec: BodySpec) -> ReplyBody {
    match spec {
        BodySpec::Empty => Empty::<Bytes>::new().map_err(|e| match e {}).boxed(),
        BodySpec::Known(b) => Full::new(b).map_err(|e| match e {}).boxed(),
        BodySpec::Stream { items, trailers } => ScriptBody {
            items: items.into(),
            trailers,
            sleep: None,
            slept: false,
        }
        .boxed(),
    }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Svc {
    ctx: Arc<Ctx>,
    conn: u64,
    reqs: Arc<AtomicU64>,
    /// Upgrade actions to run on `Parts` after `without_shutdown()` resolves.
    pending_upgrade: Arc<Mutex<Option<UpgradeSpec>>>,
}

/// Emits `handler_dropped` if the handler future is dropped before it resolves.
struct DropGuard {
    conn: u64,
    req: u64,
    armed: bool,
}

impl Drop for DropGuard {
    fn drop(&mut self) {
        if self.armed {
            emit(json!({"event": "handler_dropped", "conn": self.conn, "req": self.req}));
        }
    }
}

impl Service<Request<Incoming>> for Svc {
    type Response = Response<ReplyBody>;
    type Error = BoxError;
    type Future = Pin<Box<dyn Future<Output = Result<Response<ReplyBody>, BoxError>> + Send>>;

    fn call(&self, req: Request<Incoming>) -> Self::Future {
        let req_id = self.reqs.fetch_add(1, Ordering::SeqCst) + 1;
        let conn = self.conn;
        emit(json!({
            "event": "request",
            "conn": conn,
            "req": req_id,
            "method": req.method().as_str(),
            "target": req.uri().to_string(),
            "version": version_str(req.version()),
            "headers": headers_json(req.headers()),
        }));
        let ctx = self.ctx.clone();
        let pending = self.pending_upgrade.clone();
        let reply = match ctx.handler {
            Handler::TestService => Some(ctx.next_reply()),
            _ => None,
        };
        // Created here, not inside the async block: hyper may drop the
        // handler future without ever polling it (e.g. EOF right after the
        // head), and that must still produce a handler_dropped event.
        let guard = DropGuard {
            conn,
            req: req_id,
            armed: true,
        };
        Box::pin(async move {
            // Move the whole guard into the future (a plain field access would
            // only capture a copy of `armed` under edition-2021 closure capture).
            let mut guard = guard;
            let result = handle(ctx, conn, req_id, req, reply, pending).await;
            guard.armed = false;
            match &result {
                Ok(res) => emit(json!({
                    "event": "handler_done", "conn": conn, "req": req_id,
                    "result": "response", "status": res.status().as_u16(),
                })),
                Err(e) => emit(json!({
                    "event": "handler_done", "conn": conn, "req": req_id,
                    "result": "error", "message": e.to_string(),
                })),
            }
            result
        })
    }
}

async fn handle(
    ctx: Arc<Ctx>,
    conn: u64,
    req_id: u64,
    mut req: Request<Incoming>,
    reply: Option<Reply>,
    pending: Arc<Mutex<Option<UpgradeSpec>>>,
) -> Result<Response<ReplyBody>, BoxError> {
    let reply = match ctx.handler {
        // tests/server.rs HelloWorld: 200, Full body "hello"; never reads the body.
        Handler::HelloWorld => {
            return Ok(Response::new(make_body(BodySpec::Known(Bytes::from_static(b"hello")))))
        }
        // tests/server.rs unreachable_service.
        Handler::Unreachable => return Err("request shouldn't be received".into()),
        Handler::TestService => reply.expect("test_service reply"),
    };

    // hyper::upgrade::on must take the OnUpgrade before the request is dropped.
    let on_upgrade = match &reply.upgrade {
        Some(u) if u.on_upgrade => Some(hyper::upgrade::on(&mut req)),
        _ => None,
    };

    if reply.read_body {
        // TestService::call: read every frame before building the reply.
        let mut body = Vec::new();
        let mut trailers: Option<HeaderMap> = None;
        while let Some(item) = req.body_mut().frame().await {
            match item {
                Ok(frame) => {
                    if frame.is_data() {
                        body.extend_from_slice(&frame.into_data().unwrap_or_default());
                    } else if let Ok(t) = frame.into_trailers() {
                        trailers.get_or_insert_with(HeaderMap::new).extend(t);
                    }
                }
                Err(err) => {
                    let (kind, message) = match err
                        .source()
                        .and_then(|s| s.downcast_ref::<std::io::Error>())
                    {
                        Some(io) => (io_kind_class(io.kind()), io.to_string()),
                        None => ("other", err.to_string()),
                    };
                    emit(json!({
                        "event": "request_body_error", "conn": conn, "req": req_id,
                        "kind": kind, "message": message,
                    }));
                    return Err("req body error".into());
                }
            }
        }
        let mut ev = json!({
            "event": "request_body", "conn": conn, "req": req_id, "body": latin1(&body),
        });
        if let Some(t) = &trailers {
            ev["trailers"] = headers_json(t);
        }
        emit(ev);
    }
    drop(req);

    if reply.delay_ms > 0 {
        tokio::time::sleep(Duration::from_millis(reply.delay_ms)).await;
    }
    if let Some(e) = reply.error {
        return Err(e.into());
    }

    if let Some(spec) = reply.upgrade.clone() {
        match on_upgrade {
            Some(on_upgrade) => {
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    match on_upgrade.await {
                        Ok(upgraded) => match upgraded.downcast::<CountIo>() {
                            Ok(parts) => {
                                run_upgrade(ctx, conn, parts.io.into_stream(), parts.read_buf, spec).await
                            }
                            Err(_) => emit(json!({
                                "event": "upgrade_error", "conn": conn,
                                "message": "upgraded IO is not CountIo",
                            })),
                        },
                        Err(e) => emit(json!({
                            "event": "upgrade_error", "conn": conn, "message": e.to_string(),
                        })),
                    }
                });
            }
            None => *pending.lock().unwrap() = Some(spec),
        }
    }

    let mut res = Response::new(make_body(reply.body));
    *res.status_mut() = reply.status;
    if let Some(r) = reply.reason {
        res.extensions_mut().insert(r);
    }
    if let Some(v) = reply.version {
        *res.version_mut() = v;
    }
    for (n, v) in reply.headers {
        // ReplyBuilder::header -> HeaderMap::insert (replaces an earlier value).
        res.headers_mut().insert(n, v);
    }
    Ok(res)
}

async fn run_upgrade(ctx: Arc<Ctx>, conn: u64, mut io: TcpStream, read_buf: Bytes, spec: UpgradeSpec) {
    emit(json!({"event": "upgraded", "conn": conn, "read_buf": latin1(&read_buf)}));
    if let Some(name) = &spec.await_signal {
        ctx.wait_signal(name).await;
    }
    if let Some(w) = &spec.write {
        if let Err(e) = io.write_all(w).await {
            emit(json!({"event": "upgrade_error", "conn": conn, "message": e.to_string()}));
            return;
        }
    }
    if spec.read_to_eof {
        let mut v = Vec::new();
        match io.read_to_end(&mut v).await {
            Ok(_) => emit(json!({
                "event": "upgrade_read", "conn": conn, "data": latin1(&v), "end": "eof",
            })),
            Err(e) => emit(json!({
                "event": "upgrade_read", "conn": conn, "data": latin1(&v), "end": "error",
                "message": e.to_string(),
            })),
        }
    }
}

// ---------------------------------------------------------------------------
// Connection IO: counts the bytes hyper reads (SPEC.md `bytes_read` event)
// ---------------------------------------------------------------------------

/// The IO hyper drives: a TcpStream adapted to hyper's IO traits exactly as
/// tests/support/tokiort.rs `TokioIo` does it, plus a count of the bytes hyper
/// has read from the socket. When `emit` is set, every read that returns data
/// emits `bytes_read` before the bytes are handed back to hyper. Writes and
/// `is_write_vectored` are delegated unchanged, so the wire behavior is the
/// same as with `TokioIo<TcpStream>`.
struct CountIo {
    inner: TcpStream,
    conn: u64,
    total: u64,
    emit: bool,
}

impl CountIo {
    fn into_stream(self) -> TcpStream {
        self.inner
    }
}

impl hyper::rt::Read for CountIo {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        mut buf: hyper::rt::ReadBufCursor<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        let this = self.get_mut();
        // Same as TokioIo::poll_read.
        let n = unsafe {
            let mut tbuf = tokio::io::ReadBuf::uninit(buf.as_mut());
            match tokio::io::AsyncRead::poll_read(Pin::new(&mut this.inner), cx, &mut tbuf) {
                Poll::Ready(Ok(())) => tbuf.filled().len(),
                other => return other,
            }
        };
        unsafe {
            buf.advance(n);
        }
        if n > 0 {
            this.total += n as u64;
            if this.emit {
                emit(json!({"event": "bytes_read", "conn": this.conn, "total": this.total}));
            }
        }
        Poll::Ready(Ok(()))
    }
}

impl hyper::rt::Write for CountIo {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<Result<usize, std::io::Error>> {
        tokio::io::AsyncWrite::poll_write(Pin::new(&mut self.get_mut().inner), cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), std::io::Error>> {
        tokio::io::AsyncWrite::poll_flush(Pin::new(&mut self.get_mut().inner), cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), std::io::Error>> {
        tokio::io::AsyncWrite::poll_shutdown(Pin::new(&mut self.get_mut().inner), cx)
    }

    fn is_write_vectored(&self) -> bool {
        tokio::io::AsyncWrite::is_write_vectored(&self.inner)
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[std::io::IoSlice<'_>],
    ) -> Poll<Result<usize, std::io::Error>> {
        tokio::io::AsyncWrite::poll_write_vectored(Pin::new(&mut self.get_mut().inner), cx, bufs)
    }
}

// ---------------------------------------------------------------------------
// Connection driver
// ---------------------------------------------------------------------------

enum Step<R> {
    Done(R),
    Shutdown,
}

async fn serve_conn(ctx: Arc<Ctx>, stream: TcpStream, conn: u64) {
    emit(json!({"event": "conn_open", "conn": conn}));
    let io = CountIo {
        inner: stream,
        conn,
        total: 0,
        emit: ctx.bytes_read_events,
    };
    let pending = Arc::new(Mutex::new(None));
    let svc = Svc {
        ctx: ctx.clone(),
        conn,
        reqs: Arc::new(AtomicU64::new(0)),
        pending_upgrade: pending.clone(),
    };
    let builder = ctx.builder();
    let mut sd = ctx.shutdown_tx.subscribe();
    let gsoa = ctx.cfg.graceful_shutdown_on_accept;

    match ctx.cfg.conn_mode {
        ConnMode::Plain => {
            let mut c = Box::pin(builder.serve_connection(io, svc));
            if gsoa {
                c.as_mut().graceful_shutdown();
            }
            let r = loop {
                let step = tokio::select! {
                    biased;
                    Ok(()) = sd.changed() => Step::Shutdown,
                    r = c.as_mut() => Step::Done(r),
                };
                match step {
                    Step::Done(r) => break r,
                    Step::Shutdown => c.as_mut().graceful_shutdown(),
                }
            };
            // Drop the connection (and any in-flight handler) first, so
            // handler_dropped precedes conn_close.
            drop(c);
            emit_conn_close(conn, &r);
        }
        ConnMode::WithUpgrades => {
            let mut c = Box::pin(builder.serve_connection(io, svc).with_upgrades());
            if gsoa {
                c.as_mut().graceful_shutdown();
            }
            let r = loop {
                let step = tokio::select! {
                    biased;
                    Ok(()) = sd.changed() => Step::Shutdown,
                    r = c.as_mut() => Step::Done(r),
                };
                match step {
                    Step::Done(r) => break r,
                    Step::Shutdown => c.as_mut().graceful_shutdown(),
                }
            };
            // Drop the connection (and any in-flight handler) first, so
            // handler_dropped precedes conn_close.
            drop(c);
            emit_conn_close(conn, &r);
        }
        ConnMode::WithoutShutdown => {
            let mut c = builder.serve_connection(io, svc);
            if gsoa {
                Pin::new(&mut c).graceful_shutdown();
            }
            let r = loop {
                let step = tokio::select! {
                    biased;
                    Ok(()) = sd.changed() => Step::Shutdown,
                    r = std::future::poll_fn(|cx| c.poll_without_shutdown(cx)) => Step::Done(r),
                };
                match step {
                    Step::Done(r) => break r,
                    Step::Shutdown => Pin::new(&mut c).graceful_shutdown(),
                }
            };
            if r.is_err() {
                drop(c);
                emit_conn_close(conn, &r);
                return;
            }
            let parts = c.into_parts();
            emit_conn_close(conn, &r);
            let spec = pending.lock().unwrap().take();
            if let Some(spec) = spec {
                run_upgrade(ctx.clone(), conn, parts.io.into_stream(), parts.read_buf, spec).await;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Control channel (stdin) and main
// ---------------------------------------------------------------------------

async fn control_loop(ctx: Arc<Ctx>) {
    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        let (cmd, arg) = match line.split_once(' ') {
            Some((c, a)) => (c, Some(a.trim())),
            None => (line, None),
        };
        match (cmd, arg) {
            ("", _) => {}
            ("graceful_shutdown", None) => {
                ctx.shutdown_tx.send_modify(|g| *g += 1);
                emit(json!({"event": "control_ack", "command": "graceful_shutdown"}));
            }
            ("signal", Some(name)) if !name.is_empty() => {
                ctx.signals.lock().unwrap().insert(name.to_string());
                ctx.signal_notify.notify_waiters();
                emit(json!({"event": "control_ack", "command": "signal", "name": name}));
            }
            ("exit", None) => std::process::exit(0),
            _ => emit(json!({"event": "control_error", "line": line})),
        }
    }
    // stdin closed: the runner is gone.
    std::process::exit(0);
}

fn usage() -> ! {
    eprintln!(
        "usage: reference-server (--config <server-spec.json> | --config-json '<json>')\n\
         Prints \"LISTENING <port>\" then one JSON event per line. See conformance/SPEC.md."
    );
    std::process::exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let text = match args.as_slice() {
        [flag, path] if flag == "--config" => std::fs::read_to_string(path).unwrap_or_else(|e| {
            eprintln!("reference-server: cannot read {path}: {e}");
            std::process::exit(2)
        }),
        [flag, json] if flag == "--config-json" => json.clone(),
        [] => "{}".to_string(),
        _ => usage(),
    };
    let spec: Value = serde_json::from_str(&text).unwrap_or_else(|e| {
        eprintln!("reference-server: config is not valid JSON: {e}");
        std::process::exit(2)
    });
    let (cfg, handler, replies, bytes_read_events) = parse_server_spec(&spec).unwrap_or_else(|e| {
        eprintln!("reference-server: invalid server spec: {e}");
        std::process::exit(2)
    });
    let (shutdown_tx, _) = tokio::sync::watch::channel(0u64);
    let ctx = Arc::new(Ctx {
        cfg,
        handler,
        replies: Mutex::new(replies.into()),
        shutdown_tx,
        signals: Mutex::new(HashSet::new()),
        signal_notify: tokio::sync::Notify::new(),
        bytes_read_events,
    });

    // hyper's tests use a current-thread runtime (tests/support/mod.rs runtime()).
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async move {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind 127.0.0.1:0");
        let port = listener.local_addr().expect("local_addr").port();
        {
            let stdout = std::io::stdout();
            let mut lock = stdout.lock();
            let _ = writeln!(lock, "LISTENING {port}");
            let _ = lock.flush();
        }
        tokio::spawn(control_loop(ctx.clone()));
        let mut next_conn = 0u64;
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    next_conn += 1;
                    tokio::spawn(serve_conn(ctx.clone(), stream, next_conn));
                }
                Err(e) => eprintln!("reference-server: accept error: {e}"),
            }
        }
    });
}
