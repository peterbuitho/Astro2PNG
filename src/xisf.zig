//! Minimal reader for the monolithic XISF 1.0 file format, sufficient to pull
//! the first image out of a PixInsight / N.I.N.A. generated `.xisf` file.
//!
//! Port of the Rust `xisf.rs`.

const std = @import("std");
const xml = @import("xml.zig");
const wcs = @import("wcs.zig");
const lz4 = @import("lz4.zig");
const img = @import("image.zig");

const SIGNATURE = "XISF0100";

pub const Error = error{
    NotXisf,
    TruncatedHeader,
    InvalidXml,
    NoImageElement,
    MissingAttribute,
    BadGeometry,
    UnsupportedSampleFormat,
    BadLocation,
    AttachmentOutOfRange,
    BadEncoding,
    BadCompressionSpec,
    UnsupportedCodec,
    DecompressFailed,
    SizeMismatch,
    PixelDataTooSmall,
    OutOfMemory,
};

/// Decode the first `<Image>` in an in-memory XISF file. `object` (if any) is
/// allocated with `gpa`; so is `raw_data`.
pub fn parse(gpa: std.mem.Allocator, file: []const u8) Error!img.ImageData {
    if (file.len < 16 or !std.mem.eql(u8, file[0..8], SIGNATURE)) return error.NotXisf;
    const header_len: usize = std.mem.readInt(u32, file[8..12], .little);
    const xml_start: usize = 16;
    const xml_end = xml_start + header_len;
    if (file.len < xml_end) return error.TruncatedHeader;

    var xml_bytes = file[xml_start..xml_end];
    while (xml_bytes.len > 0 and xml_bytes[xml_bytes.len - 1] == 0) xml_bytes = xml_bytes[0 .. xml_bytes.len - 1];

    var doc = xml.parse(gpa, xml_bytes) catch return error.InvalidXml;
    defer doc.deinit();

    const image = doc.find("Image") orelse return error.NoImageElement;

    // --- header metadata for the stamp -------------------------------------
    const kw = KeywordSource{ .doc = &doc, .image = image };
    const object_raw = kw.fitsKeyword("OBJECT") orelse kw.property("Observation:Object:Name");
    const object: ?[]const u8 = if (object_raw) |o| try gpa.dupe(u8, o) else null;
    errdefer if (object) |o| gpa.free(o);

    // --- geometry --------------------------------------------------------
    const geometry = image.attr("geometry") orelse return error.MissingAttribute;
    var geo_it = std.mem.splitScalar(u8, geometry, ':');
    var geo: [8]i64 = undefined;
    var geo_n: usize = 0;
    while (geo_it.next()) |part| {
        if (geo_n >= geo.len) break;
        geo[geo_n] = std.fmt.parseInt(i64, std.mem.trim(u8, part, " \t"), 10) catch return error.BadGeometry;
        geo_n += 1;
    }
    if (geo_n < 3) return error.BadGeometry;
    const gw = geo[0];
    const gh = geo[1];
    const gc = geo[geo_n - 1];
    if (gw <= 0 or gh <= 0 or gc <= 0) return error.BadGeometry;
    const width: u32 = @intCast(gw);
    const height: u32 = @intCast(gh);
    const channels: u32 = @intCast(gc);

    const coords = wcs.fromKeywords(kw, width, height);

    // --- sample format -------------------------------------------------
    const sf_str = image.attr("sampleFormat") orelse "UInt16";
    const format: img.SampleFormat = blk: {
        if (std.mem.eql(u8, sf_str, "UInt8")) break :blk .u8;
        if (std.mem.eql(u8, sf_str, "UInt16")) break :blk .u16;
        if (std.mem.eql(u8, sf_str, "UInt32")) break :blk .u32;
        if (std.mem.eql(u8, sf_str, "UInt64")) break :blk .u64;
        if (std.mem.eql(u8, sf_str, "Float32")) break :blk .f32;
        if (std.mem.eql(u8, sf_str, "Float64")) break :blk .f64;
        return error.UnsupportedSampleFormat;
    };

    const planar = !(if (image.attr("pixelStorage")) |v| std.ascii.eqlIgnoreCase(v, "Normal") else false);
    const big_endian = if (image.attr("byteOrder")) |v| std.ascii.eqlIgnoreCase(v, "big") else false;

    const expected_samples: u64 = @as(u64, width) * height * channels;
    const expected_bytes: u64 = expected_samples * format.bytesPerSample();

    // --- locate + decode payload -------------------------------------
    const location = image.attr("location") orelse return error.MissingAttribute;
    var compression: ?[]const u8 = image.attr("compression");

    var loc_it = std.mem.splitScalar(u8, location, ':');
    const loc0 = loc_it.next() orelse return error.BadLocation;

    var payload_owned = false;
    var payload: []u8 = undefined;
    errdefer if (payload_owned) gpa.free(payload);

    if (std.mem.eql(u8, loc0, "attachment")) {
        const pos_s = loc_it.next() orelse return error.BadLocation;
        const size_s = loc_it.next() orelse return error.BadLocation;
        const position = std.fmt.parseInt(usize, pos_s, 10) catch return error.BadLocation;
        const size = std.fmt.parseInt(usize, size_s, 10) catch return error.BadLocation;
        const end = std.math.add(usize, position, size) catch return error.AttachmentOutOfRange;
        if (end > file.len) return error.AttachmentOutOfRange;
        payload = try gpa.dupe(u8, file[position..end]);
        payload_owned = true;
    } else if (std.mem.eql(u8, loc0, "embedded")) {
        const data = doc.childByName(image, "Data") orelse return error.BadLocation;
        if (compression == null) compression = data.attr("compression");
        payload = try decodeText(gpa, data.text, data.attr("encoding") orelse "base64");
        payload_owned = true;
    } else if (std.mem.eql(u8, loc0, "inline")) {
        const encoding = loc_it.next() orelse "base64";
        payload = try decodeText(gpa, image.text, encoding);
        payload_owned = true;
    } else {
        return error.BadLocation;
    }

    // --- decompress + un-shuffle ------------------------------------
    if (compression) |spec| {
        if (spec.len > 0) {
            const decompressed = try decompress(gpa, payload, spec);
            gpa.free(payload);
            payload = decompressed;
        }
    }

    if (payload.len < expected_bytes) return error.PixelDataTooSmall;

    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .format = format,
        .planar = planar,
        .big_endian = big_endian,
        .raw_data = payload,
        .object = object,
        .coords = coords,
    };
}

