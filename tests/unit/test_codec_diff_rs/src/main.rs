// Test tooling only (never shipped).
//
// Generates random (often corrupted) message bodies and header values, runs
// them through hyper v1.12.0's own Decoder (src/proto/h1/decode.rs) and
// header helpers (src/headers.rs), and writes the cases and hyper's results.
// test_codec_diff.pas replays the same cases through bearings.http1.decode and
// bearings.http.headers and compares.
//
// Usage: test_codec_diff_rs <seed> <n_decode> <n_headers> <out_dir>
// Writes <out_dir>/decode_cases.txt, decode_expected.txt,
//        <out_dir>/headers_cases.txt, headers_expected.txt
//
// Decode case line:  K N MAXH MAXHS BODYHEX SPLITS
//   K      L (Length N) | C (Chunked MAXH MAXHS) | E (Eof)
//   MAXH, MAXHS: -1 = None
//   BODYHEX: the transport bytes in hex ('-' if empty)
//   SPLITS: comma-separated read sizes summing to the body length ('-' if
//           none). The transport delivers one split per read, is Pending
//           between splits, and hits EOF after the last.
// Decode expected line: STATUS|DATALEN|DATAFNV|LEFTOVER|THEN|ISEOF
//   STATUS   END | TRL:<name=hexvalue,...> | ERR:<io::ErrorKind>:<message>
//   LEFTOVER transport bytes the decoder did not read ('-' after an error)
//   THEN     result of one more decode call ('-' after an error)
//   ISEOF    decoder.is_eof() after STATUS ('-' after an error)
//
// Header case line: FUNC HEX1 HEX2 ... (one HEX per header line, '-' = empty)
// Header expected line: the function's result.

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

mod headers;
mod proto;

use bytes::Bytes;
use http::header::{self, HeaderMap, HeaderValue};
use proto::h1::decode::Decoder;
use proto::h1::io::MemRead;
use std::fmt::Write as _;
use std::io::Write as _;
use std::task::{Context, Poll, Waker};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            0
        } else {
            self.next() % n
        }
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }
    fn pick<T: Copy>(&mut self, xs: &[T]) -> T {
        xs[self.below(xs.len() as u64) as usize]
    }
}

struct Src {
    segs: Vec<Vec<u8>>,
    idx: usize,
    pos: usize,
}

impl Src {
    fn leftover(&self) -> usize {
        if self.idx >= self.segs.len() {
            return 0;
        }
        let mut n = self.segs[self.idx].len() - self.pos;
        for s in &self.segs[self.idx + 1..] {
            n += s.len();
        }
        n
    }
    fn advance(&mut self) {
        self.idx += 1;
        self.pos = 0;
    }
}

impl MemRead for Src {
    fn read_mem(&mut self, _cx: &mut Context<'_>, len: usize) -> Poll<std::io::Result<Bytes>> {
        if self.idx >= self.segs.len() {
            return Poll::Ready(Ok(Bytes::new())); // EOF
        }
        let seg = &self.segs[self.idx];
        if self.pos >= seg.len() {
            return Poll::Pending;
        }
        let n = std::cmp::min(len, seg.len() - self.pos);
        let b = Bytes::copy_from_slice(&seg[self.pos..self.pos + n]);
        self.pos += n;
        Poll::Ready(Ok(b))
    }
}

fn hex(b: &[u8]) -> String {
    if b.is_empty() {
        return "-".to_string();
    }
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        write!(s, "{:02x}", x).unwrap();
    }
    s
}

