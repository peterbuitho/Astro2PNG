//! Shared image types: the decoded sample payload handed from the XISF / FITS
//! readers to the stretch step, and the 8-bit result handed to the PNG
//! encoder and the post-processing step.

const std = @import("std");
const wcs = @import("wcs.zig");

pub const SampleFormat = enum {
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,

    pub fn bytesPerSample(self: SampleFormat) usize {
        return switch (self) {
            .u8 => 1,
            .u16 => 2,
            .u32, .f32 => 4,
            .u64, .f64 => 8,
        };
    }
};

/// Decoded pixel payload of the first image in an XISF or FITS file, plus the
/// metadata needed to interpret the raw bytes. `raw_data` is owned by the
/// caller's allocator.
pub const ImageData = struct {
    width: u32,
    height: u32,
    channels: u32,
    format: SampleFormat,
    /// Planar = channel-major storage; otherwise interleaved ("Normal").
    planar: bool,
    /// True when samples are stored big-endian.
    big_endian: bool,
    /// Raw, decompressed, un-shuffled sample bytes.
    raw_data: []u8,
    /// Target name from the header, if present. Owned.
    object: ?[]const u8 = null,
    /// Image centre from the plate solution or the mount target, if present.
    coords: ?wcs.SkyCoords = null,

    pub fn deinit(self: *ImageData, gpa: std.mem.Allocator) void {
        gpa.free(self.raw_data);
        if (self.object) |o| gpa.free(o);
    }
};

/// 8-bit interleaved (pixel-major) image, ready for PNG.
pub const Image8 = struct {
    width: u32,
    height: u32,
    channels: u32, // 1 (gray) or 3 (rgb)
    pixels: []u8,

    pub fn deinit(self: *Image8, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};
