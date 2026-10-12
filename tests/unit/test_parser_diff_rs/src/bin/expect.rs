//! Test tooling only (never shipped). Oracle for test_parser_extra_check.py:
//! runs the real httparse 1.10.1 on cases read from stdin.
// stdin lines: <R|H> <flags> <slots> <hex bytes>.  R = parse_request with the
// config below, H = parse_headers.  Prints one result line per input line, in
// the format of TTestParserExtra.ReqLine / HdrsLine (test_parser_extra.pas).
// flags bit0 allow_multiple_spaces_in_request_line_delimiters,
// bit1 allow_space_before_first_header_name, bit2 ignore_invalid_headers_in_requests,
// bit3 allow_spaces_after_header_name_in_responses, bit4 ignore_invalid_headers_in_responses,
// bit5 allow_obsolete_multiline_headers_in_responses,
// bit6 allow_multiple_spaces_in_response_status_delimiters.
use std::io::{BufRead, Write};
fn off(base: &[u8], s: &[u8]) -> usize { s.as_ptr() as usize - base.as_ptr() as usize }
fn opt(base: &[u8], s: Option<&str>) -> String {
    match s { Some(s) => format!("{},{}", off(base, s.as_bytes()), s.len()), None => "-".into() }
}
fn hexd(s: &str) -> Vec<u8> { (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i+2], 16).unwrap()).collect() }
fn main() {
    let stdin = std::io::stdin();
    let mut w = std::io::BufWriter::new(std::io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        let f: Vec<&str> = line.split(' ').collect();
        let flags: u32 = f[1].parse().unwrap();
        let slots: usize = f[2].parse().unwrap();
        let buf = hexd(if f.len() > 3 { f[3] } else { "" });
        let mut headers = vec![httparse::EMPTY_HEADER; slots];
        if f[0] == "R" {
            let mut c = httparse::ParserConfig::default();
            c.allow_multiple_spaces_in_request_line_delimiters(flags & 1 != 0);
            c.allow_space_before_first_header_name(flags & 2 != 0);
            c.ignore_invalid_headers_in_requests(flags & 4 != 0);
            c.allow_spaces_after_header_name_in_responses(flags & 8 != 0);
            c.ignore_invalid_headers_in_responses(flags & 16 != 0);
            c.allow_obsolete_multiline_headers_in_responses(flags & 32 != 0);
            c.allow_multiple_spaces_in_response_status_delimiters(flags & 64 != 0);
            let mut req = httparse::Request::new(&mut headers[..]);
            let r = c.parse_request(&mut req, &buf);
            let l = format!("m={} p={} v={}", opt(&buf, req.method), opt(&buf, req.path),
                match req.version { Some(v) => v.to_string(), None => "-".into() });
            match r {
                Ok(httparse::Status::Complete(n)) => {
                    write!(w, "C {} {} h={}", n, l, req.headers.len()).unwrap();
                    for h in req.headers.iter() {
                        write!(w, " {},{}:{},{}", off(&buf, h.name.as_bytes()), h.name.len(), off(&buf, h.value), h.value.len()).unwrap();
                    }
                    writeln!(w).unwrap();
                }
                Ok(httparse::Status::Partial) => writeln!(w, "P {}", l).unwrap(),
                Err(e) => writeln!(w, "E {:?} {}", e, l).unwrap(),
            }
        } else {
            match httparse::parse_headers(&buf, &mut headers) {
                Ok(httparse::Status::Complete((n, hs))) => {
                    write!(w, "C {} h={}", n, hs.len()).unwrap();
                    for h in hs.iter() {
                        write!(w, " {},{}:{},{}", off(&buf, h.name.as_bytes()), h.name.len(), off(&buf, h.value), h.value.len()).unwrap();
                    }
                    writeln!(w).unwrap();
                }
                Ok(httparse::Status::Partial) => writeln!(w, "P").unwrap(),
                Err(e) => writeln!(w, "E {:?}", e).unwrap(),
            }
        }
    }
}
