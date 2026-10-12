//! Capture normalization, step assertions and event pattern matching
//! (SPEC.md "Assertions", "Normalization", "Event patterns").

use crate::conn::End;
use crate::response::Parsed;
use harness_common::{check_keys, decode_bytes, latin1, substitute, Vars};
use regex::bytes::Regex;
use serde_json::{Map, Value};
use std::sync::OnceLock;

/// Every IMF-fixdate value of a `date` field is replaced by this value
/// (same length, so byte counts are unchanged).
pub const CANONICAL_DATE: &str = "Sun, 06 Nov 1994 08:49:37 GMT";

fn date_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i-u)(\r\ndate:[ \t]*)(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT",
        )
        .unwrap()
    })
}

pub fn normalize(b: &[u8]) -> Vec<u8> {
    date_re()
        .replace_all(b, |c: &regex::bytes::Captures<'_>| {
            let mut v = c[1].to_vec();
            v.extend_from_slice(CANONICAL_DATE.as_bytes());
            v
        })
        .into_owned()
}

pub struct Capture<'a> {
    pub raw: &'a [u8],
    pub norm: &'a [u8],
    pub end: End,
    pub resp: Option<&'a Parsed>,
    /// read_once only: "data", "eof", "reset" or "timeout".
    pub read_result: Option<&'static str>,
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

pub fn show(b: &[u8], limit: usize) -> String {
    let mut s = String::new();
    for &c in b.iter().take(limit) {
        match c {
            b'\r' => s.push_str("\\r"),
            b'\n' => s.push_str("\\n"),
            b'\t' => s.push_str("\\t"),
            b'\\' => s.push_str("\\\\"),
            b'"' => s.push_str("\\\""),
            0x20..=0x7e => s.push(c as char),
            _ => s.push_str(&format!("\\x{c:02x}")),
        }
    }
    if b.len() > limit {
        s.push_str(&format!("... ({} bytes total)", b.len()));
    }
    format!("\"{s}\"")
}

const BYTE_KINDS: &[&str] = &[
    "equals", "starts_with", "ends_with", "contains", "not_contains", "regex", "not_regex", "len",
    "min_len", "max_len",
];
const OTHER_KINDS: &[&str] = &[
    "end", "read_result", "status", "reason", "version", "framing", "header", "trailer", "body",
];
const READ_RESULTS: &[&str] = &["data", "eof", "reset", "timeout"];
const MODIFIERS: &[&str] = &["scope", "ci", "raw", "comment"];

fn lower(b: &[u8]) -> Vec<u8> {
    b.to_ascii_lowercase()
}

/// Check one assertion object against a step capture.
pub fn check(a: &Value, cap: &Capture<'_>, vars: &Vars) -> Result<(), String> {
    let m = a.as_object().ok_or_else(|| format!("assertion must be an object: {a}"))?;
    let kinds: Vec<&String> = m
        .keys()
        .filter(|k| BYTE_KINDS.contains(&k.as_str()) || OTHER_KINDS.contains(&k.as_str()))
        .collect();
    if kinds.len() != 1 {
        return Err(format!("assertion needs exactly one kind key, found {a}"));
    }
    let kind = kinds[0].as_str();
    match kind {
        "header" | "trailer" => check_field(kind, m, cap, vars),
        _ => {
            let mut allowed: Vec<&str> = MODIFIERS.to_vec();
            allowed.push(kind);
            check_keys(m, &allowed)?;
            check_simple(kind, &m[kind], m, cap, vars)
        }
    }
}

fn need_resp<'a>(cap: &'a Capture<'_>, kind: &str) -> Result<&'a Parsed, String> {
    cap.resp
        .ok_or_else(|| format!("assertion {kind:?} is only valid on a read_response step"))
}

