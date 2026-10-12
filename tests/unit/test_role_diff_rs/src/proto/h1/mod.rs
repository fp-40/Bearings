// Reduced copy of hyper v1.12.0 src/proto/h1/mod.rs (Http1Transaction,
// ParseResult, ParsedMessage, ParseContext, Encode copied unchanged), a
// stub of io::WriteBuf (encode.rs names it; the harness never calls the
// methods that use it), and the parse driver, which lives here because
// ParsedMessage's fields are private to this module. role.rs and encode.rs
// stay whole: role.rs (Server::parse) does not compile without encode.rs.

use bytes::{Buf, Bytes, BytesMut};
use http::header::{HeaderName, HeaderValue};
use http::{HeaderMap, Method, StatusCode, Version};
use httparse::ParserConfig;

use crate::body::DecodedLength;
use crate::ext::{HeaderCaseMap, ReasonPhrase};
use crate::proto::{BodyLength, MessageHead};

pub(crate) use self::encode::{EncodedBuf, Encoder};

mod encode;
mod role;

pub(crate) mod io {
    pub(crate) struct WriteBuf<B> {
        _b: std::marker::PhantomData<B>,
    }

    impl<B: bytes::Buf> WriteBuf<B> {
        pub(crate) fn buffer<BB: bytes::Buf + Into<B>>(&mut self, _buf: BB) {
            unimplemented!("not used by the role harness")
        }
    }
}

pub(crate) trait Http1Transaction {
    type Incoming;
    type Outgoing: Default;
    #[cfg(feature = "tracing")]
    const LOG: &'static str;
    fn parse(bytes: &mut BytesMut, ctx: ParseContext<'_>) -> ParseResult<Self::Incoming>;
    fn encode(enc: Encode<'_, Self::Outgoing>, dst: &mut Vec<u8>) -> crate::Result<Encoder>;

    fn on_error(err: &crate::Error) -> Option<MessageHead<Self::Outgoing>>;

    fn is_client() -> bool {
        !Self::is_server()
    }

    fn is_server() -> bool {
        !Self::is_client()
    }

    fn should_error_on_parse_eof() -> bool {
        Self::is_client()
    }

    fn should_read_first() -> bool {
        Self::is_server()
    }

    fn update_date() {}
}

/// Result newtype for `Http1Transaction::parse`.
pub(crate) type ParseResult<T> = Result<Option<ParsedMessage<T>>, crate::error::Parse>;

#[derive(Debug)]
pub(crate) struct ParsedMessage<T> {
    head: MessageHead<T>,
    decode: DecodedLength,
    expect_continue: bool,
    keep_alive: bool,
    wants_upgrade: bool,
}

pub(crate) struct ParseContext<'ctx> {
    cached_headers: &'ctx mut Option<HeaderMap>,
    req_method: &'ctx mut Option<Method>,
    h1_parser_config: ParserConfig,
    h1_max_headers: Option<usize>,
    h1_max_header_size: Option<usize>,
    preserve_header_case: bool,
    #[cfg(feature = "ffi")]
    preserve_header_order: bool,
    h09_responses: bool,
    #[cfg(feature = "client")]
    on_informational: &'ctx mut Option<crate::ext::OnInformational>,
}

/// Passed to `Http1Transaction::encode`.
pub(crate) struct Encode<'encode, T> {
    head: &'encode mut MessageHead<T>,
    body: Option<BodyLength>,
    #[cfg(feature = "server")]
    keep_alive: bool,
    req_method: &'encode mut Option<Method>,
    title_case_headers: bool,
    #[cfg(feature = "server")]
    date_header: bool,
}

// ===== harness drivers (not hyper code) =====

pub(crate) fn hex(b: &[u8]) -> String {
    if b.is_empty() {
        return "-".into();
    }
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{:02x}", x));
    }
    s
}

/// Server::parse on `bytes`; returns one result line.
pub(crate) fn drive_parse(
    bytes: &[u8],
    max_headers: Option<usize>,
    max_header_size: Option<usize>,
    cfg: ParserConfig,
) -> String {
    use role::Server;
    let mut buf = BytesMut::from(bytes);
    let mut method = None;
    let r = Server::parse(
        &mut buf,
        ParseContext {
            cached_headers: &mut None,
            req_method: &mut method,
            h1_parser_config: cfg,
            h1_max_headers: max_headers,
            h1_max_header_size: max_header_size,
            preserve_header_case: true,
            h09_responses: false,
        },
    );
    match r {
        Ok(None) => "PARTIAL".into(),
        Err(e) => format!("ERR {:?}", e),
        Ok(Some(msg)) => {
            let consumed = bytes.len() - buf.len();
            assert_eq!(method.as_ref(), Some(&msg.head.subject.0));
            let uri = &msg.head.subject.1;
            let scheme = uri.scheme_str().map(|s| hex(s.as_bytes())).unwrap_or("~".into());
            let auth = uri
                .authority()
                .map(|a| hex(a.as_str().as_bytes()))
                .unwrap_or("~".into());
            let path = hex(uri.path().as_bytes());
            let query = uri.query().map(|q| hex(q.as_bytes())).unwrap_or("~".into());
            let ver = match msg.head.version {
                Version::HTTP_10 => "1.0",
                Version::HTTP_11 => "1.1",
                _ => "?",
            };
            let casemap = msg
                .head
                .extensions
                .get::<HeaderCaseMap>()
                .expect("preserve_header_case");
            let mut names: Vec<&HeaderName> = msg.head.headers.keys().collect();
            names.sort_by(|a, b| a.as_str().cmp(b.as_str()));
            let mut hs = Vec::new();
            for n in names {
                let vals: Vec<&HeaderValue> = msg.head.headers.get_all(n).iter().collect();
                let sps: Vec<&Bytes> = casemap.get_all_internal(n).collect();
                assert_eq!(vals.len(), sps.len());
                for (v, sp) in vals.iter().zip(sps.iter()) {
                    hs.push(format!("{}={}", hex(sp), hex(v.as_bytes())));
                }
            }
            let hs = if hs.is_empty() { "-".to_string() } else { hs.join(",") };
            format!(
                "OK {} {} {} {} {} {} {} {:?} {} {} {} {}",
                consumed,
                hex(msg.head.subject.0.as_str().as_bytes()),
                scheme,
                auth,
                path,
                query,
                ver,
                msg.decode,
                msg.expect_continue as u8,
                msg.keep_alive as u8,
                msg.wants_upgrade as u8,
                hs
            )
        }
    }
}
