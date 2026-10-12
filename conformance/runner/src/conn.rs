//! Client connections: blocking std TcpStream with per-read timeouts, a buffer
//! of bytes received but not yet consumed by a step, and sticky end state.

use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum End {
    /// Connection still open (the step ended for another reason).
    Open,
    /// Read returned 0 (peer sent FIN).
    Eof,
    /// Read failed with ECONNRESET / ECONNABORTED (peer sent RST).
    Reset,
}

impl End {
    pub fn as_str(self) -> &'static str {
        match self {
            End::Open => "open",
            End::Eof => "eof",
            End::Reset => "reset",
        }
    }
}

pub enum ReadOutcome {
    Data,
    Eof,
    Reset,
    Timeout,
}

pub struct Conn {
    stream: Option<TcpStream>,
    /// Received, not yet consumed by a step.
    pub buf: Vec<u8>,
    pub end: End,
    pub connected_at: Instant,
}

pub const DEFAULT_TIMEOUT: Duration = Duration::from_millis(1000);

impl Conn {
    pub fn connect(addr: SocketAddr, nodelay: bool) -> Result<Conn, String> {
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))
            .map_err(|e| format!("connect to {addr} failed: {e}"))?;
        let connected_at = Instant::now();
        stream
            .set_nodelay(nodelay)
            .map_err(|e| format!("set_nodelay: {e}"))?;
        Ok(Conn {
            stream: Some(stream),
            buf: Vec::new(),
            end: End::Open,
            connected_at,
        })
    }

    fn stream(&mut self) -> Result<&mut TcpStream, String> {
        self.stream
            .as_mut()
            .ok_or_else(|| "connection was closed by a previous close step".to_string())
    }

    pub fn write_all(&mut self, data: &[u8], timeout: Duration) -> Result<(), String> {
        let s = self.stream()?;
        s.set_write_timeout(Some(timeout.max(Duration::from_millis(1))))
            .map_err(|e| e.to_string())?;
        s.write_all(data).map_err(|e| format!("write failed: {e} ({:?})", e.kind()))?;
        s.flush().map_err(|e| format!("flush failed: {e}"))
    }

    pub fn shutdown_write(&mut self) -> Result<(), String> {
        self.stream()?
            .shutdown(Shutdown::Write)
            .map_err(|e| format!("shutdown(Write) failed: {e}"))
    }

    pub fn close(&mut self) {
        self.stream = None;
    }

    pub fn is_closed_locally(&self) -> bool {
        self.stream.is_none()
    }

    /// One read() from the socket into `self.buf`, waiting at most `timeout`.
    pub fn read_some(&mut self, timeout: Duration) -> Result<ReadOutcome, String> {
        match self.end {
            End::Eof => return Ok(ReadOutcome::Eof),
            End::Reset => return Ok(ReadOutcome::Reset),
            End::Open => {}
        }
        let s = self.stream()?;
        s.set_read_timeout(Some(timeout.max(Duration::from_millis(1))))
            .map_err(|e| e.to_string())?;
        let mut tmp = [0u8; 65536];
        loop {
            match s.read(&mut tmp) {
                Ok(0) => {
                    self.end = End::Eof;
                    return Ok(ReadOutcome::Eof);
                }
                Ok(n) => {
                    self.buf.extend_from_slice(&tmp[..n]);
                    return Ok(ReadOutcome::Data);
                }
                Err(e) => match e.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => return Ok(ReadOutcome::Timeout),
                    ErrorKind::Interrupted => continue,
                    ErrorKind::ConnectionReset | ErrorKind::ConnectionAborted => {
                        self.end = End::Reset;
                        return Ok(ReadOutcome::Reset);
                    }
                    _ => return Err(format!("read failed: {e} ({:?})", e.kind())),
                },
            }
        }
    }

    /// Take up to `max` bytes from the front of the buffer.
    pub fn take(&mut self, max: usize) -> Vec<u8> {
        let n = max.min(self.buf.len());
        self.buf.drain(..n).collect()
    }
}
