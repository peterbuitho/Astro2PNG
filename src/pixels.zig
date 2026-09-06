//! Convert a decoded XISF / FITS image into 8-bit PNG pixel data, applying a
//! linear per-image min/max stretch to the full sample range.
//!
//! Port of the Rust `pixels.rs`.

const std = @import("std");
const img = @import("image.zig");

pub const Error = error{ UnsupportedChannelCount, PixelDataTooSmall, OutOfMemory };

pub fn toImage(gpa: std.mem.Allocator, data: *const img.ImageData) Error!img.Image8 {
    if (data.channels != 1 and data.channels != 3) return error.UnsupportedChannelCount;

    const w: usize = data.width;
    const h: usize = data.height;
    const c: usize = data.channels;
    const count = w * h * c;

    const samples = try gpa.alloc(f64, count);
    defer gpa.free(samples);
    try decodeSamples(data, samples);

    // Planar (channel-major) -> interleaved (pixel-major).
    if (data.planar and c > 1) {
        const interleaved = try gpa.alloc(f64, count);
        defer gpa.free(interleaved);
        const plane = w * h;
        var ch: usize = 0;
        while (ch < c) : (ch += 1) {
            var i: usize = 0;
            while (i < plane) : (i += 1) {
                interleaved[i * c + ch] = samples[ch * plane + i];
            }
        }
        @memcpy(samples, interleaved);
    }

    var min: f64 = std.math.inf(f64);
    var max: f64 = -std.math.inf(f64);
    for (samples) |v| {
        if (std.math.isNan(v)) continue;
        if (v < min) min = v;
        if (v > max) max = v;
    }

    const pixels = try gpa.alloc(u8, count);
    @memset(pixels, 0);
    if (std.math.isFinite(min) and std.math.isFinite(max) and max > min) {
        const scale = 255.0 / (max - min);
        for (samples, 0..) |v, i| {
            if (std.math.isNan(v)) continue;
            const s = (v - min) * scale;
            pixels[i] = if (s <= 0.0) 0 else if (s >= 255.0) 255 else @intFromFloat(s + 0.5);
        }
    }

    return .{
        .width = data.width,
        .height = data.height,
        .channels = data.channels,
        .pixels = pixels,
    };
}

fn decodeSamples(data: *const img.ImageData, out: []f64) Error!void {
    const raw = data.raw_data;
    const bps = data.format.bytesPerSample();
    const swap = data.big_endian;
    const count = out.len;
    if (raw.len < count * bps) return error.PixelDataTooSmall;

    const endian: std.builtin.Endian = if (swap) .big else .little;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = raw[i * bps ..];
        out[i] = switch (data.format) {
            .u8 => @floatFromInt(b[0]),
            .u16 => @floatFromInt(std.mem.readInt(u16, b[0..2], endian)),
            .u32 => @floatFromInt(std.mem.readInt(u32, b[0..4], endian)),
            .u64 => @floatFromInt(std.mem.readInt(u64, b[0..8], endian)),
            .f32 => @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], endian)))),
            .f64 => @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], endian))),
        };
    }
}

const testing = std.testing;

test "linear stretch to full range" {
    // 2x1 mono UInt16 big-endian: values 1000 and 5000 -> 0 and 255.
    var raw = [_]u8{ 0x03, 0xE8, 0x13, 0x88 };
    var data = img.ImageData{
        .width = 2,
        .height = 1,
        .channels = 1,
        .format = .u16,
        .planar = true,
        .big_endian = true,
        .raw_data = &raw,
        .object = null,
        .coords = null,
    };
    var out = try toImage(testing.allocator, &data);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), out.pixels[0]);
    try testing.expectEqual(@as(u8, 255), out.pixels[1]);
}
