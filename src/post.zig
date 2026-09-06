//! Post-processing: resize to exactly 3840x2160 (cover + centre crop) and
//! (TODO) stamp the object name in the bottom-right corner.
//!
//! Partial port of the Rust `post.rs`: the resize is implemented with a
//! separable triangle (bilinear) filter; the text stamp is not wired up yet
//! (needs the TrueType rasteriser — see `ttf.zig`).

const std = @import("std");
const img = @import("image.zig");

pub const TARGET_WIDTH: u32 = 3840;
pub const TARGET_HEIGHT: u32 = 2160;

pub const Label = struct {
    title: []const u8,
    subtitle: ?[]const u8 = null,
};

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
