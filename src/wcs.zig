//! Sky coordinates from an image header: either the plate solution (WCS
//! keywords, i.e. where the frame really points) or the mount's target
//! coordinates (`RA`/`DEC`, `OBJCTRA`/`OBJCTDEC`). Used to cross-check the
//! object name and to identify unnamed frames.
//!
//! Port of the Rust `wcs.rs`.

const std = @import("std");
const math = std.math;

const DEG2RAD: f64 = math.pi / 180.0;
const RAD2DEG: f64 = 180.0 / math.pi;

/// Where the image is centred on the sky.
pub const SkyCoords = struct {
    ra_deg: f64,
    dec_deg: f64,
    /// Half the image diagonal in degrees, when the pixel scale is known.
    fov_radius_deg: ?f64 = null,
    /// True when derived from a plate solution (WCS) rather than the mount's
    /// intended target.
    solved: bool = false,

    /// How far a named object may sit from the image centre before we doubt
    /// the name.
    pub fn toleranceDeg(self: SkyCoords) f64 {
        return 2.0 + (self.fov_radius_deg orelse 0.0);
    }

    /// Radius for "what is at these coordinates?" searches.
    pub fn searchRadiusDeg(self: SkyCoords) f64 {
        return math.clamp(self.fov_radius_deg orelse 1.0, 0.25, 2.0);
    }

    pub fn separationTo(self: SkyCoords, ra_deg: f64, dec_deg: f64) f64 {
        return separationDeg(self.ra_deg, self.dec_deg, ra_deg, dec_deg);
    }
};

/// Keyword source. `getter` is anything with `fn get(self, key: []const u8) ?[]const u8`
/// returning the trimmed, unquoted value of a keyword.
pub fn fromKeywords(getter: anytype, width: u32, height: u32) ?SkyCoords {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);

    const num = struct {
        fn f(g: @TypeOf(getter), key: []const u8) ?f64 {
            return parseNumber(g.get(key) orelse return null);
        }
    }.f;

    // --- Plate solution --------------------------------------------------
    if (num(getter, "CRVAL1")) |crval1| if (num(getter, "CRVAL2")) |crval2| {
        const ctype_ok = if (getter.get("CTYPE1")) |t| startsWithIgnoreCase(t, "RA") else true;
        if (ctype_ok and crval1 >= 0.0 and crval1 <= 360.0 and crval2 >= -90.0 and crval2 <= 90.0) {
            // Linear part of the WCS, degrees per pixel.
            var cd: ?[4]f64 = null;
            if (num(getter, "CD1_1")) |a| {
                if (num(getter, "CD2_2")) |d| {
                    cd = .{ a, num(getter, "CD1_2") orelse 0.0, num(getter, "CD2_1") orelse 0.0, d };
                }
            }
            if (cd == null) {
                if (num(getter, "CDELT1")) |dx| if (num(getter, "CDELT2")) |dy| {
                    const rot = (num(getter, "CROTA2") orelse 0.0) * DEG2RAD;
                    cd = .{
                        dx * @cos(rot),
                        -dy * @sin(rot),
                        dx * @sin(rot),
                        dy * @cos(rot),
                    };
                };
            }

            var ra = crval1;
            var dec = crval2;
            var fov: ?f64 = null;
            if (cd) |m| {
                const a = m[0];
                const b = m[1];
                const c = m[2];
                const d = m[3];
                const scale = @sqrt(@abs(a * d - b * c));
                if (scale > 0.0 and scale < 1.0) {
                    fov = 0.5 * scale * math.hypot(w, h);
                }
                if (num(getter, "CRPIX1")) |crpix1| if (num(getter, "CRPIX2")) |crpix2| {
                    const dx = (w + 1.0) / 2.0 - crpix1;
                    const dy = (h + 1.0) / 2.0 - crpix2;
                    const xi = a * dx + b * dy;
                    const eta = c * dx + d * dy;
                    const cos_dec = @max(@cos(crval2 * DEG2RAD), 1e-6);
                    ra = remEuclid(crval1 + xi / cos_dec, 360.0);
                    dec = math.clamp(crval2 + eta, -90.0, 90.0);
                };
            }
            return .{ .ra_deg = ra, .dec_deg = dec, .fov_radius_deg = fov, .solved = true };
        }
    };

    // --- Mount / sequence target ---------------------------------------
    const ra = (if (getter.get("OBJCTRA")) |v| parseAngle(v, true) else null) orelse
        (if (getter.get("RA")) |v| parseAngle(v, false) else null) orelse
        (if (getter.get("OBJRA")) |v| parseAngle(v, false) else null) orelse
        return null;
    const dec = (if (getter.get("OBJCTDEC")) |v| parseAngle(v, false) else null) orelse
        (if (getter.get("DEC")) |v| parseAngle(v, false) else null) orelse
        (if (getter.get("OBJDEC")) |v| parseAngle(v, false) else null) orelse
        return null;

    if (ra < 0.0 or ra > 360.0 or dec < -90.0 or dec > 90.0) return null;

    var fov: ?f64 = null;
    if (num(getter, "XPIXSZ")) |pix| if (num(getter, "FOCALLEN")) |fl| {
        if (pix > 0.0 and fl > 0.0) {
            const bin = blk: {
                const b = num(getter, "XBINNING") orelse 1.0;
                break :blk if (b >= 1.0) b else 1.0;
            };
            const arcsec_per_px = 206.265 * pix * bin / fl;
            fov = 0.5 * arcsec_per_px / 3600.0 * math.hypot(w, h);
        }
    };

    return .{ .ra_deg = ra, .dec_deg = dec, .fov_radius_deg = fov, .solved = false };
}

