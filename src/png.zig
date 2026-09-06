//! Minimal PNG encoder (8-bit grayscale or truecolour, no alpha) and a small
//! decoder for the `--png-only` path. Uses the standard library's `flate`
//! for zlib compression/decompression, so no C dependency.

const std = @import("std");
const img = @import("image.zig");
const flate = std.compress.flate;

const SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
const Crc32 = std.hash.Crc32;

pub const EncodeError = error{ UnsupportedChannelCount, OutOfMemory, WriteFailed };
pub const DecodeError = error{ NotPng, Unsupported, Corrupt, OutOfMemory };

/// Encode `image` as a PNG byte stream (caller owns the returned slice).
pub fn encode(gpa: std.mem.Allocator, image: *const img.Image8) EncodeError![]u8 {
    const color_type: u8 = switch (image.channels) {
        1 => 0,
        3 => 2,
        else => return error.UnsupportedChannelCount,
    };
    const w: usize = image.width;
    const h: usize = image.height;
    const c: usize = image.channels;
    const stride = w * c;

    // --- filter scanlines (adaptive minimum-sum-of-absolute-differences) ---
    const filtered = try gpa.alloc(u8, h * (stride + 1));
    defer gpa.free(filtered);
    {
        var prev: []const u8 = &.{};
        const candidate = try gpa.alloc(u8, stride);
        defer gpa.free(candidate);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const row = image.pixels[y * stride ..][0..stride];
            const best = chooseFilter(row, prev, c, candidate);
            filtered[y * (stride + 1)] = best.filter;
            @memcpy(filtered[y * (stride + 1) + 1 ..][0..stride], best.data);
            prev = row;
        }
    }

    // --- zlib-compress the filtered stream ---
    var comp = try std.Io.Writer.Allocating.initCapacity(gpa, filtered.len / 2 + 64);
    defer comp.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var c_state = flate.Compress.init(&comp.writer, window, .zlib, flate.Compress.Options.default) catch return error.WriteFailed;
        c_state.writer.writeAll(filtered) catch return error.WriteFailed;
        c_state.finish() catch return error.WriteFailed;
    }
    const idat = try comp.toOwnedSlice();
    defer gpa.free(idat);

    // --- assemble the file ---
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, idat.len + 128);
    errdefer out.deinit();
    const bw = &out.writer;

    bw.writeAll(&SIGNATURE) catch return error.WriteFailed;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = color_type;
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    writeChunk(bw, "IHDR", &ihdr) catch return error.WriteFailed;

    // IDAT, split into <=8 MiB chunks.
    var off: usize = 0;
    while (off < idat.len) {
        const n = @min(idat.len - off, 8 * 1024 * 1024);
        writeChunk(bw, "IDAT", idat[off .. off + n]) catch return error.WriteFailed;
        off += n;
    }

    writeChunk(bw, "IEND", &.{}) catch return error.WriteFailed;
    return out.toOwnedSlice();
}

fn writeChunk(bw: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try bw.writeAll(&len_buf);
    try bw.writeAll(kind);
    try bw.writeAll(data);
    var crc = Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try bw.writeAll(&crc_buf);
}

const Chosen = struct { filter: u8, data: []const u8 };

fn chooseFilter(row: []const u8, prev: []const u8, bpp: usize, scratch: []u8) Chosen {
    // Try all five filters, score by sum of |signed byte|, keep the best.
    var best_score: u64 = scoreRaw(row); // filter 0 (None)
    var best_filter: u8 = 0;

    var f: u8 = 1;
    while (f <= 4) : (f += 1) {
        applyFilter(f, row, prev, bpp, scratch);
        const s = scoreRaw(scratch);
        if (s < best_score) {
            best_score = s;
            best_filter = f;
        }
    }

    if (best_filter == 0) return .{ .filter = 0, .data = row };
    // Re-apply the winning filter into scratch (it may have been overwritten).
    applyFilter(best_filter, row, prev, bpp, scratch);
    return .{ .filter = best_filter, .data = scratch };
}

fn scoreRaw(data: []const u8) u64 {
    var sum: u64 = 0;
    for (data) |b| {
        const sv: i16 = @as(i8, @bitCast(b));
        sum += @abs(sv);
    }
    return sum;
}

