//! Astro2PNG conversion engine — batch-convert XISF and FITS astronomical
//! images to PNG, optionally resized to 4K and stamped with the object name.
//! Shared by the `astro2png` CLI and (later) the desktop GUI.
//!
//! Pure-Zig port of the Rust `xisf2png` crate.

const build_options = @import("build_options");

pub const VERSION: []const u8 = build_options.version;

pub const wcs = @import("wcs.zig");
pub const xml = @import("xml.zig");
pub const image = @import("image.zig");
pub const lz4 = @import("lz4.zig");
pub const xisf = @import("xisf.zig");
pub const fits = @import("fits.zig");
pub const pixels = @import("pixels.zig");
pub const png = @import("png.zig");
pub const ttf = @import("ttf.zig");
pub const post = @import("post.zig");
pub const catalog = @import("catalog.zig");
pub const lookup = @import("lookup.zig");
pub const resolver = @import("resolver.zig");
pub const batch = @import("batch.zig");

test {
    _ = wcs;
    _ = xml;
    _ = image;
    _ = lz4;
    _ = xisf;
    _ = fits;
    _ = pixels;
    _ = png;
    _ = ttf;
    _ = post;
    _ = catalog;
    _ = lookup;
    _ = resolver;
    _ = batch;
}
