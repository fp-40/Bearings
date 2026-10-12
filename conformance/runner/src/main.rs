//! Conformance runner. See ../SPEC.md.
//!
//!   runner run  [--server CMD] [--filter S] [-v] PATH...
//!   runner diff --a CMD --b CMD [--filter S] [-v] PATH...
//!   runner list [--filter S] PATH...

mod assert;
mod case;
mod conn;
mod proxy;
mod response;
mod server;
mod tokiort;

use case::{run_case, validate_case, CaseResult, Mode};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

struct Opts {
    cmd: String,
    server: Option<String>,
    a: Option<String>,
    b: Option<String>,
    filters: Vec<String>,
    verbose: bool,
    paths: Vec<PathBuf>,
}

fn usage() -> ! {
    eprintln!(
        "usage:\n  runner run  [--server CMD] [--filter S]... [-v] PATH...\n  \
         runner diff --a CMD --b CMD [--filter S]... [-v] PATH...\n  \
         runner list [--filter S]... PATH...\n\
         PATH is a case file or a directory searched recursively for *.json.\n\
         CMD is a shell command line; the runner appends `--config <file>`.\n\
         Default --server: the reference-server binary next to this runner."
    );
    std::process::exit(2);
}

fn parse_args() -> Opts {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_else(|| usage());
    let mut o = Opts {
        cmd,
        server: None,
        a: None,
        b: None,
        filters: vec![],
        verbose: false,
        paths: vec![],
    };
    while let Some(a) = args.next() {
        match a.as_str() {
            "--server" => o.server = Some(args.next().unwrap_or_else(|| usage())),
            "--a" => o.a = Some(args.next().unwrap_or_else(|| usage())),
            "--b" => o.b = Some(args.next().unwrap_or_else(|| usage())),
            "--filter" => o.filters.push(args.next().unwrap_or_else(|| usage())),
            "-v" | "--verbose" => o.verbose = true,
            "-h" | "--help" => usage(),
            s if s.starts_with('-') => {
                eprintln!("unknown option {s}");
                usage()
            }
            _ => o.paths.push(PathBuf::from(a)),
        }
    }
    if o.paths.is_empty() {
        usage();
    }
    o
}

fn default_server() -> String {
    let exe = std::env::current_exe().expect("current_exe");
    let p = exe.with_file_name("reference-server");
    shell_quote(&p.to_string_lossy())
}

fn shell_quote(s: &str) -> String {
    if s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+:=".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

fn collect_files(p: &Path, out: &mut Vec<PathBuf>) {
    if p.is_dir() {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(p)
            .unwrap_or_else(|e| {
                eprintln!("cannot read {}: {e}", p.display());
                std::process::exit(2)
            })
            .filter_map(|e| e.ok().map(|e| e.path()))
            .collect();
        entries.sort();
        for e in entries {
            if e.is_dir() || e.extension().map_or(false, |x| x == "json") {
                collect_files(&e, out);
            }
        }
    } else {
        out.push(p.to_path_buf());
    }
}

struct LoadedCase {
    id: String,
    case: Value,
    invalid: Option<String>,
}

fn load_cases(paths: &[PathBuf], filters: &[String]) -> Vec<LoadedCase> {
    let mut files = Vec::new();
    for p in paths {
        collect_files(p, &mut files);
    }
    let mut out = Vec::new();
    for f in files {
        let stem = f.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let text = match std::fs::read_to_string(&f) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("cannot read {}: {e}", f.display());
                std::process::exit(2)
            }
        };
        let doc: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("{}: invalid JSON: {e}", f.display());
                std::process::exit(2)
            }
        };
        let cases = match doc.get("cases").and_then(Value::as_array) {
            Some(c) => c.clone(),
            None => {
                eprintln!("{}: expected an object with a \"cases\" array", f.display());
                std::process::exit(2)
            }
        };
        let mut seen = std::collections::HashSet::new();
        for (i, c) in cases.into_iter().enumerate() {
            let name = c.get("name").and_then(Value::as_str).map(str::to_string).unwrap_or(format!("#{i}"));
            let id = format!("{stem}::{name}");
            let full = format!("{}::{name}", f.display());
            if !filters.is_empty() && !filters.iter().any(|flt| full.contains(flt.as_str())) {
                continue;
            }
            let mut invalid = validate_case(&c).err();
            if !seen.insert(name.clone()) {
                invalid = Some(format!("duplicate case name {name:?} in {}", f.display()));
            }
            out.push(LoadedCase { id, case: c, invalid });
        }
    }
    out
}

