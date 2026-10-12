//! Server process management: spawn `<cmd> --config <file>`, wait for
//! "LISTENING <port>", collect JSON events from stdout, send control lines.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct Event {
    pub v: Value,
}

#[derive(Default)]
pub struct EventLog {
    pub events: Mutex<Vec<Event>>,
    pub cond: Condvar,
}

impl EventLog {
    pub fn snapshot(&self) -> Vec<Event> {
        self.events.lock().unwrap().clone()
    }

    /// Wait until `pred(events)` returns Some, or the deadline passes.
    pub fn wait_for<T>(&self, deadline: Instant, mut pred: impl FnMut(&[Event]) -> Option<T>) -> Option<T> {
        let mut g = self.events.lock().unwrap();
        loop {
            if let Some(t) = pred(&g) {
                return Some(t);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            g = self.cond.wait_timeout(g, deadline - now).unwrap().0;
        }
    }
}

pub struct ServerProc {
    child: Child,
    stdin: Option<ChildStdin>,
    /// The stdout reader thread; `stop` joins it so the event log holds every
    /// line the server wrote before it exited.
    reader: Option<std::thread::JoinHandle<()>>,
    pub port: u16,
    pub events: Arc<EventLog>,
    pub stderr: Arc<Mutex<Vec<u8>>>,
    _config_file: TempFile,
}

struct TempFile(std::path::PathBuf);
impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl ServerProc {
    pub fn spawn(cmd: &str, server_spec: &Value) -> Result<ServerProc, String> {
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "bearings-conformance-{}-{}.json",
            std::process::id(),
            n
        ));
        std::fs::write(&path, serde_json::to_vec_pretty(server_spec).unwrap())
            .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        let tmp = TempFile(path.clone());

        let mut child = Command::new("sh")
            .arg("-c")
            .arg(format!("exec {cmd} \"$@\""))
            .arg("sh")
            .arg("--config")
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("cannot spawn server {cmd:?}: {e}"))?;

        let stderr = Arc::new(Mutex::new(Vec::new()));
        {
            let mut err = child.stderr.take().unwrap();
            let sink = stderr.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 4096];
                while let Ok(n) = err.read(&mut buf) {
                    if n == 0 {
                        break;
                    }
                    sink.lock().unwrap().extend_from_slice(&buf[..n]);
                }
            });
        }

        let events = Arc::new(EventLog::default());
        let (port_tx, port_rx) = mpsc::channel::<Result<u16, String>>();
        let reader = {
            let out = child.stdout.take().unwrap();
            let log = events.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(out);
                let mut first = String::new();
                match reader.read_line(&mut first) {
                    Ok(0) | Err(_) => {
                        let _ = port_tx.send(Err("server closed stdout before LISTENING".into()));
                        return;
                    }
                    Ok(_) => {}
                }
                let port = first
                    .trim_end()
                    .strip_prefix("LISTENING ")
                    .and_then(|p| p.trim().parse::<u16>().ok());
                match port {
                    Some(p) => {
                        let _ = port_tx.send(Ok(p));
                    }
                    None => {
                        let _ = port_tx.send(Err(format!(
                            "first stdout line must be \"LISTENING <port>\", got {:?}",
                            first
                        )));
                        return;
                    }
                }
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match reader.read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    let text = String::from_utf8_lossy(&line);
                    let text = text.trim_end();
                    if text.is_empty() {
                        continue;
                    }
                    let v = serde_json::from_str::<Value>(text)
                        .unwrap_or_else(|_| json!({"event": "invalid_line", "line": text}));
                    log.events.lock().unwrap().push(Event { v });
                    log.cond.notify_all();
                }
            })
        };

        let stdin = child.stdin.take();
        let mut proc = ServerProc {
            child,
            stdin,
            reader: Some(reader),
            port: 0,
            events,
            stderr,
            _config_file: tmp,
        };
        match port_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(p)) => proc.port = p,
            Ok(Err(e)) => {
                std::thread::sleep(Duration::from_millis(100));
                return Err(format!("{e}; server stderr:\n{}", proc.stderr_text()));
            }
            Err(_) => return Err("server did not print LISTENING within 10 s".into()),
        }
        Ok(proc)
    }

    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr.lock().unwrap()).into_owned()
    }

    pub fn send_line(&mut self, line: &str) -> Result<(), String> {
        let stdin = self.stdin.as_mut().ok_or("server stdin is closed")?;
        stdin
            .write_all(format!("{line}\n").as_bytes())
            .and_then(|_| stdin.flush())
            .map_err(|e| format!("cannot write to server stdin: {e}"))
    }

    /// Exit status if the process has already exited.
    pub fn exited(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(st)) => Some(st.to_string()),
            _ => None,
        }
    }

    pub fn stop(&mut self) {
        let _ = self.send_line("exit");
        self.stdin = None;
        let deadline = Instant::now() + Duration::from_millis(500);
        let mut exited = false;
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                exited = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        if !exited {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        // stdout is closed once the process is gone (it was started with
        // `exec`), so the reader ends after it has logged every line
        if let Some(h) = self.reader.take() {
            let _ = h.join();
        }
    }
}

impl Drop for ServerProc {
    fn drop(&mut self) {
        if let Ok(None) = self.child.try_wait() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}
