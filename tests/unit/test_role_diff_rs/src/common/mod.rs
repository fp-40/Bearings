// Stub of hyper src/common/date.rs: writes a fixed date so the output is
// reproducible. test_role_diff.pas passes the same 29 bytes to ServerEncode.
pub(crate) mod date {
    pub(crate) const DATE_VALUE_LENGTH: usize = 29;
    pub(crate) const FIXED: &[u8; 29] = b"Sun, 06 Nov 1994 08:49:37 GMT";

    pub(crate) fn extend(dst: &mut Vec<u8>) {
        dst.extend_from_slice(FIXED);
    }

    pub(crate) fn update() {}
}
