// The items hyper's decode.rs imports from its parent module, reduced to what
// decode.rs uses. Copied from hyper v1.12.0 (src/proto/h1/io.rs MemRead,
// src/proto/h1/role.rs DEFAULT_MAX_HEADERS, src/body/length.rs DecodedLength).

pub(crate) mod io {
    use bytes::Bytes;
    use std::task::{Context, Poll};

    pub(crate) trait MemRead {
        fn read_mem(&mut self, cx: &mut Context<'_>, len: usize) -> Poll<std::io::Result<Bytes>>;
    }
}

pub(crate) mod role {
    pub(crate) const DEFAULT_MAX_HEADERS: usize = 100;
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) struct DecodedLength(u64);

impl DecodedLength {
    pub(crate) const CLOSE_DELIMITED: DecodedLength = DecodedLength(u64::MAX);
    pub(crate) const CHUNKED: DecodedLength = DecodedLength(u64::MAX - 1);

    pub(crate) fn danger_len(self) -> u64 {
        self.0
    }
}

pub(crate) mod decode;