fn check_simple(kind: &str, v: &Value, m: &Map<String, Value>, cap: &Capture<'_>, vars: &Vars) -> Result<(), String> {
    match kind {
        "end" => {
            let want = v.as_str().ok_or("end: expected a string")?;
            let ok = match want {
                "eof" => cap.end == End::Eof,
                "reset" => cap.end == End::Reset,
                "open" => cap.end == End::Open,
                "closed" => cap.end != End::Open,
                other => return Err(format!("end: unknown value {other:?}")),
            };
            return if ok {
                Ok(())
            } else {
                Err(format!("expected end {want:?}, connection state is {:?}", cap.end.as_str()))
            };
        }
        "read_result" => {
            let got = cap
                .read_result
                .ok_or("assertion \"read_result\" is only valid on a read_once step")?;
            let want: Vec<&str> = match v {
                Value::String(w) => vec![w.as_str()],
                Value::Array(a) => a
                    .iter()
                    .map(|x| x.as_str().ok_or("read_result: expected a string or an array of strings"))
                    .collect::<Result<_, _>>()?,
                _ => return Err("read_result: expected a string or an array of strings".into()),
            };
            if want.is_empty() {
                return Err("read_result: the array must not be empty".into());
            }
            for w in &want {
                if !READ_RESULTS.contains(w) {
                    return Err(format!("read_result: unknown value {w:?} (expected one of {READ_RESULTS:?})"));
                }
            }
            return if want.contains(&got) {
                Ok(())
            } else {
                Err(format!("expected read_result in {want:?}, got {got:?}"))
            };
        }
        "status" => {
            let r = need_resp(cap, kind)?;
            let want = v.as_u64().ok_or("status: expected an integer")?;
            return if r.status as u64 == want {
                Ok(())
            } else {
                Err(format!("expected status {want}, got {}", r.status))
            };
        }
        "reason" => {
            let r = need_resp(cap, kind)?;
            let want = decode_bytes(v, Some(vars))?;
            return if r.reason == want {
                Ok(())
            } else {
                Err(format!("expected reason {}, got {}", show(&want, 200), show(&r.reason, 200)))
            };
        }
        "version" => {
            let r = need_resp(cap, kind)?;
            let want = v.as_str().ok_or("version: expected a string")?;
            return if r.version == want {
                Ok(())
            } else {
                Err(format!("expected version {want:?}, got {:?}", r.version))
            };
        }
        "framing" => {
            let r = need_resp(cap, kind)?;
            let want = v.as_str().ok_or("framing: expected a string")?;
            return if r.framing == want {
                Ok(())
            } else {
                Err(format!("expected framing {want:?}, got {:?}", r.framing))
            };
        }
        "body" => {
            let r = need_resp(cap, kind)?;
            let want = decode_bytes(v, Some(vars))?;
            return if r.body == want {
                Ok(())
            } else {
                Err(format!("expected decoded body {}, got {}", show(&want, 400), show(&r.body, 400)))
            };
        }
        _ => {}
    }

    // Byte kinds, on the selected scope.
    let raw = m.get("raw").and_then(Value::as_bool).unwrap_or(false);
    let base: &[u8] = if raw { cap.raw } else { cap.norm };
    let scope = m.get("scope").and_then(Value::as_str).unwrap_or("all");
    let subject: &[u8] = match scope {
        "all" => base,
        "head" => match find(base, b"\r\n\r\n") {
            Some(p) => &base[..p],
            None => base,
        },
        "after_head" => match find(base, b"\r\n\r\n") {
            Some(p) => &base[p + 4..],
            None => &base[base.len()..],
        },
        "body" => &need_resp(cap, "scope body")?.body,
        other => return Err(format!("unknown scope {other:?}")),
    };
    let ci = m.get("ci").and_then(Value::as_bool).unwrap_or(false);
    let where_ = if scope == "all" { String::new() } else { format!(" (scope {scope})") };

    match kind {
        "len" | "min_len" | "max_len" => {
            let n = v.as_u64().ok_or_else(|| format!("{kind}: expected an integer"))? as usize;
            let got = subject.len();
            let ok = match kind {
                "len" => got == n,
                "min_len" => got >= n,
                _ => got <= n,
            };
            if ok {
                Ok(())
            } else {
                Err(format!("expected {kind} {n}{where_}, got length {got}: {}", show(subject, 300)))
            }
        }
        "regex" | "not_regex" => {
            let pat = v.as_str().ok_or_else(|| format!("{kind}: expected a string"))?;
            let pat = substitute(pat, Some(vars))?;
            let pat = if ci { format!("(?i){pat}") } else { pat };
            let re = Regex::new(&format!("(?-u){pat}")).map_err(|e| format!("bad regex: {e}"))?;
            let hit = re.is_match(subject);
            if hit == (kind == "regex") {
                Ok(())
            } else {
                Err(format!(
                    "expected {}match of regex {}{where_} in {}",
                    if kind == "regex" { "" } else { "no " },
                    show(pat.as_bytes(), 300),
                    show(subject, 600)
                ))
            }
        }
        _ => {
            let want = decode_bytes(v, Some(vars))?;
            let (s, w) = if ci { (lower(subject), lower(&want)) } else { (subject.to_vec(), want.clone()) };
            let ok = match kind {
                "equals" => s == w,
                "starts_with" => s.starts_with(&w),
                "ends_with" => s.ends_with(&w),
                "contains" => find(&s, &w).is_some(),
                "not_contains" => find(&s, &w).is_none(),
                _ => unreachable!(),
            };
            if ok {
                Ok(())
            } else {
                Err(format!(
                    "expected {kind} {}{where_}{}, got {}",
                    show(&want, 300),
                    if ci { " (case-insensitive)" } else { "" },
                    show(subject, 800)
                ))
            }
        }
    }
}

