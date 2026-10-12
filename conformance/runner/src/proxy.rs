//! In-process HTTP/1 proxy equivalent to hyper's tests/support/mod.rs
//! `naive_proxy` (h1 branch), used for the integration.rs "via proxy" runs.
//! Like the original it serves accepted connections one at a time, rewrites the
//! request URI to `http://<server>{path}` (path only, query dropped), sends it
//! upstream on a new connection with hyper's http1 client, removes the
//! `Connection` header from the response and streams the body back.

use crate::tokiort::TokioIo;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response};
use std::net::SocketAddr;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

pub struct Proxy {
    pub port: u16,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Proxy {
    pub fn start(dst: SocketAddr) -> Result<Proxy, String> {
        let (port_tx, port_rx) = std::sync::mpsc::channel();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
        let thread = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("proxy runtime");
            rt.block_on(async move {
                let listener = match tokio::net::TcpListener::bind("127.0.0.1:0").await {
                    Ok(l) => l,
                    Err(e) => {
                        let _ = port_tx.send(Err(e.to_string()));
                        return;
                    }
                };
                let _ = port_tx.send(Ok(listener.local_addr().unwrap().port()));
                let accept_loop = async move {
                    loop {
                        let (stream, _) = match listener.accept().await {
                            Ok(s) => s,
                            Err(e) => {
                                eprintln!("runner proxy: accept error: {e}");
                                continue;
                            }
                        };
                        serve(stream, dst).await;
                    }
                };
                tokio::select! {
                    _ = accept_loop => {}
                    _ = stop_rx => {}
                }
            });
        });
        let port = port_rx
            .recv()
            .map_err(|_| "proxy thread died".to_string())?
            .map_err(|e| format!("proxy bind failed: {e}"))?;
        Ok(Proxy {
            port,
            stop: Some(stop_tx),
            thread: Some(thread),
        })
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        if let Some(s) = self.stop.take() {
            let _ = s.send(());
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

async fn serve(stream: tokio::net::TcpStream, dst: SocketAddr) {
    let io = TokioIo::new(stream);
    let service = service_fn(move |mut req: Request<Incoming>| async move {
        let uri = format!("http://{}{}", dst, req.uri().path())
            .parse()
            .map_err(|e| -> BoxError { format!("proxy new uri parse: {e}").into() })?;
        *req.uri_mut() = uri;

        let stream = tokio::net::TcpStream::connect(dst).await?;
        let (mut sender, conn) = hyper::client::conn::http1::Builder::new()
            .handshake(TokioIo::new(stream))
            .await?;
        tokio::task::spawn(async move {
            if let Err(err) = conn.await {
                eprintln!("runner proxy: upstream connection error: {err:?}");
            }
        });
        let resp = sender.send_request(req).await?;
        let (mut parts, body) = resp.into_parts();
        parts.headers.remove("Connection");
        let mut builder = Response::builder().status(parts.status);
        *builder.headers_mut().unwrap() = parts.headers;
        Ok::<_, BoxError>(builder.body(body).unwrap())
    });
    if let Err(e) = hyper::server::conn::http1::Builder::new()
        .serve_connection(io, service)
        .await
    {
        eprintln!("runner proxy: client connection error: {e:?}");
    }
}
