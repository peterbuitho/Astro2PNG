//! Minimal FITS reader: the image in the primary HDU of a `.fits` / `.fit` /
//! `.fts` file, as written by PixInsight, N.I.N.A., Siril, APT and SharpCap.
//!
//! Supported: BITPIX 8, 16, 32, 64, -32, -64; NAXIS = 2 (mono) or 3 with
//! NAXIS3 = 1 or 3 (RGB planes); BZERO / BSCALE; ROWORDER. Not supported:
//! images in extensions, tile-compressed (`.fz`) files, BINTABLEs.
//!
//! Port of the Rust `fits.rs`.

const std = @import("std");
const wcs = @import("wcs.zig");
const img = @import("image.zig");

const BLOCK = 2880;
const CARD = 80;

pub const Error = error{
    NotFits,
    NonStandard,
    MissingKeyword,
    NoImageData,
    UnsupportedNaxis,
    UnsupportedNaxis3,
    UnsupportedBitpix,
    ZeroSize,
    Overflow,
    PixelDataTruncated,
    NoEndCard,
    OutOfMemory,
};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!img.ImageData {
    if (bytes.len < BLOCK or !std.mem.startsWith(u8, bytes, "SIMPLE  =")) return error.NotFits;

    var header = try Header.parse(gpa, bytes);
    defer header.deinit(gpa);

    if (!(header.boolean("SIMPLE") orelse false)) return error.NonStandard;
    const bitpix = header.int("BITPIX") orelse return error.MissingKeyword;
    const naxis = header.int("NAXIS") orelse return error.MissingKeyword;

    var width: u32 = 0;
    var height: u32 = 0;
    var channels: u32 = 1;
    switch (naxis) {
        0 => return error.NoImageData,
        2 => {
            width = try header.axis(1);
            height = try header.axis(2);
        },
        3 => {
            const c = try header.axis(3);
            if (c != 1 and c != 3) return error.UnsupportedNaxis3;
            width = try header.axis(1);
            height = try header.axis(2);
            channels = c;
        },
        else => return error.UnsupportedNaxis,
    }
    if (width == 0 or height == 0) return error.ZeroSize;

    const bytes_per_sample: usize = switch (bitpix) {
        8 => 1,
        16 => 2,
        32 => 4,
        64 => 8,
        -32 => 4,
        -64 => 8,
        else => return error.UnsupportedBitpix,
    };

    const count = std.math.mul(usize, std.math.mul(usize, width, height) catch return error.Overflow, channels) catch return error.Overflow;
    const data_len = count * bytes_per_sample;
    if (header.data_offset + data_len > bytes.len) return error.PixelDataTruncated;
    const data = bytes[header.data_offset .. header.data_offset + data_len];

    const bzero = header.float("BZERO") orelse 0.0;
    const bscale = header.float("BSCALE") orelse 1.0;
    const scaled = bzero != 0.0 or bscale != 1.0;

    const bottom_up = blk: {
        if (header.string("ROWORDER")) |s| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, s, " \t"), "TOP-DOWN")) break :blk false;
        }
        break :blk true;
    };

    const w: usize = width;
    const h: usize = height;
    const c: usize = channels;
    const plane = w * h;

    var format: img.SampleFormat = undefined;
    var raw_data: []u8 = undefined;

    if (bitpix == 8 and !scaled) {
        format = .u8;
        raw_data = try flipRows(gpa, data, w, h, c, 1, bottom_up);
    } else if (bitpix == -32 and !scaled) {
        format = .f32;
        raw_data = try flipRows(gpa, data, w, h, c, 4, bottom_up);
    } else if (bitpix == -64 and !scaled) {
        format = .f64;
        raw_data = try flipRows(gpa, data, w, h, c, 8, bottom_up);
    } else {
        format = .f32;
        const out = try gpa.alloc(u8, count * 4);
        errdefer gpa.free(out);
        var ch: usize = 0;
        while (ch < c) : (ch += 1) {
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const dst_y = if (bottom_up) h - 1 - y else y;
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    const i = ch * plane + y * w + x;
                    const raw = readSample(bitpix, data[i * bytes_per_sample ..]);
                    const v: f32 = @floatCast(bzero + bscale * raw);
                    const o = (ch * plane + dst_y * w + x) * 4;
                    std.mem.writeInt(u32, out[o..][0..4], @bitCast(v), .big);
                }
            }
        }
        raw_data = out;
    }
    errdefer gpa.free(raw_data);

    var object: ?[]const u8 = null;
    if (header.string("OBJECT")) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len != 0) object = try gpa.dupe(u8, t);
    }
    errdefer if (object) |o| gpa.free(o);

    const coords = wcs.fromKeywords(HeaderGetter{ .h = &header }, width, height);

    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .format = format,
        .planar = true,
        .big_endian = true,
        .raw_data = raw_data,
        .object = object,
        .coords = coords,
    };
}

