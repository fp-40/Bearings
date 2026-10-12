//! Request-stream generator of the differential fuzz: a grammar of HTTP/1
//! requests (methods, targets, versions, header lines, Content-Length and
//! Transfer-Encoding combinations, chunk framing, trailers, pipelines, the
//! HTTP/2 preface) and byte mutations of a seed corpus (the conformance
//! case inputs and the M2 parser corpus, which holds httparse's test inputs
//! when it was generated with HTTPARSE_SRC).

pub struct Rng(pub u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        let mut r = Rng(seed ^ 0x5DEECE66D);
        r.next();
        r
    }
    /// splitmix64
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }
    pub fn pct(&mut self, p: usize) -> bool {
        self.below(100) < p
    }
    pub fn pick<'a, T>(&mut self, a: &'a [T]) -> &'a T {
        &a[self.below(a.len())]
    }
    /// weighted pick: (weight, value)
    pub fn wpick<'a, T>(&mut self, a: &'a [(usize, T)]) -> &'a T {
        let total: usize = a.iter().map(|x| x.0).sum();
        let mut r = self.below(total);
        for (w, v) in a {
            if r < *w {
                return v;
            }
            r -= *w;
        }
        &a[a.len() - 1].1
    }
}

pub const H2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const H2_SETTINGS: &[u8] = b"\x00\x00\x06\x04\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x64";

const METHODS: &[(usize, &[u8])] = &[
    (30, b"GET"), (20, b"POST"), (8, b"HEAD"), (5, b"PUT"), (4, b"DELETE"), (3, b"OPTIONS"),
    (3, b"PATCH"), (4, b"CONNECT"), (2, b"TRACE"), (1, b"PRI"), (3, b"FOO"), (2, b"get"),
    (1, b"G\x00T"), (1, b""), (2, b"M-SEARCH"), (1, b"GE T"), (1, b"\x7fGET"),
];

fn target(r: &mut Rng, method: &[u8]) -> Vec<u8> {
    if method == b"CONNECT" && r.pct(70) {
        return r.pick(&[&b"example.com:443"[..], b"127.0.0.1:80", b"example.com", b"[::1]:8080", b"/x"]).to_vec();
    }
    match r.below(20) {
        0..=7 => b"/".to_vec(),
        8..=10 => r.pick(&[&b"/path/to?q=1&x=%20"[..], b"/a/b;c?d=e", b"/index.html", b"/%00", b"/~user"]).to_vec(),
        11 => b"*".to_vec(),
        12 => r.pick(&[&b"http://example.com/x"[..], b"http://example.com:8080", b"https://h/p?q", b"http://user@h/"]).to_vec(),
        13 => r.pick(&[&b"/a b"[..], b"/\x7f", b"/\xc3\xa9", b"", b"?", b"//", b"/#frag", b"/\t", b"/{}", b"/\"x\""]).to_vec(),
        14 => {
            let n = r.pick(&[100usize, 1000, 8000, 20000]);
            let mut t = b"/".to_vec();
            t.extend(std::iter::repeat(b'a').take(*n));
            t
        }
        15 => {
            // longer than 65534: 414
            if r.pct(10) {
                let mut t = b"/".to_vec();
                t.extend(std::iter::repeat(b'b').take(65534 + r.below(4)));
                t
            } else {
                b"/x".to_vec()
            }
        }
        _ => {
            let mut t = b"/".to_vec();
            for _ in 0..r.below(12) {
                t.push(*r.pick(b"abcz09-._~!$&'()*+,;=:@/?%"));
            }
            t
        }
    }
}

const VERSIONS: &[(usize, &[u8])] = &[
    (80, b"HTTP/1.1"), (10, b"HTTP/1.0"), (2, b"HTTP/2.0"), (1, b"HTTP/0.9"), (1, b"HTTP/1.2"),
    (1, b"HTTP/11"), (1, b"http/1.1"), (1, b"HTTP/1.1 "), (1, b""), (1, b"HTTP/3"),
];

