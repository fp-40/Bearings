// Reduced copy of hyper v1.12.0 src/error.rs: the Parse and Header enums and
// the From conversions are copied unchanged; Error/Kind/User keep only what
// role.rs uses.

#[derive(Debug)]
pub(crate) enum Kind {
    Parse(Parse),
    User(User),
}

#[derive(Debug)]
pub(crate) enum Parse {
    Method,
    #[cfg(feature = "http1")]
    Version,
    #[cfg(all(any(feature = "client", feature = "server"), feature = "http1"))]
    VersionH2,
    Uri,
    #[cfg(all(feature = "http1", feature = "server"))]
    UriTooLong,
    #[cfg(feature = "http1")]
    Header(Header),
    #[cfg(any(feature = "http1", feature = "http2"))]
    #[cfg_attr(feature = "http2", allow(unused))]
    TooLarge,
    Status,
    #[cfg(all(any(feature = "client", feature = "server"), feature = "http1"))]
    Internal,
}

#[derive(Debug)]
#[cfg(feature = "http1")]
pub(crate) enum Header {
    Token,
    #[cfg(any(feature = "client", feature = "server"))]
    ContentLengthInvalid,
    #[cfg(feature = "server")]
    TransferEncodingInvalid,
    #[cfg(any(feature = "client", feature = "server"))]
    TransferEncodingUnexpected,
}

#[derive(Debug)]
pub(crate) enum User {
    UnexpectedHeader,
    UnsupportedStatusCode,
}

#[derive(Debug)]
pub(crate) struct Error {
    kind: Kind,
}

impl Error {
    pub(crate) fn kind(&self) -> &Kind {
        &self.kind
    }
    pub(crate) fn new_user_header() -> Error {
        Error { kind: Kind::User(User::UnexpectedHeader) }
    }
    pub(crate) fn new_user_unsupported_status_code() -> Error {
        Error { kind: Kind::User(User::UnsupportedStatusCode) }
    }
}

#[cfg(feature = "http1")]
impl Parse {
    #[cfg(any(feature = "client", feature = "server"))]
    pub(crate) fn content_length_invalid() -> Self {
        Parse::Header(Header::ContentLengthInvalid)
    }

    #[cfg(feature = "server")]
    pub(crate) fn transfer_encoding_invalid() -> Self {
        Parse::Header(Header::TransferEncodingInvalid)
    }

    #[cfg(any(feature = "client", feature = "server"))]
    pub(crate) fn transfer_encoding_unexpected() -> Self {
        Parse::Header(Header::TransferEncodingUnexpected)
    }
}

#[cfg(feature = "http1")]
impl From<httparse::Error> for Parse {
    fn from(err: httparse::Error) -> Parse {
        match err {
            httparse::Error::HeaderName
            | httparse::Error::HeaderValue
            | httparse::Error::NewLine
            | httparse::Error::Token => Parse::Header(Header::Token),
            httparse::Error::Status => Parse::Status,
            httparse::Error::TooManyHeaders => Parse::TooLarge,
            httparse::Error::Version => Parse::Version,
        }
    }
}

impl From<http::method::InvalidMethod> for Parse {
    fn from(_: http::method::InvalidMethod) -> Parse {
        Parse::Method
    }
}

impl From<http::status::InvalidStatusCode> for Parse {
    fn from(_: http::status::InvalidStatusCode) -> Parse {
        Parse::Status
    }
}

impl From<http::uri::InvalidUri> for Parse {
    fn from(_: http::uri::InvalidUri) -> Parse {
        Parse::Uri
    }
}

impl From<http::uri::InvalidUriParts> for Parse {
    fn from(_: http::uri::InvalidUriParts) -> Parse {
        Parse::Uri
    }
}
