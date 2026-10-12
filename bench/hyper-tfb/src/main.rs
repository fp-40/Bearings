// Copy of FrameworkBenchmarks frameworks/Rust/hyper/src/main.rs (57d92fb) with the
// DB/json/fortunes routes and logging removed. Runtime layout is unchanged:
// one current-thread tokio runtime per thread (default = num_cpus), SO_REUSEPORT
// listener per runtime, nodelay, backlog 4096, http1::Builder with pipeline_flush(true).
// Extra: optional 2nd arg = port (default 8080), optional THREADS env.
use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr};
use std::{io, thread};

use http::header::{CONTENT_LENGTH, CONTENT_TYPE, SERVER};
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::{Bytes, Incoming};
use hyper::header::HeaderValue;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use socket2::{Domain, SockAddr, Socket};
use tokio::net::TcpListener;
use tokio::runtime;

static SERVER_HEADER: HeaderValue = HeaderValue::from_static("hyper");
static TEXT_PLAIN: HeaderValue = HeaderValue::from_static("text/plain");
static CONTENT: &[u8] = b"Hello, world!";

type R = Result<Response<BoxBody<Bytes, Infallible>>, http::Error>;

fn main() -> io::Result<()> {
    let threads: usize = std::env::var("THREADS").ok().and_then(|s| s.parse().ok()).unwrap_or_else(num_cpus::get);
    let port: u16 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(8080);
    eprintln!("hyper-tfb: {} current-thread runtimes, port {}", threads, port);
    for _ in 1..threads {
        let rt = runtime::Builder::new_current_thread().enable_all().build()?;
        thread::spawn(move || run_server(rt, port));
    }
    let rt = runtime::Builder::new_current_thread().enable_all().build()?;
    run_server(rt, port)
}

fn run_server(rt: runtime::Runtime, port: u16) -> io::Result<()> {
    rt.block_on(serve(rt.handle(), port))
}

async fn serve(handle: &runtime::Handle, port: u16) -> io::Result<()> {
    let addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, port));
    let socket = create_socket(addr)?;
    let listener = TcpListener::from_std(socket.into())?;
    let accept_loop = accept_loop(handle.clone(), listener);
    handle.spawn(accept_loop).await.unwrap()
}

fn create_socket(addr: SocketAddr) -> io::Result<Socket> {
    let socket = Socket::new(Domain::IPV4, socket2::Type::STREAM, None)?;
    socket.set_reuse_port(true)?;
    socket.set_reuse_address(true)?;
    socket.set_nodelay(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(addr))?;
    socket.listen(4096)?;
    Ok(socket)
}

async fn accept_loop(handle: runtime::Handle, listener: TcpListener) -> io::Result<()> {
    let mut http = http1::Builder::new();
    http.pipeline_flush(std::env::var("PFLUSH").map(|v| v != "0").unwrap_or(true));
    let service = service_fn(router);
    loop {
        let (stream, _) = listener.accept().await?;
        let http = http.clone();
        handle.spawn(async move {
            let io = TokioIo::new(stream);
            let _ = http.serve_connection(io, service).await;
        });
    }
}

async fn router(request: Request<Incoming>) -> R {
    match request.uri().path() {
        "/plaintext" => Response::builder()
            .header(SERVER, SERVER_HEADER.clone())
            .header(CONTENT_TYPE, TEXT_PLAIN.clone())
            .header(CONTENT_LENGTH, CONTENT.len())
            .body(Full::from(CONTENT).boxed()),
        "/ping" => Response::builder().body(Full::from("pong").boxed()),
        _ => Response::builder().status(StatusCode::NOT_FOUND).header(SERVER, SERVER_HEADER.clone()).body(Empty::new().boxed()),
    }
}
