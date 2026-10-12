// Test tooling only (never shipped).
//
// Generates request heads and request targets, runs them through hyper
// v1.12.0's own Server::parse (src/proto/h1/role.rs, copied unchanged) and
// http::Uri::try_from, and writes the cases and hyper's results.
// test_role_diff.pas replays the cases through bearings.http1.role / bearings.http.uri
// and compares (request acceptance: framing, CL/TE, header limits).
// (Step T1 removed the Server::encode / encode_trailers cases: the response
// encoding is checked by the fixed expectations of test_role_verify,
// test_role_extra and test_codec_extra.)
//
// Usage: test_role_diff_rs <seed> <n_parse> <out_dir> [n_uri]
// Writes <out_dir>/role_cases.txt and <out_dir>/role_expected.txt.
//
// Case lines (hex '-' = empty bytes, '~' = None):
//   P <maxh> <maxhs> <flags> <hexreq>
//       maxh, maxhs: -1 = None. flags: 3 digits, ParserConfig
//       allow_multiple_spaces_in_request_line_delimiters,
//       allow_space_before_first_header_name,
//       ignore_invalid_headers_in_requests.
//   U <hex>
//       http::Uri::try_from(bytes) alone (http 1.5.0), any bytes.
// Expected lines: see drive_parse in proto/h1/mod.rs;
//   for U: OK <scheme> <authority> <path> <query> (hex, ~ = None) or
//   ERR <InvalidUri Display text>.

#![allow(dead_code, unused_imports, unused_macros, unused_variables, unused_mut)]

macro_rules! trace {
    ($($t:tt)*) => {};
}
macro_rules! debug {
    ($($t:tt)*) => {};
}
macro_rules! warn {
    ($($t:tt)*) => {};
}
macro_rules! error {
    ($($t:tt)*) => {};
}
macro_rules! trace_span {
    ($($t:tt)*) => {
        ()
    };
}

mod body;
mod common;
mod error;
mod ext;
mod headers;
mod proto;

pub(crate) use error::Error;
pub(crate) type Result<T> = std::result::Result<T, Error>;

use http::{Method, Version};
use proto::h1::{drive_parse, hex};
use proto::BodyLength;
use std::io::Write as _;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }
    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len() as u64) as usize]
    }
}

const METHODS: &[&str] = &[
    "GET", "GET", "GET", "POST", "POST", "HEAD", "CONNECT", "PUT", "OPTIONS", "DELETE",
    "PATCH", "TRACE", "get", "FOO", "M-SEARCH", "G\x01T", "",
];

const TARGETS: &[&[u8]] = &[
    b"/", b"/", b"*", b"/echo", b"/a?b=c", b"/a#frag", b"/?", b"/a?b#c", b"/a?b?c",
    b"http://example.com", b"http://example.com/", b"HTTP://EXAMPLE.COM/x", b"https://a:443/p?q",
    b"hTTpS://h", b"ftp://x/y", b"htt:p//", b"example.com:443", b"[::1]:8080", b"[::1",
    b"::1]", b"a:b:c", b"user@host:80", b"user@", b"@host", b"h%20st", b"user%40:pw@host",
    b"x", b"a", b":", b"@", b"%", b"[", b"/\"{}|", b"/^", b"/`", b"/\\", b"/<>",
    "/caf\u{e9}".as_bytes(), b"/\xff", b"/\xc3", b"//", b"?x", b"#x", b"s://", b"s://@", b"s://h",
    b"scheme+1.x://h/p", b"http://[v1.fe80::a+en1]/", b"http://a:b@c:d/", b"http://a/b?c?d#e#f",
    b"/%zz", b"http://", b"http:///", b"http://h?q", b"http://h#f", b"http://h:", b"http://[::1]:80/",
    b"http://[::1]x/", b"http://a]b/", b"http://h%41/", b"http://u%41@h/", b"http://[fe80::1%25en0]/",
    b"a:1:2:3:4:5:6:7:8:9", b"[1:2:3:4:5:6:7:8]:9", b"~a://b/", b"a~://b/", b"1a://b/",
    b"http:/x", b"http:x", b"/a?\xc3\xa9", b"/a?\"", b"/a?{", b"/a? ", b"/a#\xff",
    b"/a?b#\x7e", b"/~", b"/'", b"/(", b"/[", b"/]", b"/a?[]", b"/a?'",
    b"localhost:8080:3030", b"example.com/path", b"example.com?q", b"h@", b"u@h@i",
];

const SCHEME_LONG: usize = 65;

