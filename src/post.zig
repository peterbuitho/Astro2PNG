//! Post-processing: resize to exactly 3840x2160 (cover + centre crop) and
//! stamp a two-line label in the bottom-right corner. The resize is a
//! separable triangle filter; the label is rasterised with `ttf.zig`.
//!
//! Port of the Rust `post.rs`.

const std = @import("std");
const img = @import("image.zig");
const ttf = @import("ttf.zig");

pub const TARGET_WIDTH: u32 = 3840;
pub const TARGET_HEIGHT: u32 = 2160;

const TITLE_PX: f32 = 48.0;
const SUBTITLE_PX: f32 = 30.0;
const LINE_GAP: f32 = 14.0;
const MARGIN_RIGHT: f32 = 60.0;
const MARGIN_BOTTOM: f32 = 120.0;
const SHADOW_OFFSET: f32 = 2.0;
const SHADOW_OPACITY: f32 = 0.7;

pub const Label = struct {
    title: []const u8,
    subtitle: ?[]const u8 = null,
};

/// The embedded stamp font (DejaVu Sans Condensed Bold).
pub fn bundledFontBytes() []const u8 {
    return @embedFile("dejavu_font");
}

/// Holds the label font; create once and reuse for every image.
pub const Stamper = struct {
    font: ttf.Font,

    pub fn initBundled() Stamper {
        return .{ .font = ttf.Font.parse(bundledFontBytes()) catch unreachable };
    }

    /// `font_bytes` must outlive the Stamper.
    pub fn init(font_bytes: []const u8) !Stamper {
        return .{ .font = try ttf.Font.parse(font_bytes) };
    }

    /// Resize `image` to cover 3840×2160, centre-crop, then draw `label` in the
    /// bottom-right corner. Caller owns the returned pixels.
    pub fn resizeAndLabel(self: Stamper, gpa: std.mem.Allocator, image: *const img.Image8, label: Label) !img.Image8 {
        var out = try resizeToFill(gpa, image, TARGET_WIDTH, TARGET_HEIGHT);
        errdefer out.deinit(gpa);
        try self.drawLabel(gpa, &out, label);
        return out;
    }

    fn scaledDescentAbs(self: Stamper, px: f32) f32 {
        return @abs(self.font.descent() * px / self.font.unitsPerEm());
    }
    fn scaledAscent(self: Stamper, px: f32) f32 {
        return self.font.ascent() * px / self.font.unitsPerEm();
    }

    fn drawLabel(self: Stamper, gpa: std.mem.Allocator, image: *img.Image8, label: Label) !void {
        const right = @as(f32, @floatFromInt(image.width)) - MARGIN_RIGHT;
        const bottom = @as(f32, @floatFromInt(image.height)) - MARGIN_BOTTOM;
        const max_width = @as(f32, @floatFromInt(image.width)) - 2.0 * MARGIN_RIGHT;

        var title_baseline = bottom - self.scaledDescentAbs(TITLE_PX);

        if (label.subtitle) |sub| {
            if (std.mem.trim(u8, sub, " \t").len != 0) {
                const sub_baseline = bottom - self.scaledDescentAbs(SUBTITLE_PX);
                try self.drawLine(gpa, image, sub, SUBTITLE_PX, right, sub_baseline, max_width);
                title_baseline = sub_baseline - self.scaledAscent(SUBTITLE_PX) - LINE_GAP;
            }
        }
        if (std.mem.trim(u8, label.title, " \t").len != 0) {
            try self.drawLine(gpa, image, label.title, TITLE_PX, right, title_baseline, max_width);
        }
    }

    const Placed = struct { gid: u16, x: f32 };

    fn layout(self: Stamper, gpa: std.mem.Allocator, text: []const u8, px: f32, out: *std.ArrayList(Placed)) !f32 {
        out.clearRetainingCapacity();
        const sf = px / self.font.unitsPerEm();
        var x: f32 = 0;
        var prev: ?u16 = null;
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            const gid = self.font.glyphId(cp);
            if (prev) |p| x += self.font.kern(p, gid) * sf;
            try out.append(gpa, .{ .gid = gid, .x = x });
            x += self.font.advance(gid) * sf;
            prev = gid;
        }
        return x;
    }

    fn drawLine(self: Stamper, gpa: std.mem.Allocator, image: *img.Image8, text: []const u8, px_in: f32, right: f32, baseline: f32, max_width: f32) !void {
        var glyphs: std.ArrayList(Placed) = .empty;
        defer glyphs.deinit(gpa);

        var px = px_in;
        var width = try self.layout(gpa, text, px, &glyphs);
        if (width > max_width and width > 0) {
            px = px * max_width / width;
            width = try self.layout(gpa, text, px, &glyphs);
        }
        const x0 = right - width;
        const scale = px / self.font.unitsPerEm();

        try self.blit(gpa, image, glyphs.items, scale, x0 + SHADOW_OFFSET, baseline + SHADOW_OFFSET, 0, SHADOW_OPACITY);
        try self.blit(gpa, image, glyphs.items, scale, x0, baseline, 255, 1.0);
    }

    fn blit(self: Stamper, gpa: std.mem.Allocator, image: *img.Image8, glyphs: []const Placed, scale: f32, origin_x: f32, origin_y: f32, value: u8, opacity: f32) !void {
        const iw: i64 = image.width;
        const ih: i64 = image.height;
        const ch: usize = image.channels;

        for (glyphs) |g| {
            const gx = origin_x + g.x;
            const ix: i64 = @intFromFloat(@floor(gx));
            const fx = gx - @floor(gx);
            const iy: i64 = @intFromFloat(@floor(origin_y));
            const fy = origin_y - @floor(origin_y);

            var glyph = (try self.font.rasterize(gpa, g.gid, scale, fx, fy)) orelse continue;
            defer glyph.deinit(gpa);

            var row: usize = 0;
            while (row < glyph.h) : (row += 1) {
                var col: usize = 0;
                while (col < glyph.w) : (col += 1) {
                    const cov = glyph.coverage[row * glyph.w + col];
                    const a = std.math.clamp(cov * opacity, 0.0, 1.0);
                    if (a <= 0.0) continue;
                    const px_x = ix + glyph.left + @as(i64, @intCast(col));
                    const px_y = iy + glyph.top + @as(i64, @intCast(row));
                    if (px_x < 0 or px_y < 0 or px_x >= iw or px_y >= ih) continue;
                    const base = (@as(usize, @intCast(px_y)) * image.width + @as(usize, @intCast(px_x))) * ch;
                    var k: usize = 0;
                    while (k < ch) : (k += 1) {
                        const src: f32 = @floatFromInt(image.pixels[base + k]);
                        const blended = src + (@as(f32, @floatFromInt(value)) - src) * a;
                        image.pixels[base + k] = @intFromFloat(std.math.clamp(@round(blended), 0.0, 255.0));
                    }
                }
            }
        }
    }
};