fn pending_reason(c: &Value) -> Option<String> {
    match c.get("pending") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(v) => Some(v.to_string()),
    }
}

fn print_failure(r: &CaseResult) {
    for f in &r.failures {
        println!("    {f}");
    }
    println!("    server events:");
    for e in &r.events {
        println!("      {e}");
    }
    let err = r.stderr.trim();
    if !err.is_empty() {
        println!("    server stderr (last 2000 bytes):");
        let tail = &err[err.len().saturating_sub(2000)..];
        for l in tail.lines() {
            println!("      {l}");
        }
    }
}

fn cmd_run(o: &Opts) -> i32 {
    let server = o.server.clone().unwrap_or_else(default_server);
    let cases = load_cases(&o.paths, &o.filters);
    let (mut passed, mut failed, mut pending) = (0, 0, 0);
    for lc in &cases {
        if let Some(e) = &lc.invalid {
            failed += 1;
            println!("FAIL {} (invalid case)\n    {e}", lc.id);
            continue;
        }
        if let Some(reason) = pending_reason(&lc.case) {
            pending += 1;
            println!("PEND {}: {reason}", lc.id);
            continue;
        }
        let r = run_case(&lc.case, &server, Mode::Assert, o.verbose);
        if r.failures.is_empty() {
            passed += 1;
            println!("PASS {} ({} ms)", lc.id, r.elapsed.as_millis());
            if o.verbose {
                for e in &r.events {
                    println!("      {e}");
                }
            }
        } else {
            failed += 1;
            println!("FAIL {} ({} ms)", lc.id, r.elapsed.as_millis());
            print_failure(&r);
        }
    }
    println!(
        "SUMMARY passed={passed} failed={failed} pending={pending} total={}",
        cases.len()
    );
    if failed > 0 {
        1
    } else {
        0
    }
}

/// Replace "127.0.0.1:<port>" for this run's ports with "127.0.0.1:${name}"
/// in every string, so runs on different ports compare equal.
fn scrub(v: &Value, vars: &harness_common::Vars) -> Value {
    match v {
        Value::String(s) => {
            let mut s = s.clone();
            for name in ["server_port", "proxy_port"] {
                if let Some(p) = vars.get(name) {
                    s = s.replace(&format!("127.0.0.1:{p}"), &format!("127.0.0.1:${{{name}}}"));
                }
            }
            Value::String(s)
        }
        Value::Array(a) => Value::Array(a.iter().map(|x| scrub(x, vars)).collect()),
        Value::Object(m) => Value::Object(m.iter().map(|(k, x)| (k.clone(), scrub(x, vars))).collect()),
        other => other.clone(),
    }
}

/// Transcript entry for comparison: ports scrubbed; for a step with
/// `"diff_capture": false`, the capture-dependent fields are removed.
fn compared_entry(v: &Value, vars: &harness_common::Vars) -> Value {
    let mut v = scrub(v, vars);
    if let Some(m) = v.as_object_mut() {
        if m.get("diff_capture") == Some(&Value::Bool(false)) {
            for k in ["received", "end", "read_result", "status", "body", "framing"] {
                m.remove(k);
            }
        }
    }
    v
}