fn check_field(kind: &str, m: &Map<String, Value>, cap: &Capture<'_>, vars: &Vars) -> Result<(), String> {
    check_keys(m, &[kind, "value", "values", "present", "count", "comment"])?;
    let r = need_resp(cap, kind)?;
    let name = m[kind].as_str().ok_or_else(|| format!("{kind}: expected a field name string"))?;
    let vals = if kind == "header" { r.header_values(name) } else { r.trailer_values(name) };
    let mut checked = false;
    if let Some(p) = m.get("present") {
        checked = true;
        let p = p.as_bool().ok_or("present: expected a boolean")?;
        if p != !vals.is_empty() {
            return Err(format!(
                "expected {kind} {name:?} to be {}; fields: {}",
                if p { "present" } else { "absent" },
                fields_show(if kind == "header" { &r.headers } else { &r.trailers })
            ));
        }
    }
    if let Some(c) = m.get("count") {
        checked = true;
        let c = c.as_u64().ok_or("count: expected an integer")? as usize;
        if vals.len() != c {
            return Err(format!("expected {c} {kind} field(s) {name:?}, found {}", vals.len()));
        }
    }
    if let Some(v) = m.get("value") {
        checked = true;
        let want = decode_bytes(v, Some(vars))?;
        match vals.first() {
            Some(got) if *got == want.as_slice() => {}
            Some(got) => {
                return Err(format!("expected {kind} {name:?} = {}, got {}", show(&want, 200), show(got, 200)))
            }
            None => return Err(format!("expected {kind} {name:?} = {}, field absent", show(&want, 200))),
        }
    }
    if let Some(vs) = m.get("values") {
        checked = true;
        let arr = vs.as_array().ok_or("values: expected an array")?;
        let want: Vec<Vec<u8>> = arr
            .iter()
            .map(|v| decode_bytes(v, Some(vars)))
            .collect::<Result<_, _>>()?;
        let got: Vec<Vec<u8>> = vals.iter().map(|v| v.to_vec()).collect();
        if want != got {
            return Err(format!(
                "expected {kind} {name:?} values {:?}, got {:?}",
                want.iter().map(|v| latin1(v)).collect::<Vec<_>>(),
                got.iter().map(|v| latin1(v)).collect::<Vec<_>>()
            ));
        }
    }
    if !checked {
        return Err(format!("{kind} assertion needs one of value, values, present, count"));
    }
    Ok(())
}

fn fields_show(f: &[(String, Vec<u8>)]) -> String {
    f.iter()
        .map(|(n, v)| format!("{n}: {}", latin1(v)))
        .collect::<Vec<_>>()
        .join(" | ")
}

// ---------------------------------------------------------------------------
// Event patterns
// ---------------------------------------------------------------------------

/// Match an event (or any JSON value) against a pattern. See SPEC.md.
pub fn matches(pat: &Value, act: Option<&Value>, vars: &Vars) -> Result<bool, String> {
    if let Value::Object(pm) = pat {
        if pm.len() == 1 {
            let (k, arg) = pm.iter().next().unwrap();
            if k.starts_with('$') {
                return match_op(k, arg, act, vars);
            }
        }
        let am = match act {
            Some(Value::Object(am)) => am,
            _ => return Ok(false),
        };
        for (k, pv) in pm {
            if !matches(pv, am.get(k), vars)? {
                return Ok(false);
            }
        }
        return Ok(true);
    }
    let act = match act {
        Some(a) => a,
        None => return Ok(false),
    };
    Ok(match (pat, act) {
        (Value::String(p), Value::String(a)) => substitute(p, Some(vars))? == *a,
        (Value::Array(p), Value::Array(a)) => {
            if p.len() != a.len() {
                return Ok(false);
            }
            for (pe, ae) in p.iter().zip(a) {
                if !matches(pe, Some(ae), vars)? {
                    return Ok(false);
                }
            }
            true
        }
        (p, a) => p == a,
    })
}

fn match_op(op: &str, arg: &Value, act: Option<&Value>, vars: &Vars) -> Result<bool, String> {
    match op {
        "$absent" => Ok(act.is_none()),
        "$any" => Ok(act.is_some()),
        "$not" => Ok(!matches(arg, act, vars)?),
        "$bytes" => {
            let want = latin1(&decode_bytes(arg, Some(vars))?);
            Ok(matches!(act, Some(Value::String(a)) if *a == want))
        }
        "$contains" => {
            let want = latin1(&decode_bytes(arg, Some(vars))?);
            Ok(matches!(act, Some(Value::String(a)) if a.contains(&want)))
        }
        "$regex" => {
            let p = substitute(arg.as_str().ok_or("$regex: expected a string")?, Some(vars))?;
            let re = regex::Regex::new(&p).map_err(|e| format!("bad regex: {e}"))?;
            Ok(matches!(act, Some(Value::String(a)) if re.is_match(a)))
        }
        "$includes" => {
            let want = arg.as_array().ok_or("$includes: expected an array")?;
            let have = match act {
                Some(Value::Array(a)) => a,
                _ => return Ok(false),
            };
            for w in want {
                let mut found = false;
                for h in have {
                    if matches(w, Some(h), vars)? {
                        found = true;
                        break;
                    }
                }
                if !found {
                    return Ok(false);
                }
            }
            Ok(true)
        }
        other => Err(format!("unknown pattern operator {other}")),
    }
}
