//! Shared helpers for the conformance harness: the "bytes spec" encoding used
//! in case files and the latin-1 byte <-> JSON string mapping used in events.
//! See SPEC.md section "Byte strings".

use serde_json::Value;
use std::collections::HashMap;

/// Map each byte to the Unicode code point with the same value (latin-1).
pub fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

/// Inverse of [`latin1`]. Fails on code points above U+00FF.
pub fn from_latin1(s: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(s.len());
    for c in s.chars() {
        let cp = c as u32;
        if cp > 0xFF {
            return Err(format!(
                "byte string contains code point U+{cp:04X} (> U+00FF); use \\u00XX escapes for bytes"
            ));
        }
        out.push(cp as u8);
    }
    Ok(out)
}

/// Variables available for `${name}` substitution in runner-side byte strings.
pub type Vars = HashMap<String, String>;

/// Substitute `${name}` in `s`. `$${` produces a literal `${`.
/// With `vars == None` no substitution is done.
pub fn substitute(s: &str, vars: Option<&Vars>) -> Result<String, String> {
    let vars = match vars {
        Some(v) => v,
        None => return Ok(s.to_string()),
    };
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find('$') {
        out.push_str(&rest[..pos]);
        let tail = &rest[pos..];
        if tail.starts_with("$${") {
            out.push_str("${");
            rest = &tail[3..];
        } else if tail.starts_with("${") {
            let end = tail
                .find('}')
                .ok_or_else(|| format!("unterminated ${{...}} in {s:?}"))?;
            let name = &tail[2..end];
            let val = vars
                .get(name)
                .ok_or_else(|| format!("unknown variable ${{{name}}} in {s:?}"))?;
            out.push_str(val);
            rest = &tail[end + 1..];
        } else {
            out.push('$');
            rest = &tail[1..];
        }
    }
    out.push_str(rest);
    Ok(out)
}

/// Decode a bytes spec (SPEC.md "Byte strings"):
/// - a JSON string: each code point U+0000..U+00FF is one byte;
/// - an array of parts, concatenated, where a part is a string,
///   `{"repeat": <bytes spec>, "count": n}` or `{"hex": "0a0b..."}`.
pub fn decode_bytes(v: &Value, vars: Option<&Vars>) -> Result<Vec<u8>, String> {
    match v {
        Value::String(s) => from_latin1(&substitute(s, vars)?),
        Value::Array(parts) => {
            let mut out = Vec::new();
            for p in parts {
                out.extend(decode_part(p, vars)?);
            }
            Ok(out)
        }
        Value::Object(_) => decode_part(v, vars),
        other => Err(format!("expected a byte string, found {other}")),
    }
}

fn decode_part(p: &Value, vars: Option<&Vars>) -> Result<Vec<u8>, String> {
    match p {
        Value::String(_) => decode_bytes(p, vars),
        Value::Object(m) => {
            if let Some(r) = m.get("repeat") {
                check_keys(m, &["repeat", "count"])?;
                let unit = decode_bytes(r, vars)?;
                let count = m
                    .get("count")
                    .and_then(Value::as_u64)
                    .ok_or("repeat part needs an integer \"count\"")?;
                Ok(unit.repeat(count as usize))
            } else if let Some(h) = m.get("hex") {
                check_keys(m, &["hex"])?;
                let h = h.as_str().ok_or("\"hex\" must be a string")?;
                decode_hex(h)
            } else {
                Err(format!("unknown byte-string part {p}"))
            }
        }
        other => Err(format!("unknown byte-string part {other}")),
    }
}

fn decode_hex(h: &str) -> Result<Vec<u8>, String> {
    let digits: Vec<u8> = h.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if digits.len() % 2 != 0 {
        return Err(format!("odd number of hex digits in {h:?}"));
    }
    let val = |c: u8| -> Result<u8, String> {
        (c as char)
            .to_digit(16)
            .map(|d| d as u8)
            .ok_or_else(|| format!("invalid hex digit {:?}", c as char))
    };
    digits
        .chunks(2)
        .map(|pair| Ok(val(pair[0])? << 4 | val(pair[1])?))
        .collect()
}

/// Fail if `m` has a key outside `allowed`.
pub fn check_keys(m: &serde_json::Map<String, Value>, allowed: &[&str]) -> Result<(), String> {
    for k in m.keys() {
        if !allowed.contains(&k.as_str()) {
            return Err(format!(
                "unknown field {k:?} (allowed: {})",
                allowed.join(", ")
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn bytes_specs() {
        assert_eq!(decode_bytes(&json!("a\r\n"), None).unwrap(), b"a\r\n");
        assert_eq!(
            decode_bytes(&json!(["x", {"repeat": "ab", "count": 2}, {"hex": "00ff"}]), None).unwrap(),
            b"xabab\x00\xff"
        );
        assert_eq!(decode_bytes(&json!("\u{00ff}"), None).unwrap(), vec![0xff]);
        assert!(decode_bytes(&json!("\u{0100}"), None).is_err());
        let mut vars = Vars::new();
        vars.insert("port".into(), "8080".into());
        assert_eq!(
            decode_bytes(&json!("h:${port} $${port} $x"), Some(&vars)).unwrap(),
            b"h:8080 ${port} $x"
        );
        assert_eq!(decode_bytes(&json!("${port}"), None).unwrap(), b"${port}");
    }
}