fn gen_target(r: &mut Rng) -> Vec<u8> {
    match r.below(10) {
        0..=5 => r.pick(TARGETS).to_vec(),
        6 => {
            // scheme length boundary around MAX_SCHEME_LEN (64)
            let n = 62 + r.below(5) as usize;
            let mut v = vec![b'a'; n];
            v.extend_from_slice(b"://h/p");
            v
        }
        7 if r.chance(5) => {
            // URI length boundary: MAX_URI_LEN = 65534
            let n = 65532 + r.below(5) as usize;
            let mut v = vec![b'/'];
            v.extend(std::iter::repeat(b'a').take(n - 1));
            v
        }
        _ => {
            const ALPHA: &[u8] = b"/?#:@[]%!$&'()*+,;=-._~\"{}|^`\\<>aZ09\x7f\x80\xc3\xa9\xff";
            let mut v = Vec::new();
            match r.below(4) {
                0 => v.push(b'/'),
                1 => v.extend_from_slice(b"http://"),
                2 => v.extend_from_slice(b"x://"),
                _ => {}
            }
            let n = 1 + r.below(12);
            for _ in 0..n {
                v.push(*r.pick(ALPHA));
            }
            v
        }
    }
}

const REQ_HEADERS: &[(&str, &[&[u8]])] = &[
    ("Host", &[b"example.com", b"hyper.rs", b""]),
    ("content-length", &[b"10", b"0", b"5", b"+10", b"-1", b"1 0", b"10, 10", b"18446744073709551613", b"18446744073709551614", b"18446744073709551615", b"18446744073709551616", b"abc", b"", b"007"]),
    ("Content-Length", &[b"10", b"11"]),
    ("transfer-encoding", &[b"chunked", b"gzip", b"gzip, chunked", b"chunked, gzip", b"CHUNKED", b"gzip,chunked", b"chunked ,", b"identity", b"", b"afterlol", b"gzip, \x80chunked"]),
    ("Transfer-Encoding", &[b"chunked", b"gzip"]),
    ("connection", &[b"close", b"keep-alive", b"Keep-Alive", b"foo, close, bar", b"upgrade", b"foo", b"CLOSE", b"keep-alive, close", b""]),
    ("expect", &[b"100-continue", b"100-Continue", b"100-continue ", b"200-ok", b""]),
    ("upgrade", &[b"websocket", b"h2c"]),
    ("x-a", &[b"1", b"", b"a\tb", b"\xc3\xa9"]),
    ("X-A", &[b"2"]),
    ("te", &[b"trailers"]),
    ("trailer", &[b"x-a"]),
];

fn gen_request(r: &mut Rng) -> Vec<u8> {
    let mut v = Vec::new();
    if r.chance(3) {
        v.extend_from_slice(b"\r\n");
    }
    let method = *r.pick(METHODS);
    v.extend_from_slice(method.as_bytes());
    v.push(b' ');
    if r.chance(3) {
        v.push(b' ');
    }
    v.extend_from_slice(&gen_target(r));
    v.push(b' ');
    if r.chance(3) {
        v.push(b' ');
    }
    let ver: &[u8] = match r.below(20) {
        0..=13 => b"HTTP/1.1",
        14..=17 => b"HTTP/1.0",
        18 => b"HTTP/2.0",
        _ => b"HTTP/1.2",
    };
    v.extend_from_slice(ver);
    let lf_only = r.chance(10);
    let eol: &[u8] = if lf_only { b"\n" } else { b"\r\n" };
    v.extend_from_slice(eol);
    let n = r.below(7);
    for _ in 0..n {
        let (name, vals) = r.pick(REQ_HEADERS);
        let val: &[u8] = r.pick(vals);
        match r.below(30) {
            0 => {
                v.extend_from_slice(name.as_bytes());
                v.extend_from_slice(b" : ");
            }
            1 => {
                v.extend_from_slice(name.as_bytes());
                v.extend_from_slice(b":");
            }
            2 => {
                v.extend_from_slice(b" ");
                v.extend_from_slice(name.as_bytes());
                v.extend_from_slice(b": ");
            }
            _ => {
                v.extend_from_slice(name.as_bytes());
                v.extend_from_slice(b": ");
            }
        }
        v.extend_from_slice(val);
        if r.chance(3) {
            v.extend_from_slice(b" \t");
        }
        v.extend_from_slice(eol);
        if r.chance(2) {
            // obs-fold
            v.extend_from_slice(b" folded");
            v.extend_from_slice(eol);
        }
    }
    v.extend_from_slice(eol);
    if r.chance(10) {
        v.extend_from_slice(b"body bytes");
    }
    // mutations
    if r.chance(8) && !v.is_empty() {
        let i = r.below(v.len() as u64) as usize;
        v[i] = r.below(256) as u8;
    }
    if r.chance(10) {
        let cut = r.below(v.len() as u64 + 1) as usize;
        v.truncate(cut);
    }
    v
}

