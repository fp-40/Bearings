// Reduced copy of hyper v1.12.0 src/ext/mod.rs: HeaderCaseMap (copied
// unchanged) and the ReasonPhrase re-export.
use bytes::Bytes;
use http::header::{HeaderName, IntoHeaderName, ValueIter};
use http::HeaderMap;

mod h1_reason_phrase;
pub use h1_reason_phrase::ReasonPhrase;

/// A map from header names to their original casing as received in an HTTP message.
///
/// If an HTTP/1 response `res` is parsed on a connection whose option
/// [`preserve_header_case`] was set to true and the response included
/// the following headers:
///
/// ```ignore
/// x-Bread: Baguette
/// X-BREAD: Pain
/// x-bread: Ficelle
/// ```
///
/// Then `res.extensions().get::<HeaderCaseMap>()` will return a map with:
///
/// ```ignore
/// HeaderCaseMap({
///     "x-bread": ["x-Bread", "X-BREAD", "x-bread"],
/// })
/// ```
///
/// [`preserve_header_case`]: /client/struct.Client.html#method.preserve_header_case
#[cfg(all(any(feature = "client", feature = "server"), feature = "http1"))]
#[derive(Clone, Debug)]
pub(crate) struct HeaderCaseMap(HeaderMap<Bytes>);

#[cfg(all(any(feature = "client", feature = "server"), feature = "http1"))]
impl HeaderCaseMap {
    /// Returns a view of all spellings associated with that header name,
    /// in the order they were found.
    #[cfg(feature = "client")]
    pub(crate) fn get_all<'hdr>(
        &'hdr self,
        name: &HeaderName,
    ) -> impl Iterator<Item = impl AsRef<[u8]> + 'hdr> + 'hdr {
        self.get_all_internal(name)
    }

    /// Returns a view of all spellings associated with that header name,
    /// in the order they were found.
    #[cfg(any(feature = "client", feature = "server"))]
    pub(crate) fn get_all_internal(&self, name: &HeaderName) -> ValueIter<'_, Bytes> {
        self.0.get_all(name).into_iter()
    }

    #[cfg(any(feature = "client", feature = "server"))]
    pub(crate) fn default() -> Self {
        Self(HeaderMap::default())
    }

    #[cfg(any(test, feature = "ffi"))]
    pub(crate) fn insert(&mut self, name: HeaderName, orig: Bytes) {
        self.0.insert(name, orig);
    }

    #[cfg(any(feature = "client", feature = "server"))]
    pub(crate) fn append<N>(&mut self, name: N, orig: Bytes)
    where
        N: IntoHeaderName,
    {
        self.0.append(name, orig);
    }
}