/// Queries FITS keywords and XISF properties from a parsed header, matching the
/// Rust closure passed to `wcs::from_keywords`.
const KeywordSource = struct {
    doc: *const xml.Document,
    image: *const xml.Node,

    fn fitsKeyword(self: KeywordSource, key: []const u8) ?[]const u8 {
        for (self.image.children) |ci| {
            const n = &self.doc.nodes[ci];
            if (!std.mem.eql(u8, n.tagName(), "FITSKeyword")) continue;
            const name = n.attr("name") orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), key)) continue;
            const v = n.attr("value") orelse return null;
            const trimmed = std.mem.trim(u8, std.mem.trim(u8, std.mem.trim(u8, v, " \t"), "'"), " \t");
            return if (trimmed.len == 0) null else trimmed;
        }
        return null;
    }

    fn property(self: KeywordSource, id: []const u8) ?[]const u8 {
        for (self.doc.nodes) |*n| {
            if (!std.mem.eql(u8, n.tagName(), "Property")) continue;
            const nid = n.attr("id") orelse continue;
            if (!std.mem.eql(u8, nid, id)) continue;
            const t = std.mem.trim(u8, n.text, " \t\r\n");
            if (t.len != 0) return t;
            if (n.attr("value")) |v| if (v.len != 0) return v;
            return null;
        }
        return null;
    }

    /// The `get` interface expected by `wcs.fromKeywords`.
    pub fn get(self: KeywordSource, key: []const u8) ?[]const u8 {
        if (self.fitsKeyword(key)) |v| return v;
        if (std.mem.eql(u8, key, "RA")) return self.property("Observation:Center:RA");
        if (std.mem.eql(u8, key, "DEC")) return self.property("Observation:Center:Dec");
        return null;
    }
};

fn decodeText(gpa: std.mem.Allocator, text: []const u8, encoding: []const u8) Error![]u8 {
    // Strip all whitespace.
    var cleaned = try gpa.alloc(u8, text.len);
    defer gpa.free(cleaned);
    var n: usize = 0;
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) {
            cleaned[n] = c;
            n += 1;
        }
    }
    const src = cleaned[0..n];

    if (std.ascii.eqlIgnoreCase(encoding, "base64")) {
        const dec = std.base64.standard.Decoder;
        const size = dec.calcSizeForSlice(src) catch return error.BadEncoding;
        const out = try gpa.alloc(u8, size);
        errdefer gpa.free(out);
        dec.decode(out, src) catch return error.BadEncoding;
        return out;
    } else if (std.ascii.eqlIgnoreCase(encoding, "hex")) {
        if (src.len % 2 != 0) return error.BadEncoding;
        const out = try gpa.alloc(u8, src.len / 2);
        errdefer gpa.free(out);
        _ = std.fmt.hexToBytes(out, src) catch return error.BadEncoding;
        return out;
    }
    return error.BadEncoding;
}