fn applyFilter(f: u8, row: []const u8, prev: []const u8, bpp: usize, out: []u8) void {
    var i: usize = 0;
    while (i < row.len) : (i += 1) {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b: u8 = if (prev.len != 0) prev[i] else 0;
        const c: u8 = if (prev.len != 0 and i >= bpp) prev[i - bpp] else 0;
        out[i] = switch (f) {
            1 => row[i] -% a,
            2 => row[i] -% b,
            3 => row[i] -% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
            4 => row[i] -% paeth(a, b, c),
            else => row[i],
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Decode a PNG (8-bit grayscale / RGB / RGBA, non-interlaced) to Image8.
/// RGBA input is flattened to RGB (alpha dropped).
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!img.Image8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &SIGNATURE)) return error.NotPng;
    var i: usize = 8;

    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: u8 = 0;
    var bit_depth: u8 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    while (i + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const kind = bytes[i + 4 .. i + 8];
        const data_start = i + 8;
        if (data_start + len + 4 > bytes.len) return error.Corrupt;
        const data = bytes[data_start .. data_start + len];

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            bit_depth = data[8];
            color_type = data[9];
            if (data[12] != 0) return error.Unsupported; // interlaced
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            idat.appendSlice(gpa, data) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        i = data_start + len + 4;
    }

    if (bit_depth != 8) return error.Unsupported;
    const src_channels: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        6 => 4,
        else => return error.Unsupported,
    };
    const out_channels: usize = if (src_channels == 4) 3 else src_channels;

    const w: usize = width;
    const h: usize = height;
    const src_stride = w * src_channels;

    // inflate
    var in = std.Io.Reader.fixed(idat.items);
    const window = gpa.alloc(u8, flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    var d = flate.Decompress.init(&in, .zlib, window);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    d.reader.appendRemaining(gpa, &raw, .unlimited) catch return error.Corrupt;
    if (raw.items.len < h * (src_stride + 1)) return error.Corrupt;

    // unfilter
    const recon = gpa.alloc(u8, h * src_stride) catch return error.OutOfMemory;
    errdefer gpa.free(recon);
    {
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const ft = raw.items[y * (src_stride + 1)];
            const line = raw.items[y * (src_stride + 1) + 1 ..][0..src_stride];
            const cur = recon[y * src_stride ..][0..src_stride];
            const prev: []const u8 = if (y == 0) &.{} else recon[(y - 1) * src_stride ..][0..src_stride];
            unfilter(ft, line, prev, src_channels, cur);
        }
    }

    if (src_channels == out_channels) {
        return .{ .width = width, .height = height, .channels = @intCast(out_channels), .pixels = recon };
    }
    // Drop alpha.
    defer gpa.free(recon);
    const pixels = gpa.alloc(u8, w * h * out_channels) catch return error.OutOfMemory;
    var p: usize = 0;
    while (p < w * h) : (p += 1) {
        pixels[p * 3 + 0] = recon[p * 4 + 0];
        pixels[p * 3 + 1] = recon[p * 4 + 1];
        pixels[p * 3 + 2] = recon[p * 4 + 2];
    }
    return .{ .width = width, .height = height, .channels = 3, .pixels = pixels };
}

fn unfilter(f: u8, line: []const u8, prev: []const u8, bpp: usize, out: []u8) void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const a: u8 = if (i >= bpp) out[i - bpp] else 0;
        const b: u8 = if (prev.len != 0) prev[i] else 0;
        const c: u8 = if (prev.len != 0 and i >= bpp) prev[i - bpp] else 0;
        out[i] = switch (f) {
            0 => line[i],
            1 => line[i] +% a,
            2 => line[i] +% b,
            3 => line[i] +% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
            4 => line[i] +% paeth(a, b, c),
            else => line[i],
        };
    }
}

const testing = std.testing;

test "encode/decode round trip (gray)" {
    var pix = [_]u8{ 0, 64, 128, 255, 32, 200 };
    var image = img.Image8{ .width = 3, .height = 2, .channels = 1, .pixels = &pix };
    const bytes = try encode(testing.allocator, &image);
    defer testing.allocator.free(bytes);
    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), back.width);
    try testing.expectEqual(@as(u32, 2), back.height);
    try testing.expectEqualSlices(u8, &pix, back.pixels);
}

test "encode/decode round trip (rgb)" {
    var pix: [4 * 3]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 };
    var image = img.Image8{ .width = 2, .height = 2, .channels = 3, .pixels = &pix };
    const bytes = try encode(testing.allocator, &image);
    defer testing.allocator.free(bytes);
    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &pix, back.pixels);
}
