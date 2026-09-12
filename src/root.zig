//! Astro2PNG conversion engine — batch-convert XISF and FITS astronomical
//! images to PNG, optionally resized to 4K and stamped with the object name.
//! Shared by the `astro2png` CLI and the desktop GUI.
//!
//! The conversion pipeline itself lives in the shared
//! [astropng-core](https://github.com/peterbuitho/astropng-core) crate,
//! also used by the Go/Rust/Scala ports of this program (via its C ABI).
//! This module is a thin FFI wrapper around it.

const build_options = @import("build_options");

pub const VERSION: []const u8 = build_options.version;

pub const batch = @import("batch.zig");

test {
    _ = batch;
}
