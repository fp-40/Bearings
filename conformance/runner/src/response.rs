//! Minimal, permissive HTTP/1.x response reader for the `read_response` step.
//! It frames one response per RFC 9112 section 6.3 so that following steps see
//! the bytes after it.

use crate::conn::{Conn, End, ReadOutcome};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Parsed {
    pub version: String,
    pub status: u16,
    pub reason: Vec<u8>,
    pub headers: Vec<(String, Vec<u8>)>,
    pub body: Vec<u8>,
    pub trailers: Vec<(String, Vec<u8>)>,
    /// "none" | "content-length" | "chunked" | "close"
    pub framing: &'static str,
    pub raw: Vec<u8>,
}

impl Parsed {
    pub fn header_values(&self, name: &str) -> Vec<&[u8]> {
        self.headers
            .iter()
            .filter(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_slice())
            .collect()
    }
    pub fn trailer_values(&self, name: &str) -> Vec<&[u8]> {
        self.trailers
            .iter()
            .filter(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_slice())
            .collect()
    }
}

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if from > hay.len() {
        return None;
    }
    hay[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + from)
}

fn trim_ows(v: &[u8]) -> &[u8] {
    let start = v.iter().position(|&b| b != b' ' && b != b'\t').unwrap_or(v.len());
    let end = v.iter().rposition(|&b| b != b' ' && b != b'\t').map(|p| p + 1).unwrap_or(start);
    &v[start..end.max(start)]
}

fn parse_fields(block: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut out = Vec::new();
    for line in block.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.is_empty() {
            continue;
        }
        let colon = line
            .iter()
            .position(|&b| b == b':')
            .ok_or_else(|| format!("malformed field line {:?}", String::from_utf8_lossy(line)))?;
        let name = String::from_utf8_lossy(&line[..colon]).into_owned();
        out.push((name, trim_ows(&line[colon + 1..]).to_vec()));
    }
    Ok(out)
}

/// Ok(None): need more bytes. `eof`: no more bytes will arrive.
fn try_parse(buf: &[u8], is_head: bool, eof: bool) -> Result<Option<(Parsed, usize)>, String> {
    let head_end = match find(buf, b"\r\n\r\n", 0) {
        Some(p) => p,
        None => {
            return if eof {
                Err("connection ended before a complete response head".into())
            } else {
                Ok(None)
            }
        }
    };
    let head = &buf[..head_end];
    let (status_line, rest) = match find(head, b"\r\n", 0) {
        Some(p) => (&head[..p], &head[p + 2..]),
        None => (head, &head[head.len()..]),
    };
    let mut parts = status_line.splitn(3, |&b| b == b' ');
    let version = String::from_utf8_lossy(parts.next().unwrap_or_default()).into_owned();
    let code = parts.next().unwrap_or_default();
    let reason = parts.next().unwrap_or_default().to_vec();
    if !version.starts_with("HTTP/") || code.len() != 3 || !code.iter().all(u8::is_ascii_digit) {
        return Err(format!(
            "malformed status line {:?}",
            String::from_utf8_lossy(status_line)
        ));
    }
    let status: u16 = std::str::from_utf8(code).unwrap().parse().unwrap();
    let headers = parse_fields(rest)?;
    let mut pos = head_end + 4;

    let values = |name: &str| -> Vec<Vec<u8>> {
        headers
            .iter()
            .filter(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.clone())
            .collect()
    };
    let mut parsed = Parsed {
        version,
        status,
        reason,
        headers: headers.clone(),
        body: Vec::new(),
        trailers: Vec::new(),
        framing: "none",
        raw: Vec::new(),
    };

    let te = values("transfer-encoding");
    let cl = values("content-length");
    if is_head || (100..200).contains(&status) || status == 204 || status == 304 {
        parsed.framing = "none";
    } else if !te.is_empty() {
        let joined = te.join(&b","[..]);
        let last = joined.rsplit(|&b| b == b',').next().map(trim_ows).unwrap_or_default();
        if last.eq_ignore_ascii_case(b"chunked") {
            parsed.framing = "chunked";
            loop {
                let line_end = match find(buf, b"\r\n", pos) {
                    Some(p) => p,
                    None => return incomplete(eof, "chunk size line"),
                };
                let line = &buf[pos..line_end];
                let size_part = line.split(|&b| b == b';').next().unwrap_or_default();
                let size_str = String::from_utf8_lossy(trim_ows(size_part)).into_owned();
                let size = u64::from_str_radix(&size_str, 16)
                    .map_err(|_| format!("invalid chunk size line {:?}", String::from_utf8_lossy(line)))?
                    as usize;
                pos = line_end + 2;
                if size == 0 {
                    // trailer section, ends with an empty line
                    let mut tpos = pos;
                    loop {
                        let le = match find(buf, b"\r\n", tpos) {
                            Some(p) => p,
                            None => return incomplete(eof, "trailer section"),
                        };
                        if le == tpos {
                            parsed.trailers = parse_fields(&buf[pos..tpos])?;
                            pos = le + 2;
                            break;
                        }
                        tpos = le + 2;
                    }
                    break;
                }
                if buf.len() < pos + size + 2 {
                    return incomplete(eof, "chunk data");
                }
                parsed.body.extend_from_slice(&buf[pos..pos + size]);
                if &buf[pos + size..pos + size + 2] != b"\r\n" {
                    return Err("chunk data not followed by CRLF".into());
                }
                pos += size + 2;
            }
        } else {
            parsed.framing = "close";
        }
    } else if !cl.is_empty() {
        let first = &cl[0];
        if cl.iter().any(|v| v != first) || first.is_empty() || !first.iter().all(u8::is_ascii_digit) {
            return Err(format!("invalid content-length {:?}", cl));
        }
        let n: usize = String::from_utf8_lossy(first)
            .parse()
            .map_err(|_| "content-length overflow".to_string())?;
        parsed.framing = "content-length";
        if buf.len() < pos + n {
            return incomplete(eof, "content-length body");
        }
        parsed.body.extend_from_slice(&buf[pos..pos + n]);
        pos += n;
    } else {
        parsed.framing = "close";
    }

    if parsed.framing == "close" {
        if !eof {
            return Ok(None);
        }
        parsed.body.extend_from_slice(&buf[pos..]);
        pos = buf.len();
    }
    parsed.raw = buf[..pos].to_vec();
    Ok(Some((parsed, pos)))
}

fn incomplete<T>(eof: bool, what: &str) -> Result<Option<T>, String> {
    if eof {
        Err(format!("connection ended in the middle of the {what}"))
    } else {
        Ok(None)
    }
}

/// Read one response. Returns the parsed response, the connection end state
/// and the instant the response was complete.
pub fn read_response(
    conn: &mut Conn,
    is_head: bool,
    timeout: Duration,
    allow_reset: bool,
) -> Result<(Parsed, End, Instant), String> {
    loop {
        let eof = conn.end != End::Open;
        if conn.end == End::Reset && !allow_reset {
            return Err("connection reset by peer (set allow_reset to accept)".into());
        }
        if let Some((p, used)) = try_parse(&conn.buf, is_head, eof)? {
            conn.buf.drain(..used);
            return Ok((p, conn.end, Instant::now()));
        }
        match conn.read_some(timeout)? {
            ReadOutcome::Data | ReadOutcome::Eof | ReadOutcome::Reset => {}
            ReadOutcome::Timeout => {
                return Err(format!(
                    "timed out after {} ms waiting for response bytes ({} buffered)",
                    timeout.as_millis(),
                    conn.buf.len()
                ))
            }
        }
    }
}