const testing = std.testing;

test "stamp a two-line label without crashing and leave ink" {
    const gpa = testing.allocator;
    var src = img.Image8{
        .width = 200,
        .height = 150,
        .channels = 3,
        .pixels = try gpa.alloc(u8, 200 * 150 * 3),
    };
    defer src.deinit(gpa);
    @memset(src.pixels, 90);

    const st = Stamper.initBundled();
    var out = try st.resizeAndLabel(gpa, &src, .{
        .title = "Heart Nebula (IC 1805) & Fish Head Nebula (NGC 896)",
        .subtitle = "NGC 896  ·  Sh2-190  ·  Emission nebula  ·  RA 02h 32m 43s  Dec +61° 27′ 26″",
    });
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u32, TARGET_WIDTH), out.width);

    var white: usize = 0;
    for (out.pixels) |p| {
        if (p > 200) white += 1;
    }
    try testing.expect(white > 500); // the label drew a meaningful amount of ink
}

/// Scale `image` (aspect ratio kept) to cover `tw`x`th`, then centre-crop the
/// overflow to exactly `tw`x`th`. Caller owns the returned pixels.
pub fn resizeToFill(gpa: std.mem.Allocator, image: *const img.Image8, tw: u32, th: u32) !img.Image8 {
    const c: usize = image.channels;
    const sw: f64 = @floatFromInt(image.width);
    const sh: f64 = @floatFromInt(image.height);
    const scale = @max(@as(f64, @floatFromInt(tw)) / sw, @as(f64, @floatFromInt(th)) / sh);

    const rw: u32 = @intFromFloat(@ceil(sw * scale));
    const rh: u32 = @intFromFloat(@ceil(sh * scale));

    // Two-pass separable resample: horizontal then vertical.
    const tmp = try gpa.alloc(u8, @as(usize, rw) * image.height * c);
    defer gpa.free(tmp);
    resampleAxis(image.pixels, image.width, image.height, tmp, rw, c, true);

    const scaled = try gpa.alloc(u8, @as(usize, rw) * rh * c);
    defer gpa.free(scaled);
    resampleAxis(tmp, rw, image.height, scaled, rh, c, false);

    // Centre crop to tw x th.
    const ox = (rw - tw) / 2;
    const oy = (rh - th) / 2;
    const out = try gpa.alloc(u8, @as(usize, tw) * th * c);
    var y: usize = 0;
    while (y < th) : (y += 1) {
        const src = ((y + oy) * rw + ox) * c;
        const dst = y * tw * c;
        @memcpy(out[dst .. dst + tw * c], scaled[src .. src + tw * c]);
    }

    return .{ .width = tw, .height = th, .channels = image.channels, .pixels = out };
}

