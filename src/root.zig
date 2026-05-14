//! Minimal Zig wrapper for boringssl-zig.
//!
//! BoringSSL's headers are not directly translatable by Zig's `translate-c`
//! (the macro-heavy `DEFINE_STACK_OF` and friends defeat the C importer).
//! This module therefore exposes only hand-written extern declarations for
//! commonly-needed entry points. Consumers who need more should add their own
//! `extern fn` declarations against `<openssl/...>` — link with the artifact
//! and the symbols are available.

pub const c = struct {
    /// Generate `len` cryptographically-secure random bytes into `buf`.
    /// Returns 1 on success, 0 on failure.
    pub extern fn RAND_bytes(buf: [*]u8, len: usize) c_int;

    /// Return the BoringSSL version string.
    pub extern fn OpenSSL_version(which: c_int) [*:0]const u8;
};

pub const OPENSSL_VERSION: c_int = 0;