fn decompress(gpa: std.mem.Allocator, input: []const u8, spec: []const u8) Error![]u8 {
    // grammar: codec[+sh]:uncompressedSize[:shuffleItemSize]
    var it = std.mem.splitScalar(u8, spec, ':');
    const codec_spec_raw = it.next() orelse return error.BadCompressionSpec;
    const size_s = it.next() orelse return error.BadCompressionSpec;
    const uncompressed_size = std.fmt.parseInt(usize, size_s, 10) catch return error.BadCompressionSpec;

    var lower_buf: [32]u8 = undefined;
    if (codec_spec_raw.len > lower_buf.len) return error.UnsupportedCodec;
    const codec_spec = std.ascii.lowerString(lower_buf[0..codec_spec_raw.len], codec_spec_raw);

    const shuffled = std.mem.endsWith(u8, codec_spec, "+sh");
    const codec = if (shuffled) codec_spec[0 .. codec_spec.len - 3] else codec_spec;
    const shuffle_item_size: usize = if (it.next()) |s|
        (std.fmt.parseInt(usize, s, 10) catch return error.BadCompressionSpec)
    else
        1;

    var out: []u8 = undefined;
    if (std.mem.eql(u8, codec, "lz4") or std.mem.eql(u8, codec, "lz4hc")) {
        out = lz4.decompressBlock(gpa, input, uncompressed_size) catch return error.DecompressFailed;
    } else if (std.mem.eql(u8, codec, "zlib")) {
        out = inflate(gpa, input, .zlib, uncompressed_size) catch return error.DecompressFailed;
    } else if (std.mem.eql(u8, codec, "zstd")) {
        out = zstdDecode(gpa, input, uncompressed_size) catch return error.DecompressFailed;
    } else {
        return error.UnsupportedCodec;
    }
    errdefer gpa.free(out);

    if (out.len != uncompressed_size) return error.SizeMismatch;

    if (shuffled and shuffle_item_size > 1) {
        const unshuffled = try unshuffle(gpa, out, shuffle_item_size);
        gpa.free(out);
        out = unshuffled;
    }
    return out;
}

fn inflate(gpa: std.mem.Allocator, input: []const u8, container: std.compress.flate.Container, hint: usize) ![]u8 {
    var in = std.Io.Reader.fixed(input);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d = std.compress.flate.Decompress.init(&in, container, window);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, hint);
    try d.reader.appendRemaining(gpa, &out, .unlimited);
    return out.toOwnedSlice(gpa);
}

fn zstdDecode(gpa: std.mem.Allocator, input: []const u8, hint: usize) ![]u8 {
    var in = std.Io.Reader.fixed(input);
    const window = try gpa.alloc(u8, 1 << 23); // 8 MiB window ceiling
    defer gpa.free(window);
    var d = std.compress.zstd.Decompress.init(&in, window, .{});
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, hint);
    try d.reader.appendRemaining(gpa, &out, .unlimited);
    return out.toOwnedSlice(gpa);
}

/// Reverse the XISF byte-shuffle.
fn unshuffle(gpa: std.mem.Allocator, input: []const u8, item_size: usize) error{OutOfMemory}![]u8 {
    const items = input.len / item_size;
    const out = try gpa.alloc(u8, input.len);
    var p: usize = 0;
    var b: usize = 0;
    while (b < item_size) : (b += 1) {
        var i: usize = 0;
        while (i < items) : (i += 1) {
            out[i * item_size + b] = input[p];
            p += 1;
        }
    }
    var k = items * item_size;
    while (k < input.len) : (k += 1) out[k] = input[k];
    return out;
}

const testing = std.testing;

test "unshuffle round trips a transpose" {
    const original = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB, 0xCC, 0xDD };
    // shuffle: byte0 of each item, then byte1, ...
    var shuffled: [8]u8 = undefined;
    const item = 2;
    const items = 4;
    var p: usize = 0;
    for (0..item) |b| {
        for (0..items) |i| {
            shuffled[p] = original[i * item + b];
            p += 1;
        }
    }
    const back = try unshuffle(testing.allocator, &shuffled, item);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &original, back);
}