/// Resample along one axis with a triangle filter. When `horizontal`, `dst_len`
/// is the new width and rows stay put; otherwise `dst_len` is the new height
/// and columns stay put. `src` is `w` wide and `h` tall (in pixels), `c`
/// channels.
fn resampleAxis(src: []const u8, w: u32, h: u32, dst: []u8, dst_len: u32, c: usize, horizontal: bool) void {
    const src_len: u32 = if (horizontal) w else h;
    const ratio: f64 = @as(f64, @floatFromInt(src_len)) / @as(f64, @floatFromInt(dst_len));
    const filter_scale = @max(ratio, 1.0);
    const support = filter_scale; // triangle radius 1.0 in dst space

    const lines: u32 = if (horizontal) h else w;
    const dst_w: u32 = if (horizontal) dst_len else w;

    var line: u32 = 0;
    while (line < lines) : (line += 1) {
        var o: u32 = 0;
        while (o < dst_len) : (o += 1) {
            const center = (@as(f64, @floatFromInt(o)) + 0.5) * ratio - 0.5;
            const lo_f = @floor(center - support);
            const hi_f = @ceil(center + support);
            var lo: i64 = @intFromFloat(lo_f);
            var hi: i64 = @intFromFloat(hi_f);
            if (lo < 0) lo = 0;
            if (hi > @as(i64, src_len) - 1) hi = @as(i64, src_len) - 1;

            var acc = [_]f64{0} ** 4;
            var wsum: f64 = 0;
            var t: i64 = lo;
            while (t <= hi) : (t += 1) {
                const d = (@as(f64, @floatFromInt(t)) - center) / filter_scale;
                const weight = 1.0 - @abs(d);
                if (weight <= 0) continue;
                wsum += weight;
                var ch: usize = 0;
                while (ch < c) : (ch += 1) {
                    const si: usize = if (horizontal)
                        ((line * w) + @as(u32, @intCast(t))) * c + ch
                    else
                        ((@as(u32, @intCast(t)) * w) + line) * c + ch;
                    acc[ch] += @as(f64, @floatFromInt(src[si])) * weight;
                }
            }
            var ch: usize = 0;
            while (ch < c) : (ch += 1) {
                const v = if (wsum > 0) acc[ch] / wsum else 0;
                const clamped = std.math.clamp(v + 0.5, 0.0, 255.0);
                const di: usize = if (horizontal)
                    ((line * dst_w) + o) * c + ch
                else
                    ((o * dst_w) + line) * c + ch;
                dst[di] = @intFromFloat(clamped);
            }
        }
    }
}