fn eol(r: &mut Rng) -> &'static [u8] {
    *r.wpick(&[(92, &b"\r\n"[..]), (7, b"\n"), (1, b"\r")])
}

enum Framing {
    None,
    Length(usize, Vec<u8>),   // declared, header text
    Chunked(Vec<u8>),         // TE header text
    Both(usize, Vec<u8>),
}

fn cl_value(r: &mut Rng, n: usize) -> Vec<u8> {
    match r.below(30) {
        0 => format!("0{n}").into_bytes(),
        1 => format!("+{n}").into_bytes(),
        2 => b"-1".to_vec(),
        3 => format!("{n}, {n}").into_bytes(),
        4 => format!("{n},{}", n + 1).into_bytes(),
        5 => format!(" {n} ").into_bytes(),
        6 => b"18446744073709551616".to_vec(),
        7 => b"abc".to_vec(),
        8 => b"".to_vec(),
        9 => format!("{n}\t").into_bytes(),
        _ => format!("{n}").into_bytes(),
    }
}

fn te_value(r: &mut Rng) -> Vec<u8> {
    r.wpick(&[
        (20, &b"chunked"[..]), (2, b"Chunked"), (2, b"gzip, chunked"), (2, b"chunked, gzip"),
        (2, b"chunked, chunked"), (1, b"identity"), (1, b"gzip"), (1, b" chunked"), (1, b"chunked;q=1"),
        (1, b"chunked\t"), (1, b"x-custom, chunked"), (1, b""),
    ])
    .to_vec()
}

fn header_value(r: &mut Rng) -> Vec<u8> {
    match r.below(12) {
        0 => b"".to_vec(),
        1 => b"a\tb".to_vec(),
        2 => b"\xc3\xa9t\xe9".to_vec(),
        3 => b"x\x00y".to_vec(),
        4 => b"x\x7fy".to_vec(),
        5 => b"  padded  ".to_vec(),
        6 => {
            let n = *r.pick(&[100usize, 4000, 9000, 20000]);
            vec![b'v'; n]
        }
        7 => b"x\ry".to_vec(),
        _ => b"value".to_vec(),
    }
}

fn header_line(r: &mut Rng, e: &[u8]) -> Vec<u8> {
    let mut h: Vec<u8> = match r.below(24) {
        0 => b"Connection: close".to_vec(),
        1 => b"Connection: keep-alive".to_vec(),
        2 => b"Connection: upgrade".to_vec(),
        3 => b"Expect: 100-continue".to_vec(),
        4 => b"Upgrade: websocket".to_vec(),
        5 => b"Upgrade: h2c".to_vec(),
        6 => b"TE: trailers".to_vec(),
        7 => b"Bad Name: v".to_vec(),
        8 => b": empty-name".to_vec(),
        9 => b"Name : v".to_vec(),
        10 => b"NoColon".to_vec(),
        11 => {
            let mut v = b"X-Fold: a".to_vec();
            v.extend_from_slice(e);
            v.extend_from_slice(b" b");
            v
        }
        12 => b"x\x00y: v".to_vec(),
        13 => b"Host: other.example".to_vec(),
        14 => b"Trailer: x-t".to_vec(),
        15 => b"Keep-Alive: timeout=5".to_vec(),
        16 => b"Content-Type: text/plain".to_vec(),
        _ => {
            let mut v = format!("X-H{}: ", r.below(1000)).into_bytes();
            v.extend(header_value(r));
            v
        }
    };
    h.extend_from_slice(e);
    h
}