/// Event list for comparison: implementation-specific text fields and
/// `bytes_read` events removed, ports scrubbed, grouped by connection id
/// (order kept within each connection).
fn normalized_events(evs: &[Value], vars: &harness_common::Vars) -> BTreeMap<String, Vec<Value>> {
    let mut out: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for e in evs {
        if e.get("event").and_then(Value::as_str) == Some("bytes_read") {
            continue;
        }
        let mut e = scrub(e, vars);
        if let Some(m) = e.as_object_mut() {
            m.remove("message");
            m.remove("detail");
        }
        let key = match e.get("conn") {
            Some(c) => format!("conn {c}"),
            None => "no conn".to_string(),
        };
        out.entry(key).or_default().push(e);
    }
    out
}

fn cmd_diff(o: &Opts) -> i32 {
    let (a, b) = match (&o.a, &o.b) {
        (Some(a), Some(b)) => (a.clone(), b.clone()),
        _ => usage(),
    };
    let cases = load_cases(&o.paths, &o.filters);
    let (mut same, mut different, mut pending, mut invalid) = (0, 0, 0, 0);
    for lc in &cases {
        if let Some(e) = &lc.invalid {
            invalid += 1;
            println!("INVALID {}\n    {e}", lc.id);
            continue;
        }
        if let Some(reason) = pending_reason(&lc.case) {
            pending += 1;
            println!("PEND {}: {reason}", lc.id);
            continue;
        }
        let ra = run_case(&lc.case, &a, Mode::Transcript, o.verbose);
        let rb = run_case(&lc.case, &b, Mode::Transcript, o.verbose);
        let mut diffs = Vec::new();
        let n = ra.transcript.len().max(rb.transcript.len());
        for i in 0..n {
            let ta = ra.transcript.get(i).map(|v| compared_entry(v, &ra.vars));
            let tb = rb.transcript.get(i).map(|v| compared_entry(v, &rb.vars));
            if ta != tb {
                diffs.push(format!(
                    "step {i}:\n      A: {}\n      B: {}",
                    ta.map_or("<missing>".into(), |v| v.to_string()),
                    tb.map_or("<missing>".into(), |v| v.to_string())
                ));
            }
        }
        let ea = normalized_events(&ra.events, &ra.vars);
        let eb = normalized_events(&rb.events, &rb.vars);
        if ea != eb {
            diffs.push(format!(
                "events:\n      A: {}\n      B: {}",
                serde_json::to_string(&ea).unwrap(),
                serde_json::to_string(&eb).unwrap()
            ));
        }
        let fa = ra.failures.len();
        let fb = rb.failures.len();
        if diffs.is_empty() {
            same += 1;
            println!("SAME {} (assertion failures: A={fa} B={fb})", lc.id);
        } else {
            different += 1;
            println!("DIFF {} (assertion failures: A={fa} B={fb})", lc.id);
            for d in diffs {
                println!("    {d}");
            }
        }
        if o.verbose {
            for f in &ra.failures {
                println!("    A failure: {f}");
            }
            for f in &rb.failures {
                println!("    B failure: {f}");
            }
        }
    }
    println!(
        "SUMMARY same={same} different={different} pending={pending} invalid={invalid} total={}",
        cases.len()
    );
    if different > 0 || invalid > 0 {
        1
    } else {
        0
    }
}

fn cmd_list(o: &Opts) -> i32 {
    let cases = load_cases(&o.paths, &o.filters);
    for lc in &cases {
        let src = lc.case.get("source").and_then(Value::as_str).unwrap_or("");
        let tag = if lc.invalid.is_some() {
            "INVALID"
        } else if pending_reason(&lc.case).is_some() {
            "PEND"
        } else {
            "CASE"
        };
        println!("{tag} {} {src}", lc.id);
        if let Some(e) = &lc.invalid {
            println!("    {e}");
        }
    }
    0
}

fn main() {
    let o = parse_args();
    let code = match o.cmd.as_str() {
        "run" => cmd_run(&o),
        "diff" => cmd_diff(&o),
        "list" => cmd_list(&o),
        _ => usage(),
    };
    std::process::exit(code);
}