// M3 step H (decision 13): requests with more than 100 header lines and
// max_headers above 100 (hyper's heap header slots, bearings'
// ServerParseHeapSlots); own Rng, appended after the other cases
fn gen_many_headers(r: &mut Rng) -> (i64, Vec<u8>) {
    let maxh: i64 = *r.pick(&[101i64, 128, 150, 200, 256, 300, -1]);
    let n = 90 + r.below(240) as usize;
    let mut v = b"GET /many HTTP/1.1\r\nHost: x\r\n".to_vec();
    for i in 0..n {
        if r.chance(1) {
            v.extend_from_slice(b"bad header\r\n");
        } else {
            v.extend_from_slice(format!("x-h{}: v{}\r\n", i, r.below(1000)).as_bytes());
        }
    }
    v.extend_from_slice(b"\r\n");
    (maxh, v)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 || args.len() > 5 {
        eprintln!("usage: test_role_diff_rs <seed> <n_parse> <out_dir> [n_uri]");
        std::process::exit(2);
    }
    let seed: u64 = args[1].parse().unwrap();
    let np: usize = args[2].parse().unwrap();
    let out = std::path::Path::new(&args[3]);
    let nu: usize = if args.len() == 5 { args[4].parse().unwrap() } else { np };
    let mut r = Rng(seed.wrapping_mul(0x9E3779B97F4A7C15) | 1);
    let mut cases = std::io::BufWriter::new(std::fs::File::create(out.join("role_cases.txt")).unwrap());
    let mut expected =
        std::io::BufWriter::new(std::fs::File::create(out.join("role_expected.txt")).unwrap());

    for _ in 0..np {
        let req = gen_request(&mut r);
        let maxh: i64 = if r.chance(15) { r.below(8) as i64 } else { -1 };
        let maxhs: i64 = if r.chance(10) {
            (req.len() as i64 - 3 + r.below(6) as i64).max(0)
        } else {
            -1
        };
        let f0 = r.chance(10);
        let f1 = r.chance(10);
        let f2 = r.chance(10);
        let mut cfg = httparse::ParserConfig::default();
        cfg.allow_multiple_spaces_in_request_line_delimiters(f0);
        cfg.allow_space_before_first_header_name(f1);
        cfg.ignore_invalid_headers_in_requests(f2);
        writeln!(
            cases,
            "P {} {} {}{}{} {}",
            maxh,
            maxhs,
            f0 as u8,
            f1 as u8,
            f2 as u8,
            hex(&req)
        )
        .unwrap();
        let res = drive_parse(
            &req,
            if maxh < 0 { None } else { Some(maxh as usize) },
            if maxhs < 0 { None } else { Some(maxhs as usize) },
            cfg,
        );
        writeln!(expected, "{}", res).unwrap();
    }

    for _ in 0..nu {
        let mut t = gen_target(&mut r);
        if r.chance(20) {
            // any byte, including ones httparse would reject
            let i = r.below(t.len() as u64 + 1) as usize;
            t.insert(i, r.below(256) as u8);
        }
        writeln!(cases, "U {}", hex(&t)).unwrap();
        let res = match http::Uri::try_from(t.as_slice()) {
            Err(e) => format!("ERR {}", e),
            Ok(u) => format!(
                "OK {} {} {} {}",
                u.scheme_str().map(|s| hex(s.as_bytes())).unwrap_or("~".into()),
                u.authority().map(|a| hex(a.as_str().as_bytes())).unwrap_or("~".into()),
                hex(u.path().as_bytes()),
                u.query().map(|q| hex(q.as_bytes())).unwrap_or("~".into())
            ),
        };
        writeln!(expected, "{}", res).unwrap();
    }

    // step H: max_headers above 100 (np / 20 cases, own Rng)
    let mut rm = Rng(seed.wrapping_mul(0xD1B54A32D192ED03) | 1);
    for _ in 0..np / 20 {
        let (maxh, req) = gen_many_headers(&mut rm);
        writeln!(cases, "P {} -1 000 {}", maxh, hex(&req)).unwrap();
        let res = drive_parse(
            &req,
            if maxh < 0 { None } else { Some(maxh as usize) },
            None,
            httparse::ParserConfig::default(),
        );
        writeln!(expected, "{}", res).unwrap();
    }
}