fn chunked_body(r: &mut Rng, e: &[u8]) -> Vec<u8> {
    let mut b = Vec::new();
    for _ in 0..r.below(4) {
        let n = *r.pick(&[1usize, 5, 16, 100, 300, 0]);
        if n == 0 {
            continue;
        }
        let size = match r.below(16) {
            0 => format!("{n:X}").into_bytes(),
            1 => format!("000{n:x}").into_bytes(),
            2 => format!("{n:x};ext=1").into_bytes(),
            3 => format!("{n:x} ").into_bytes(),
            4 => b"5g".to_vec(),
            5 => b"1ffffffffffffffff".to_vec(),
            6 => format!("{n:x};a\nb").into_bytes(),
            7 => b"".to_vec(),
            _ => format!("{n:x}").into_bytes(),
        };
        b.extend(size);
        b.extend_from_slice(e);
        b.extend(std::iter::repeat(b'd').take(n));
        if !r.pct(4) {
            b.extend_from_slice(e);
        }
    }
    if r.pct(92) {
        b.extend_from_slice(b"0");
        b.extend_from_slice(e);
        if r.pct(25) {
            for _ in 0..1 + r.below(2) {
                b.extend(r.pick(&[&b"X-T: v"[..], b"Host: x", b"Bad Trailer", b"x-t: 1", b"Content-Length: 5"]).iter());
                b.extend_from_slice(e);
            }
        }
        b.extend_from_slice(e);
    }
    b
}

pub fn request(r: &mut Rng) -> Vec<u8> {
    let method = r.wpick(METHODS).to_vec();
    let e = eol(r);
    let mut out = method.clone();
    let sp: &[u8] = *r.wpick(&[(95, &b" "[..]), (3, b"  "), (1, b"\t"), (1, b"")]);
    out.extend_from_slice(sp);
    out.extend(target(r, &method));
    out.extend_from_slice(sp);
    out.extend_from_slice(r.wpick(VERSIONS));
    out.extend_from_slice(e);
    if r.pct(85) {
        out.extend_from_slice(b"Host: example.com");
        out.extend_from_slice(e);
    }
    let framing = match r.below(20) {
        0..=8 => Framing::None,
        9..=13 => {
            let n = *r.pick(&[0usize, 1, 5, 10, 100, 1000]);
            let v = cl_value(r, n);
            Framing::Length(n, v)
        }
        14..=17 => Framing::Chunked(te_value(r)),
        _ => {
            let n = *r.pick(&[0usize, 5, 10]);
            Framing::Both(n, te_value(r))
        }
    };
    let mut hdrs: Vec<Vec<u8>> = Vec::new();
    for _ in 0..r.below(5) {
        hdrs.push(header_line(r, e));
    }
    if r.pct(2) {
        for i in 0..50 + r.below(80) {
            let mut h = format!("X-Many-{i}: v").into_bytes();
            h.extend_from_slice(e);
            hdrs.push(h);
        }
    }
    let mut body = Vec::new();
    match &framing {
        Framing::None => {}
        Framing::Length(n, v) => {
            let mut h = b"Content-Length: ".to_vec();
            h.extend_from_slice(v);
            h.extend_from_slice(e);
            hdrs.push(h);
            if r.pct(10) {
                let mut h = b"Content-Length: ".to_vec();
                h.extend(cl_value(r, *n));
                h.extend_from_slice(e);
                hdrs.push(h);
            }
            // exact, shorter or longer than declared
            let len = match r.below(10) {
                0 => n / 2,
                1 => n + 3,
                _ => *n,
            };
            body.extend(std::iter::repeat(b'b').take(len));
        }
        Framing::Chunked(te) => {
            let mut h = b"Transfer-Encoding: ".to_vec();
            h.extend_from_slice(te);
            h.extend_from_slice(e);
            hdrs.push(h);
            body = chunked_body(r, e);
        }
        Framing::Both(n, te) => {
            let mut h = format!("Content-Length: {n}").into_bytes();
            h.extend_from_slice(e);
            hdrs.push(h);
            let mut h = b"Transfer-Encoding: ".to_vec();
            h.extend_from_slice(te);
            h.extend_from_slice(e);
            hdrs.push(h);
            body = chunked_body(r, e);
        }
    }
    // shuffle header order a little
    if hdrs.len() > 1 && r.pct(50) {
        let i = r.below(hdrs.len());
        let j = r.below(hdrs.len());
        hdrs.swap(i, j);
    }
    for h in hdrs {
        out.extend(h);
    }
    out.extend_from_slice(if r.pct(97) { e } else { b"" });
    out.extend(body);
    out
}

