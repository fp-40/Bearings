// Reduced copy of hyper v1.12.0 src/proto/mod.rs: MessageHead, RequestLine
// and BodyLength, copied unchanged.

pub(crate) mod h1;

/// An Incoming Message head. Includes request/status line, and headers.
#[cfg(feature = "http1")]
#[derive(Debug, Default)]
pub(crate) struct MessageHead<S> {
    /// HTTP version of the message.
    pub(crate) version: http::Version,
    /// Subject (request line or status line) of Incoming message.
    pub(crate) subject: S,
    /// Headers of the Incoming message.
    pub(crate) headers: http::HeaderMap,
    /// Extensions.
    extensions: http::Extensions,
}

#[derive(Debug, Default, PartialEq)]
#[cfg(feature = "http1")]
pub(crate) struct RequestLine(pub(crate) http::Method, pub(crate) http::Uri);

#[derive(Debug)]
#[cfg(feature = "http1")]
pub(crate) enum BodyLength {
    /// `Content-Length`.
    Known(u64),
    /// `Transfer-Encoding: chunked` (if h1).
    Unknown,
}