fn fnv1a(b: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn norm_msg(m: &str) -> String {
    // hyper appends the httparse Header debug text to these two; the port
    // reports the fixed part only.
    for p in ["Invalid header name", "Invalid header value"] {
        if m.starts_with(p) {
            return p.to_string();
        }
    }
    m.to_string()
}

fn opt(v: i64) -> Option<usize> {
    if v < 0 {
        None
    } else {
        Some(v as usize)
    }
}

fn run_decode(kind: u8, n: u64, maxh: i64, maxhs: i64, body: &[u8], splits: &[usize]) -> String {
    let mut dec = match kind {
        b'L' => Decoder::length(n),
        b'C' => Decoder::chunked(opt(maxh), opt(maxhs)),
        _ => Decoder::eof(),
    };
    let mut segs = Vec::new();
    let mut p = 0;
    for &s in splits {
        segs.push(body[p..p + s].to_vec());
        p += s;
    }
    let mut src = Src { segs, idx: 0, pos: 0 };
    let mut cx = Context::from_waker(Waker::noop());
    let mut data = Vec::new();
    let status;
    let mut guard = 0u64;
    loop {
        guard += 1;
        assert!(guard < 50_000_000, "no progress");
        match dec.decode(&mut cx, &mut src) {
            Poll::Pending => src.advance(),
            Poll::Ready(Ok(frame)) => {
                if frame.is_data() {
                    let d = frame.into_data().unwrap();
                    if d.is_empty() {
                        status = "END".to_string();
                        break;
                    }
                    data.extend_from_slice(&d);
                } else {
                    let t = frame.into_trailers().unwrap();
                    let mut s = String::from("TRL:");
                    let mut first = true;
                    for (name, value) in t.iter() {
                        if !first {
                            s.push(',');
                        }
                        first = false;
                        write!(s, "{}={}", name.as_str(), hex(value.as_bytes())).unwrap();
                    }
                    status = s;
                    break;
                }
            }
            Poll::Ready(Err(e)) => {
                status = format!("ERR:{:?}:{}", e.kind(), norm_msg(&e.to_string()));
                break;
            }
        }
    }
    let (left, then, iseof) = if status.starts_with("ERR") {
        ("-".to_string(), "-".to_string(), "-".to_string())
    } else {
        let left = src.leftover().to_string();
        let iseof = (dec.is_eof() as u8).to_string();
        let then = loop {
            match dec.decode(&mut cx, &mut src) {
                Poll::Pending => src.advance(),
                Poll::Ready(Ok(f)) => {
                    break if f.is_data() && f.data_ref().unwrap().is_empty() {
                        "END".to_string()
                    } else {
                        "FRAME".to_string()
                    }
                }
                Poll::Ready(Err(e)) => break format!("ERR:{:?}", e.kind()),
            }
        };
        (left, then, iseof)
    };
    format!(
        "{}|{}|{:016x}|{}|{}|{}",
        status,
        data.len(),
        fnv1a(&data),
        left,
        then,
        iseof
    )
}

// ---- body generators ----

fn push_hex_size(r: &mut Rng, v: &mut Vec<u8>, size: u64) {
    if r.chance(8) {
        for _ in 0..r.below(20) + 1 {
            v.push(b'0');
        }
    }
    let s = format!("{:x}", size);
    for c in s.bytes() {
        if c.is_ascii_alphabetic() && r.chance(50) {
            v.push(c.to_ascii_uppercase());
        } else {
            v.push(c);
        }
    }
}

fn gen_ext(r: &mut Rng, v: &mut Vec<u8>) {
    let n = r.below(12);
    for _ in 0..n {
        let k = r.below(100);
        let b = if k < 94 {
            r.pick(b"abcxyz=;\"' \t-_.0123456789")
        } else if k < 95 {
            b'\n'
        } else if k < 96 {
            b'\r'
        } else if k < 98 {
            0
        } else {
            0x80 + r.below(128) as u8
        };
        v.push(b);
    }
}

fn push_line_end(r: &mut Rng, v: &mut Vec<u8>) {
    let k = r.below(100);
    if k < 90 {
        v.extend_from_slice(b"\r\n");
    } else if k < 94 {
        v.push(b'\n');
    } else if k < 97 {
        v.push(b'\r');
    } else {
        v.extend_from_slice(b"\r\r\n");
    }
}

fn push_size_line(r: &mut Rng, v: &mut Vec<u8>, size: u64) {
    push_hex_size(r, v, size);
    if r.chance(15) {
        for _ in 0..r.below(4) + 1 {
            v.push(r.pick(b" \t"));
        }
    }
    if r.chance(25) {
        for _ in 0..r.below(3) + 1 {
            v.push(b';');
            gen_ext(r, v);
        }
    }
    push_line_end(r, v);
}

const NAME_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFXYZ0123456789-_!#$%&'*+.^`|~";
const VALUE_CHARS: &[u8] = b"abcdefXYZ 0123456789,;:=/\"()<>@?[]{}\t";

fn gen_trailer_line(r: &mut Rng, v: &mut Vec<u8>) {
    let k = r.below(100);
    if k < 4 {
        // obs-fold continuation
        v.push(r.pick(b" \t"));
        v.extend_from_slice(b"folded\r\n");
        return;
    }
    if k < 6 {
        v.extend_from_slice(b"\n");
        return;
    }
    // name
    let nl = r.below(8) + 1;
    for _ in 0..nl {
        v.push(r.pick(NAME_CHARS));
    }
    if r.chance(4) {
        v.push(r.pick(b"@()<>,;\\\"/[]?={} \t\x80\x00"));
    }
    if r.chance(4) {
        v.push(b' ');
    }
    if !r.chance(4) {
        v.push(b':');
    }
    // whitespace after colon
    if r.chance(70) {
        for _ in 0..r.below(3) + 1 {
            v.push(r.pick(b" \t"));
        }
    }
    let vl = r.below(12);
    for _ in 0..vl {
        let k = r.below(100);
        let b = if k < 85 {
            r.pick(VALUE_CHARS)
        } else if k < 92 {
            0x80 + r.below(128) as u8
        } else if k < 94 {
            0x7f
        } else if k < 96 {
            0
        } else if k < 98 {
            b'\n'
        } else {
            r.below(32) as u8
        };
        v.push(b);
    }
    if r.chance(10) {
        for _ in 0..r.below(3) + 1 {
            v.push(r.pick(b" \t"));
        }
    }
    let k = r.below(100);
    if k < 92 {
        v.extend_from_slice(b"\r\n");
    } else if k < 97 {
        v.push(b'\n');
    } else {
        v.push(b'\r');
    }
}

fn gen_chunked(r: &mut Rng) -> Vec<u8> {
    let mut v = Vec::new();
    let special = r.below(100);
    if special < 3 {
        // chunk extensions near CHUNKED_EXTENSIONS_LIMIT (16384, whole body)
        let total = 16384 - 6 + r.below(12) as usize;
        let parts = r.below(3) as usize + 1;
        let mut left = total;
        for i in 0..parts {
            let n = if i + 1 == parts { left } else { left / 2 };
            left -= n;
            v.extend_from_slice(b"1;");
            // ext_cnt counts the bytes after the first ';'
            for _ in 0..n {
                v.push(b'x');
            }
            v.extend_from_slice(b"\r\nA\r\n");
        }
        v.extend_from_slice(b"0\r\n\r\n");
        return v;
    }
    if special < 5 {
        // trailers near TRAILER_LIMIT (16384)
        v.extend_from_slice(b"0\r\n");
        let target = 16384 - 8 + r.below(16) as usize;
        let lines = r.below(3) as usize + 1;
        // each line "tN: " + value + "\r\n"; the final "\r\n" adds 2
        let per = (target - 2) / lines;
        let mut used = 0;
        for i in 0..lines {
            let mut line = format!("t{}: ", i).into_bytes();
            let want = if i + 1 == lines { target - 2 - used } else { per };
            while line.len() + 2 < want {
                line.push(b'v');
            }
            line.extend_from_slice(b"\r\n");
            used += line.len();
            v.extend_from_slice(&line);
        }
        v.extend_from_slice(b"\r\n");
        return v;
    }
    if special < 7 {
        // big or huge sizes
        let size = r.pick(&[
            0xffff_ffff_ffff_ffffu64,
            0x0fff_ffff_ffff_ffff,
            0x1_0000,
            0x2000,
            300,
        ]);
        if r.chance(30) {
            v.extend_from_slice(b"10000000000000000"); // 2^64: overflow
        } else {
            push_hex_size(r, &mut v, size);
        }
        v.extend_from_slice(b"\r\n");
        let n = std::cmp::min(size, 400 + r.below(400)) as usize;
        for i in 0..n {
            v.push((i * 7 + 13) as u8);
        }
        if size as usize == n {
            v.extend_from_slice(b"\r\n0\r\n\r\n");
        }
        return v;
    }

    let nchunks = r.below(4);
    for _ in 0..nchunks {
        let size = if r.chance(85) {
            r.below(20) + 1
        } else {
            r.below(200) + 1
        };
        push_size_line(r, &mut v, size);
        let mut n = size as usize;
        if r.chance(5) {
            n = if r.chance(50) { n + 1 } else { n - 1 };
        }
        for _ in 0..n {
            v.push(r.below(256) as u8);
        }
        let k = r.below(100);
        if k < 92 {
            v.extend_from_slice(b"\r\n");
        } else if k < 95 {
            v.push(b'\n');
        } else if k < 97 {
            v.push(b'\r');
        } else {
            v.extend_from_slice(b"xx");
        }
    }
    // last chunk
    if r.chance(10) {
        v.extend_from_slice(b"00");
    } else {
        v.push(b'0');
    }
    if r.chance(10) {
        v.push(r.pick(b" \t"));
    }
    if r.chance(15) {
        v.push(b';');
        gen_ext(r, &mut v);
    }
    push_line_end(r, &mut v);
    // trailers
    if r.chance(45) {
        for _ in 0..r.below(5) + 1 {
            gen_trailer_line(r, &mut v);
        }
    }
    let k = r.below(100);
    if k < 90 {
        v.extend_from_slice(b"\r\n");
    } else if k < 94 {
        v.push(b'\n');
    } else if k < 97 {
        v.push(b'\r');
    }
    v
}

fn finish_body(r: &mut Rng, mut v: Vec<u8>) -> Vec<u8> {
    // bytes after the body (a pipelined request)
    if r.chance(30) {
        if r.chance(50) {
            v.extend_from_slice(b"GET / HTTP/1.1\r\n\r\n");
        } else {
            for _ in 0..r.below(10) + 1 {
                v.push(r.below(256) as u8);
            }
        }
    }
    // random mutations
    if r.chance(10) && !v.is_empty() {
        for _ in 0..r.below(3) + 1 {
            let i = r.below(v.len() as u64) as usize;
            match r.below(3) {
                0 => v[i] = r.pick(b"\r\n;:0aF \t\x00\x80"),
                1 => v.insert(i, r.pick(b"\r\n;:0aF \t\x00\x80")),
                _ => {
                    v.remove(i);
                }
            }
            if v.is_empty() {
                break;
            }
        }
    }
    // early EOF
    if r.chance(12) && !v.is_empty() {
        let n = r.below(v.len() as u64) as usize;
        v.truncate(n);
    }
    v
}

fn gen_splits(r: &mut Rng, len: usize) -> Vec<usize> {
    let mut s = Vec::new();
    if len == 0 {
        if r.chance(50) {
            s.push(0);
        }
        return s;
    }
    let mode = r.below(5);
    let mut left = len;
    while left > 0 {
        let n = match mode {
            0 => left,
            1 => 1,
            2 => (r.below(8) + 1) as usize,
            3 => r.below(17) as usize, // zero-length reads too
            _ => {
                if s.is_empty() {
                    r.below(left as u64 + 1) as usize
                } else {
                    left
                }
            }
        };
        let n = std::cmp::min(n, left);
        s.push(n);
        left -= n;
    }
    s
}

fn gen_decode_case(r: &mut Rng) -> (u8, u64, i64, i64, Vec<u8>, Vec<usize>) {
    let k = r.below(100);
    let (kind, n, maxh, maxhs, body) = if k < 80 {
        let maxh = r.pick(&[-1i64, -1, -1, -1, -1, 0, 1, 2, 3, 100]);
        let maxhs = match r.below(10) {
            0..=3 => -1,
            4 => 0,
            5 => 1,
            6..=8 => r.below(48) as i64,
            _ => 64,
        };
        let raw = gen_chunked(r);
        let body = finish_body(r, raw);
        (b'C', 0u64, maxh, maxhs, body)
    } else if k < 92 {
        let len = r.below(30) as usize;
        let mut body = Vec::new();
        for _ in 0..len {
            body.push(r.below(256) as u8);
        }
        let n = match r.below(6) {
            0 => 0,
            1 => len as u64,
            2 => (len as u64).saturating_sub(1),
            3 => len as u64 + 1,
            4 => u64::MAX - 2,
            _ => r.below(40),
        };
        if r.chance(30) {
            body.extend_from_slice(b"NEXT");
        }
        (b'L', n, -1, -1, body)
    } else {
        let len = r.below(30) as usize;
        let mut body = Vec::new();
        for _ in 0..len {
            body.push(r.below(256) as u8);
        }
        (b'E', 0, -1, -1, body)
    };
    let splits = gen_splits(r, body.len());
    (kind, n, maxh, maxhs, body, splits)
}

// ---- header helper cases ----

fn gen_value(r: &mut Rng, words: &[&[u8]]) -> Vec<u8> {
    let mut v = Vec::new();
    let parts = r.below(4);
    for i in 0..parts {
        if i > 0 || r.chance(10) {
            v.push(b',');
        }
        for _ in 0..r.below(3) {
            v.push(r.pick(b" \t"));
        }
        if r.chance(85) {
            let w = r.pick(words);
            for &c in w {
                v.push(if c.is_ascii_alphabetic() && r.chance(20) {
                    c.to_ascii_uppercase()
                } else {
                    c
                });
            }
        }
        if r.chance(8) {
            v.push(r.pick(b"x\x80\xff+-\""));
        }
        for _ in 0..r.below(3) {
            v.push(r.pick(b" \t"));
        }
    }
    if r.chance(5) {
        v.push(b',');
    }
    v
}

fn hv(b: &[u8]) -> HeaderValue {
    HeaderValue::from_bytes(b).expect("generated value must be a valid HeaderValue")
}

fn bool_s(b: bool) -> String {
    (b as u8).to_string()
}

fn gen_header_case(r: &mut Rng) -> (String, Vec<Vec<u8>>, String) {
    let funcs = ["cc", "ka", "ic", "cl", "cla", "te", "cac", "tec"];
    let f = r.pick(&funcs);
    let conn_words: &[&[u8]] = &[b"close", b"keep-alive", b"upgrade", b"closed", b"clos", b"keep_alive", b"te"];
    let te_words: &[&[u8]] = &[b"chunked", b"gzip", b"trailers", b"identity", b"chunk", b"chunkedx", b"deflate"];
    let num_words: &[&[u8]] = &[
        b"0",
        b"10",
        b"010",
        b"18446744073709551615",
        b"18446744073709551616",
        b"99999999999999999999",
        b"5",
        b"+5",
        b"-1",
        b"1e3",
        b"",
    ];
    let words = match f {
        "cc" | "ka" | "cac" => conn_words,
        "cl" | "cla" => num_words,
        _ => te_words,
    };
    let nlines = match f {
        "cc" | "ka" | "ic" | "cl" => 1,
        _ => r.below(4),
    };
    let mut lines = Vec::new();
    for _ in 0..nlines {
        lines.push(gen_value(r, words));
    }
    let mut map = HeaderMap::new();
    let name = match f {
        "cla" | "cl" => header::CONTENT_LENGTH,
        "te" => header::TE,
        "cac" | "cc" | "ka" => header::CONNECTION,
        _ => header::TRANSFER_ENCODING,
    };
    for l in &lines {
        map.append(name.clone(), hv(l));
    }
    let out = match f {
        "cc" => bool_s(headers::connection_close(&hv(&lines[0]))),
        "ka" => bool_s(headers::connection_keep_alive(&hv(&lines[0]))),
        "ic" => bool_s(headers::is_chunked_(&hv(&lines[0]))),
        "cl" => match headers::content_length_parse(&hv(&lines[0])) {
            Some(n) => format!("N:{}", n),
            None => "NONE".to_string(),
        },
        "cla" => match headers::content_length_parse_all(&map) {
            Some(n) => format!("N:{}", n),
            None => "NONE".to_string(),
        },
        "te" => bool_s(headers::te_is_trailers(&map)),
        "cac" => bool_s(headers::connection_any_close(&map)),
        "tec" => bool_s(headers::transfer_encoding_is_chunked(&map)),
        _ => unreachable!(),
    };
    (f.to_string(), lines, out)
}

// `run <cases_file>`: hyper's result for each decode case line in the file
// (same format as decode_cases.txt), printed to stdout. Used to get hyper's
// exact answers for the hand-written Extra_* tests.
fn run_file(path: &str) {
    let text = std::fs::read_to_string(path).unwrap();
    for line in text.lines() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let w: Vec<&str> = line.split(' ').collect();
        let body = if w[4] == "-" {
            Vec::new()
        } else {
            (0..w[4].len() / 2)
                .map(|i| u8::from_str_radix(&w[4][2 * i..2 * i + 2], 16).unwrap())
                .collect::<Vec<u8>>()
        };
        let splits: Vec<usize> = if w[5] == "-" {
            Vec::new()
        } else {
            w[5].split(',').map(|s| s.parse().unwrap()).collect()
        };
        let res = run_decode(
            w[0].as_bytes()[0],
            w[1].parse().unwrap(),
            w[2].parse().unwrap(),
            w[3].parse().unwrap(),
            &body,
            &splits,
        );
        println!("{}", res);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "run" {
        run_file(&args[2]);
        return;
    }
    if args.len() != 5 {
        eprintln!("usage: {} <seed> <n_decode> <n_headers> <out_dir>", args[0]);
        std::process::exit(2);
    }
    let seed: u64 = args[1].parse().unwrap();
    let n_decode: usize = args[2].parse().unwrap();
    let n_headers: usize = args[3].parse().unwrap();
    let dir = std::path::Path::new(&args[4]);
    let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);

    let mut cases = std::io::BufWriter::new(std::fs::File::create(dir.join("decode_cases.txt")).unwrap());
    let mut exp = std::io::BufWriter::new(std::fs::File::create(dir.join("decode_expected.txt")).unwrap());
    for _ in 0..n_decode {
        let (kind, n, maxh, maxhs, body, splits) = gen_decode_case(&mut r);
        let sp = if splits.is_empty() {
            "-".to_string()
        } else {
            splits.iter().map(|s| s.to_string()).collect::<Vec<_>>().join(",")
        };
        writeln!(cases, "{} {} {} {} {} {}", kind as char, n, maxh, maxhs, hex(&body), sp).unwrap();
        writeln!(exp, "{}", run_decode(kind, n, maxh, maxhs, &body, &splits)).unwrap();
    }

    let mut cases = std::io::BufWriter::new(std::fs::File::create(dir.join("headers_cases.txt")).unwrap());
    let mut exp = std::io::BufWriter::new(std::fs::File::create(dir.join("headers_expected.txt")).unwrap());
    for _ in 0..n_headers {
        let (f, lines, out) = gen_header_case(&mut r);
        let mut line = f.clone();
        for l in &lines {
            line.push(' ');
            line.push_str(&hex(l));
        }
        writeln!(cases, "{}", line).unwrap();
        writeln!(exp, "{}", out).unwrap();
    }
}