const INTERESTING: &[u8] = b"\r\n\0 :\t\x7f\xffa0f;/-,\"";

pub fn mutate(r: &mut Rng, src: &[u8]) -> Vec<u8> {
    let mut b = src.to_vec();
    for _ in 0..1 + r.below(4) {
        if b.is_empty() {
            b.push(*r.pick(INTERESTING));
            continue;
        }
        let i = r.below(b.len());
        match r.below(6) {
            0 => b[i] = *r.pick(INTERESTING),
            1 => b.insert(i, *r.pick(INTERESTING)),
            2 => {
                b.remove(i);
            }
            3 => {
                let j = (i + 1 + r.below(16)).min(b.len());
                let s: Vec<u8> = b[i..j].to_vec();
                b.splice(i..i, s);
            }
            4 => b.truncate(i),
            _ => b[i] = (r.next() & 0xff) as u8,
        }
    }
    b
}

/// One generated stream.
pub fn stream(r: &mut Rng, corpus: &[Vec<u8>]) -> (Vec<u8>, &'static str) {
    let kind = r.below(100);
    if kind < 50 || corpus.is_empty() {
        let n = *r.wpick(&[(50, 1usize), (25, 2), (15, 3), (10, 5)]);
        let mut s = Vec::new();
        for _ in 0..n {
            s.extend(request(r));
        }
        if r.pct(5) {
            s.extend_from_slice(H2_PREFACE);
        }
        (s, "grammar")
    } else if kind < 60 {
        let mut s = request(r);
        s = mutate(r, &s);
        if r.pct(30) {
            s.extend(request(r));
        }
        (s, "grammar-mutated")
    } else if kind < 82 {
        let src = r.pick(corpus).clone();
        (mutate(r, &src), "corpus-mutated")
    } else if kind < 92 {
        (r.pick(corpus).clone(), "corpus")
    } else if kind < 96 {
        let mut s = request(r);
        s.extend(r.pick(corpus).iter());
        (s, "splice")
    } else {
        let mut s = Vec::new();
        match r.below(4) {
            0 => {
                s.extend_from_slice(H2_PREFACE);
                s.extend_from_slice(H2_SETTINGS);
            }
            1 => s.extend_from_slice(&H2_PREFACE[..1 + r.below(H2_PREFACE.len() - 1)]),
            2 => {
                s.extend(request(r));
                s.extend_from_slice(H2_PREFACE);
            }
            _ => {
                let mut p = H2_PREFACE.to_vec();
                p.extend_from_slice(H2_SETTINGS);
                s = mutate(r, &p);
            }
        }
        (s, "h2-preface")
    }
}

/// The write plan of a stream: pieces with a gap (ms) before each, and
/// whether the client half-closes after the last piece.
pub struct Plan {
    pub pieces: Vec<(Vec<u8>, u64)>,
    pub half_close: bool,
}

pub fn plan(r: &mut Rng, data: &[u8]) -> Plan {
    let mut pieces = Vec::new();
    let mut p = 0;
    let big = data.len() > 16384;
    while p < data.len() {
        let n = if big {
            1 + r.below(16384)
        } else {
            match r.below(4) {
                0 => 1,
                1 => 1 + r.below(8),
                2 => 1 + r.below(64),
                _ => 1 + r.below(4096),
            }
        };
        let end = (p + n).min(data.len());
        let gap = if r.pct(30) { 0 } else { r.below(6) as u64 };
        pieces.push((data[p..end].to_vec(), gap));
        p = end;
        if pieces.len() >= 40 {
            // at most 40 pieces: the rest in one write
            if p < data.len() {
                pieces.push((data[p..].to_vec(), r.below(6) as u64));
            }
            break;
        }
    }
    Plan { pieces, half_close: r.pct(30) }
}
