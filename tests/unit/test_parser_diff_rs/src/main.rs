//! Differential oracle for bearings.http1.parser.
//! Usage: test_parser_diff_rs <corpus>
//! Corpus: repeated (u32 little-endian length, bytes).
//! For each case prints one line per configuration (see CONFIGS), in the
//! format that tests/unit/test_parser_diff.pas prints for the Pascal port.
use std::io::Write;

fn off(base: &[u8], s: &[u8]) -> usize {
    s.as_ptr() as usize - base.as_ptr() as usize
}

fn opt_slice(base: &[u8], s: Option<&str>) -> String {
    match s {
        Some(s) => format!("{},{}", off(base, s.as_bytes()), s.len()),
        None => "-".to_string(),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("corpus path");
    let data = std::fs::read(path).expect("read corpus");
    let stdout = std::io::stdout();
    let mut w = std::io::BufWriter::new(stdout.lock());
    let mut pos = 0usize;
    let mut case = 0usize;
    while pos < data.len() {
        let n = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        let buf = &data[pos..pos + n];
        pos += n;
        // cfg 0..7: bit0 allow_multiple_spaces_in_request_line_delimiters,
        // bit1 allow_space_before_first_header_name,
        // bit2 ignore_invalid_headers_in_requests; 4 header slots.
        // cfg 8: default config, 1 header slot.
        for cfg in 0..9u32 {
            let mut c = httparse::ParserConfig::default();
            let flags = if cfg == 8 { 0 } else { cfg };
            c.allow_multiple_spaces_in_request_line_delimiters(flags & 1 != 0);
            c.allow_space_before_first_header_name(flags & 2 != 0);
            c.ignore_invalid_headers_in_requests(flags & 4 != 0);
            let slots = if cfg == 8 { 1 } else { 4 };
            let mut headers = [httparse::EMPTY_HEADER; 4];
            let mut req = httparse::Request::new(&mut headers[..slots]);
            let r = c.parse_request(&mut req, buf);
            let line = format!(
                "m={} p={} v={}",
                opt_slice(buf, req.method),
                opt_slice(buf, req.path),
                match req.version { Some(v) => v.to_string(), None => "-".to_string() }
            );
            match r {
                Ok(httparse::Status::Complete(len)) => {
                    write!(w, "{} {} C {} {} h={}", case, cfg, len, line, req.headers.len()).unwrap();
                    for h in req.headers.iter() {
                        write!(w, " {},{}:{},{}", off(buf, h.name.as_bytes()), h.name.len(),
                               off(buf, h.value), h.value.len()).unwrap();
                    }
                    writeln!(w).unwrap();
                }
                Ok(httparse::Status::Partial) => {
                    writeln!(w, "{} {} P {}", case, cfg, line).unwrap();
                }
                Err(e) => {
                    writeln!(w, "{} {} E {:?} {}", case, cfg, e, line).unwrap();
                }
            }
        }
        // httparse::parse_headers with 4 slots.
        let mut headers = [httparse::EMPTY_HEADER; 4];
        match httparse::parse_headers(buf, &mut headers) {
            Ok(httparse::Status::Complete((len, hs))) => {
                write!(w, "{} H C {} h={}", case, len, hs.len()).unwrap();
                for h in hs.iter() {
                    write!(w, " {},{}:{},{}", off(buf, h.name.as_bytes()), h.name.len(),
                           off(buf, h.value), h.value.len()).unwrap();
                }
                writeln!(w).unwrap();
            }
            Ok(httparse::Status::Partial) => writeln!(w, "{} H P", case).unwrap(),
            Err(e) => writeln!(w, "{} H E {:?}", case, e).unwrap(),
        }
        case += 1;
    }
}