fn remEuclid(v: f64, m: f64) f64 {
    const r = @mod(v, m);
    return if (r < 0.0) r + m else r;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (haystack[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toUpper(a) != std.ascii.toUpper(b)) return false;
    }
    return true;
}

/// Parse a plain number (FITS allows Fortran 'D' exponents).
pub fn parseNumber(s: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    for (trimmed, 0..) |c, i| {
        buf[i] = switch (c) {
            'D', 'd' => 'E',
            else => c,
        };
    }
    return std.fmt.parseFloat(f64, buf[0..trimmed.len]) catch null;
}

/// Parse an angle in degrees. Accepts decimal degrees, or sexagesimal
/// ("05 35 17.3", "05:35:17", "+41 16 08", "-05d23m28s"). `hours` says a
/// sexagesimal (or bare decimal) value is in hours and must be scaled by 15.
pub fn parseAngle(raw: []const u8, hours: bool) ?f64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;

    const sexagesimal = std.mem.indexOfAny(u8, s, " :hdm") != null;
    if (!sexagesimal) {
        const v = parseNumber(s) orelse return null;
        return if (hours) v * 15.0 else v;
    }

    const negative = s[0] == '-';
    const body = std.mem.trimStart(u8, s, "+-");
    var parts: [3]f64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, " :hdms'\"");
    while (it.next()) |tok| {
        if (n >= 3) return null;
        parts[n] = std.fmt.parseFloat(f64, tok) catch return null;
        n += 1;
    }
    if (n == 0) return null;

    var v = parts[0];
    if (n > 1) v += parts[1] / 60.0;
    if (n > 2) v += parts[2] / 3600.0;
    if (negative) v = -v;
    return if (hours) v * 15.0 else v;
}

/// Great-circle separation in degrees (haversine).
pub fn separationDeg(ra1_d: f64, dec1_d: f64, ra2_d: f64, dec2_d: f64) f64 {
    const ra1 = ra1_d * DEG2RAD;
    const dec1 = dec1_d * DEG2RAD;
    const ra2 = ra2_d * DEG2RAD;
    const dec2 = dec2_d * DEG2RAD;
    const s1 = @sin((dec2 - dec1) / 2.0);
    const s2 = @sin((ra2 - ra1) / 2.0);
    const hv = s1 * s1 + @cos(dec1) * @cos(dec2) * s2 * s2;
    return 2.0 * math.asin(math.clamp(@sqrt(hv), 0.0, 1.0)) * RAD2DEG;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

const MapGetter = struct {
    pairs: []const [2][]const u8,
    fn get(self: MapGetter, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p[0], key)) return p[1];
        }
        return null;
    }
};