fn readSample(bitpix: i64, b: []const u8) f64 {
    return switch (bitpix) {
        8 => @floatFromInt(b[0]),
        16 => @floatFromInt(std.mem.readInt(i16, b[0..2], .big)),
        32 => @floatFromInt(std.mem.readInt(i32, b[0..4], .big)),
        64 => @floatFromInt(std.mem.readInt(i64, b[0..8], .big)),
        -32 => @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .big)))),
        -64 => @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .big))),
        else => 0.0,
    };
}

fn flipRows(gpa: std.mem.Allocator, data: []const u8, w: usize, h: usize, c: usize, bps: usize, flip: bool) error{OutOfMemory}![]u8 {
    if (!flip) return gpa.dupe(u8, data);
    const row = w * bps;
    const plane = row * h;
    const out = try gpa.alloc(u8, data.len);
    var ch: usize = 0;
    while (ch < c) : (ch += 1) {
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const src = ch * plane + y * row;
            const dst = ch * plane + (h - 1 - y) * row;
            @memcpy(out[dst .. dst + row], data[src .. src + row]);
        }
    }
    return out;
}

const Card = struct { key: []const u8, value: []const u8 };

const Header = struct {
    cards: []Card,
    data_offset: usize,

    fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Header {
        var cards: std.ArrayList(Card) = .empty;
        errdefer cards.deinit(gpa);
        var pos: usize = 0;
        while (true) {
            if (pos + CARD > bytes.len) return error.NoEndCard;
            const card = bytes[pos .. pos + CARD];
            pos += CARD;
            const key = std.mem.trimEnd(u8, card[0..8], " ");
            if (std.mem.eql(u8, key, "END")) break;
            if (card[8] == '=' and card[9] == ' ') {
                const val = stripComment(card[10..]);
                try cards.append(gpa, .{
                    .key = try gpa.dupe(u8, key),
                    .value = try gpa.dupe(u8, val),
                });
            }
        }
        const data_offset = ((pos + BLOCK - 1) / BLOCK) * BLOCK; // BLOCK (2880) is not a power of two
        return .{ .cards = try cards.toOwnedSlice(gpa), .data_offset = data_offset };
    }

    fn deinit(self: *Header, gpa: std.mem.Allocator) void {
        for (self.cards) |c| {
            gpa.free(c.key);
            gpa.free(c.value);
        }
        gpa.free(self.cards);
    }

    fn get(self: Header, key: []const u8) ?[]const u8 {
        for (self.cards) |c| {
            if (std.mem.eql(u8, c.key, key)) return c.value;
        }
        return null;
    }

    fn boolean(self: Header, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        if (std.mem.eql(u8, v, "T")) return true;
        if (std.mem.eql(u8, v, "F")) return false;
        return null;
    }

    fn int(self: Header, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t"), 10) catch null;
    }

    fn float(self: Header, key: []const u8) ?f64 {
        const v = self.get(key) orelse return null;
        return wcs.parseNumber(v);
    }

    /// Any value as text: strings unquoted, numbers as written.
    fn value(self: Header, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        if (v.len != 0 and v[0] == '\'') return self.string(key);
        const t = std.mem.trim(u8, v, " \t");
        return if (t.len == 0) null else t;
    }

    fn string(self: Header, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        if (v.len == 0 or v[0] != '\'') return null;
        const rest = v[1..];
        const close = std.mem.lastIndexOfScalar(u8, rest, '\'') orelse return std.mem.trimEnd(u8, rest, " ");
        return std.mem.trimEnd(u8, rest[0..close], " ");
    }

    fn axis(self: Header, n: u32) Error!u32 {
        var buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "NAXIS{d}", .{n}) catch unreachable;
        const v = self.int(key) orelse return error.MissingKeyword;
        if (v < 0) return error.ZeroSize;
        return @intCast(v);
    }
};

const HeaderGetter = struct {
    h: *const Header,
    pub fn get(self: HeaderGetter, key: []const u8) ?[]const u8 {
        return self.h.value(key);
    }
};

fn stripComment(field_raw: []const u8) []const u8 {
    const field = std.mem.trim(u8, field_raw, " ");
    if (field.len != 0 and field[0] == '\'') {
        var i: usize = 1;
        while (i < field.len) {
            if (field[i] == '\'') {
                if (i + 1 < field.len and field[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                return field[0 .. i + 1];
            }
            i += 1;
        }
        return field;
    }
    if (std.mem.indexOfScalar(u8, field, '/')) |idx| return std.mem.trim(u8, field[0..idx], " ");
    return field;
}

const testing = std.testing;

test "stripComment" {
    try testing.expectEqualStrings("42", stripComment("42 / the answer"));
    try testing.expectEqualStrings("'M 31'", stripComment("'M 31'          / object"));
    try testing.expectEqualStrings("T", stripComment("T"));
}
