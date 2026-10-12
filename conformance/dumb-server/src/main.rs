//! dumb-server: a mutation check for the conformance cases (test tooling only).
//!
//! It implements the process protocol of SPEC.md section 3 (LISTENING line, stdin control
//! commands with acknowledgements, `exit`, exit on end of stdin) and nothing else of the
//! contract. The server spec passed with `--config` is ignored. Every time the bytes received
//! on a connection contain a `\r\n\r\n`, everything up to and including it counts as one
//! "request" and the server writes
//!
//!     HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n
//!
//! Request bodies are not parsed (their bytes become part of the next "request"). The
//! connection is closed when the client sends EOF or the socket fails. No date header, no
//! keep-alive logic, no error responses, no timeouts, no upgrades.
//!
//! Events: by default only `control_ack` / `control_error`. With `--events` (placed before
//! `--config`), it also emits `conn_open`, a `request` event per "request" (method, target and
//! version split from the first line; headers split naively at the first colon, names
//! lowercased, in received order), and `conn_close` with outcome `ok` when the socket closes.
//!
//! A case that PASSES against this server checks less than a fixed 200 response can satisfy.
//! See MANIFEST.md for how each such case was judged.

use std::io::{BufRead, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

static OUT: Mutex<()> = Mutex::new(());
static CONNS: AtomicU64 = AtomicU64::new(0);

const RESPONSE: &[u8] = b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n";

/// latin-1 byte string -> JSON string literal (SPEC section 2).
fn jstr(bytes: &[u8]) -> String {
    let mut s = String::from("\"");
    for &b in bytes {
        match b {
            b'"' => s.push_str("\\\""),
            b'\\' => s.push_str("\\\\"),
            0x00..=0x1f | 0x7f..=0xff => s.push_str(&format!("\\u{:04x}", b)),
            _ => s.push(b as char),
        }
    }
    s.push('"');
    s
}

fn emit(line: &str) {
    let _g = OUT.lock().unwrap();
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(line.as_bytes());
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn request_event(conn: u64, req: u64, head: &[u8]) -> String {
    let mut lines = head.split(|&b| b == b'\n').map(|l| l.strip_suffix(b"\r").unwrap_or(l));
    let first = lines.next().unwrap_or(b"");
    let mut parts = first.splitn(3, |&b| b == b' ');
    let method = parts.next().unwrap_or(b"");
    let target = parts.next().unwrap_or(b"");
    let version = parts.next().unwrap_or(b"");
    let mut headers = Vec::new();
    for l in lines {
        if l.is_empty() {
            continue;
        }
        if let Some(c) = l.iter().position(|&b| b == b':') {
            let name = l[..c].to_ascii_lowercase();
            let value = l[c + 1..].trim_ascii();
            headers.push(format!("[{},{}]", jstr(&name), jstr(value)));
        }
    }
    format!(
        "{{\"event\":\"request\",\"conn\":{},\"req\":{},\"method\":{},\"target\":{},\"version\":{},\"headers\":[{}]}}",
        conn,
        req,
        jstr(method),
        jstr(target),
        jstr(version),
        headers.join(",")
    )
}

fn serve(mut sock: TcpStream, conn: u64, events: bool) {
    if events {
        emit(&format!("{{\"event\":\"conn_open\",\"conn\":{}}}", conn));
    }
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 65536];
    let mut req = 0u64;
    loop {
        match sock.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        let mut failed = false;
        while let Some(i) = find(&buf, b"\r\n\r\n") {
            let head: Vec<u8> = buf.drain(..i + 4).collect();
            req += 1;
            if events {
                emit(&request_event(conn, req, &head[..i]));
            }
            if sock.write_all(RESPONSE).is_err() {
                failed = true;
                break;
            }
        }
        if failed {
            break;
        }
    }
    drop(sock);
    if events {
        emit(&format!("{{\"event\":\"conn_close\",\"conn\":{},\"outcome\":\"ok\"}}", conn));
    }
}

fn main() {
    let events = std::env::args().any(|a| a == "--events");
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    emit(&format!("LISTENING {}", port));

    std::thread::spawn(|| {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let line = line.trim_end_matches('\r');
            if line == "exit" {
                std::process::exit(0);
            } else if line == "graceful_shutdown" {
                emit("{\"event\":\"control_ack\",\"command\":\"graceful_shutdown\"}");
            } else if let Some(name) = line.strip_prefix("signal ") {
                emit(&format!(
                    "{{\"event\":\"control_ack\",\"command\":\"signal\",\"name\":{}}}",
                    jstr(name.as_bytes())
                ));
            } else {
                emit(&format!("{{\"event\":\"control_error\",\"line\":{}}}", jstr(line.as_bytes())));
            }
        }
        // End of stdin: the runner is gone.
        std::process::exit(0);
    });

    for sock in listener.incoming() {
        let Ok(sock) = sock else { continue };
        let conn = CONNS.fetch_add(1, Ordering::SeqCst) + 1;
        std::thread::spawn(move || serve(sock, conn, events));
    }
}