test "angles" {
    try testing.expect(@abs(parseAngle("05 35 17.3", true).? - 83.822083) < 1e-4);
    try testing.expect(@abs(parseAngle("05:35:17", true).? - 83.820833) < 1e-4);
    try testing.expect(@abs(parseAngle("-05 23 28", false).? + 5.391111) < 1e-4);
    try testing.expect(@abs(parseAngle("+41 16 08", false).? - 41.268889) < 1e-4);
    try testing.expectEqual(@as(?f64, 83.82), parseAngle("83.82", false));
    try testing.expectEqual(@as(?f64, 82.5), parseAngle("5.5", true));
    try testing.expectEqual(@as(?f64, null), parseAngle("", false));
}

test "wcs centre and fov" {
    const m = MapGetter{ .pairs = &.{
        .{ "CTYPE1", "RA---TAN" }, .{ "CRVAL1", "314.7" }, .{ "CRVAL2", "44.33" },
        .{ "CRPIX1", "400.5" },    .{ "CRPIX2", "250.5" }, .{ "CD1_1", "-0.000555556" },
        .{ "CD1_2", "0" },         .{ "CD2_1", "0" },      .{ "CD2_2", "0.000555556" },
    } };
    const c = fromKeywords(m, 800, 500).?;
    try testing.expect(c.solved);
    try testing.expect(@abs(c.ra_deg - 314.7) < 1e-6 and @abs(c.dec_deg - 44.33) < 1e-6);
    try testing.expect(@abs(c.fov_radius_deg.? - 0.262) < 0.002);

    const m2 = MapGetter{ .pairs = &.{
        .{ "CRVAL1", "100.0" },  .{ "CRVAL2", "0.0" },   .{ "CRPIX1", "0.5" }, .{ "CRPIX2", "0.5" },
        .{ "CDELT1", "-0.001" }, .{ "CDELT2", "0.001" },
    } };
    const c2 = fromKeywords(m2, 1000, 1000).?;
    try testing.expect(@abs(c2.ra_deg - 99.5) < 1e-6 and @abs(c2.dec_deg - 0.5) < 1e-6);
}

test "target coords" {
    const m = MapGetter{ .pairs = &.{
        .{ "OBJCTRA", "00 42 44" }, .{ "OBJCTDEC", "+41 16 08" },
        .{ "XPIXSZ", "3.76" },      .{ "FOCALLEN", "400" },
        .{ "RA", "999" },
    } };
    const c = fromKeywords(m, 6248, 4176).?;
    try testing.expect(!c.solved);
    try testing.expect(@abs(c.ra_deg - 10.6833) < 1e-3);
    try testing.expect(c.fov_radius_deg.? > 1.9 and c.fov_radius_deg.? < 2.1);

    const m2 = MapGetter{ .pairs = &.{ .{ "RA", "83.82" }, .{ "DEC", "-5.39" } } };
    const c2 = fromKeywords(m2, 100, 100).?;
    try testing.expectEqual(@as(f64, 83.82), c2.ra_deg);
    try testing.expectEqual(@as(f64, -5.39), c2.dec_deg);
    try testing.expectEqual(@as(?f64, null), c2.fov_radius_deg);

    const empty = MapGetter{ .pairs = &.{} };
    try testing.expectEqual(@as(?SkyCoords, null), fromKeywords(empty, 100, 100));
}

test "separation" {
    try testing.expect(@abs(separationDeg(10.0, 40.0, 10.0, 40.0)) < 1e-9);
    try testing.expect(@abs(separationDeg(0.0, 0.0, 1.0, 0.0) - 1.0) < 1e-9);
    try testing.expect(@abs(separationDeg(0.0, 89.0, 180.0, 89.0) - 2.0) < 1e-6);
}
