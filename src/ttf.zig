//! A small TrueType / OpenType(glyf) reader and glyph rasteriser — enough to
//! draw the bottom-right corner label. Parses `cmap` (formats 4 and 12),
//! `head`, `hhea`, `hmtx`, `maxp`, `loca`, `glyf` (simple + composite) and the
//! legacy `kern` table (format 0).
//!
//! The rasteriser flattens the quadratic outline to line segments and fills it
//! with a non-zero winding scanline rule, vertically supersampled with
//! analytic horizontal coverage — good enough for text at 30–48 px.
//!
//! Replaces the Rust code's `ab_glyph` dependency.

const std = @import("std");

pub const Error = error{ BadFont, UnsupportedCmap, OutOfMemory };

fn rdU16(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .big);
}
fn rdI16(d: []const u8, o: usize) i16 {
    return std.mem.readInt(i16, d[o..][0..2], .big);
}
fn rdU32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    ascent_fu: i16,
    descent_fu: i16,
    line_gap_fu: i16,
    num_glyphs: u16,
    num_h_metrics: u16,
    hmtx_off: usize,
    loca_off: usize,
    loca_long: bool,
    glyf_off: usize,
    // cmap
    cmap_off: usize,
    cmap_format: u16,
    // kern format 0
    kern_off: usize = 0,
    kern_pairs: u16 = 0,

    pub fn parse(data: []const u8) Error!Font {
        if (data.len < 12) return error.BadFont;
        const num_tables = rdU16(data, 4);

        var head_off: usize = 0;
        var hhea_off: usize = 0;
        var maxp_off: usize = 0;
        var f = Font{
            .data = data,
            .units_per_em = 1000,
            .ascent_fu = 0,
            .descent_fu = 0,
            .line_gap_fu = 0,
            .num_glyphs = 0,
            .num_h_metrics = 0,
            .hmtx_off = 0,
            .loca_off = 0,
            .loca_long = false,
            .glyf_off = 0,
            .cmap_off = 0,
            .cmap_format = 0,
        };

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return error.BadFont;
            const tag = data[rec .. rec + 4];
            const off = rdU32(data, rec + 8);
            const len = rdU32(data, rec + 12);
            if (off + len > data.len) continue;
            if (std.mem.eql(u8, tag, "head")) head_off = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea_off = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp_off = off;
            if (std.mem.eql(u8, tag, "hmtx")) f.hmtx_off = off;
            if (std.mem.eql(u8, tag, "loca")) f.loca_off = off;
            if (std.mem.eql(u8, tag, "glyf")) f.glyf_off = off;
            if (std.mem.eql(u8, tag, "cmap")) f.cmap_off = off;
            if (std.mem.eql(u8, tag, "kern")) parseKern(&f, data, off, len);
        }
        if (head_off == 0 or hhea_off == 0 or maxp_off == 0 or f.glyf_off == 0 or f.loca_off == 0 or f.cmap_off == 0)
            return error.BadFont;

        f.units_per_em = rdU16(data, head_off + 18);
        if (f.units_per_em == 0) f.units_per_em = 1000;
        f.loca_long = rdI16(data, head_off + 50) == 1;

        f.ascent_fu = rdI16(data, hhea_off + 4);
        f.descent_fu = rdI16(data, hhea_off + 6);
        f.line_gap_fu = rdI16(data, hhea_off + 8);
        f.num_h_metrics = rdU16(data, hhea_off + 34);

        f.num_glyphs = rdU16(data, maxp_off + 4);

        try selectCmap(&f, data);
        return f;
    }

    fn parseKern(f: *Font, d: []const u8, off: usize, len: usize) void {
        if (len < 4 or rdU16(d, off) != 0) return;
        const n_tables = rdU16(d, off + 2);
        if (n_tables == 0) return;
        const sub = off + 4;
        if (sub + 6 > d.len) return;
        const coverage = rdU16(d, sub + 4);
        if (coverage >> 8 != 0) return; // only format 0
        f.kern_off = sub + 6 + 8; // skip nPairs + search fields to the pairs
        f.kern_pairs = rdU16(d, sub + 6);
    }

    fn selectCmap(f: *Font, d: []const u8) Error!void {
        const base = f.cmap_off;
        const n = rdU16(d, base + 2);
        var best_off: usize = 0;
        var best_score: i32 = -1;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const rec = base + 4 + k * 8;
            if (rec + 8 > d.len) break;
            const plat = rdU16(d, rec);
            const enc = rdU16(d, rec + 2);
            const sub_off = base + rdU32(d, rec + 4);
            if (sub_off + 4 > d.len) continue;
            const fmt = rdU16(d, sub_off);
            const score: i32 = blk: {
                if (plat == 3 and enc == 10 and fmt == 12) break :blk 5;
                if (plat == 0 and fmt == 12) break :blk 4;
                if (plat == 3 and enc == 1 and fmt == 4) break :blk 3;
                if (plat == 0 and fmt == 4) break :blk 2;
                if (fmt == 4 or fmt == 12) break :blk 1;
                break :blk -1;
            };
            if (score > best_score) {
                best_score = score;
                best_off = sub_off;
            }
        }
        if (best_off == 0) return error.UnsupportedCmap;
        f.cmap_off = best_off;
        f.cmap_format = rdU16(d, best_off);
    }

    pub fn unitsPerEm(f: Font) f32 {
        return @floatFromInt(f.units_per_em);
    }
    pub fn ascent(f: Font) f32 {
        return @floatFromInt(f.ascent_fu);
    }
    pub fn descent(f: Font) f32 {
        return @floatFromInt(f.descent_fu);
    }

    /// Glyph index for a Unicode code point (0 = .notdef / missing).
    pub fn glyphId(f: Font, cp: u21) u16 {
        const d = f.data;
        const base = f.cmap_off;
        if (f.cmap_format == 4) {
            const seg_x2 = rdU16(d, base + 6);
            const seg_count = seg_x2 / 2;
            const end_codes = base + 14;
            const start_codes = end_codes + seg_x2 + 2;
            const id_deltas = start_codes + seg_x2;
            const id_range_offsets = id_deltas + seg_x2;
            if (cp > 0xffff) return 0;
            const c: u16 = @intCast(cp);
            var s: usize = 0;
            while (s < seg_count) : (s += 1) {
                if (c <= rdU16(d, end_codes + s * 2)) {
                    const start = rdU16(d, start_codes + s * 2);
                    if (c < start) return 0;
                    const id_delta = rdI16(d, id_deltas + s * 2);
                    const id_range_offset = rdU16(d, id_range_offsets + s * 2);
                    if (id_range_offset == 0) {
                        return @truncate(@as(u32, c) +% @as(u16, @bitCast(id_delta)));
                    }
                    const gi_addr = id_range_offsets + s * 2 + id_range_offset + (c - start) * 2;
                    if (gi_addr + 2 > d.len) return 0;
                    const g = rdU16(d, gi_addr);
                    if (g == 0) return 0;
                    return @truncate(@as(u32, g) +% @as(u16, @bitCast(id_delta)));
                }
            }
            return 0;
        } else if (f.cmap_format == 12) {
            const n_groups = rdU32(d, base + 12);
            var g: usize = 0;
            while (g < n_groups) : (g += 1) {
                const rec = base + 16 + g * 12;
                if (rec + 12 > d.len) return 0;
                const first = rdU32(d, rec);
                const last = rdU32(d, rec + 4);
                if (cp >= first and cp <= last) {
                    return @truncate(rdU32(d, rec + 8) + (cp - first));
                }
            }
            return 0;
        }
        return 0;
    }

    /// Horizontal advance in font units.
    pub fn advance(f: Font, gid: u16) f32 {
        const idx = if (gid < f.num_h_metrics) gid else f.num_h_metrics - 1;
        return @floatFromInt(rdU16(f.data, f.hmtx_off + idx * 4));
    }

    /// Kerning adjustment between two glyphs in font units (legacy `kern`).
    pub fn kern(f: Font, left: u16, right: u16) f32 {
        if (f.kern_pairs == 0) return 0;
        const key = (@as(u32, left) << 16) | right;
        var lo: usize = 0;
        var hi: usize = f.kern_pairs;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = f.kern_off + mid * 6;
            if (rec + 6 > f.data.len) break;
            const k = (@as(u32, rdU16(f.data, rec)) << 16) | rdU16(f.data, rec + 2);
            if (k == key) return @floatFromInt(rdI16(f.data, rec + 4));
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return 0;
    }

    fn glyfRange(f: Font, gid: u16) ?struct { start: usize, end: usize } {
        if (gid >= f.num_glyphs) return null;
        const d = f.data;
        var start: usize = undefined;
        var end: usize = undefined;
        if (f.loca_long) {
            start = rdU32(d, f.loca_off + gid * 4);
            end = rdU32(d, f.loca_off + (gid + 1) * 4);
        } else {
            start = @as(usize, rdU16(d, f.loca_off + gid * 2)) * 2;
            end = @as(usize, rdU16(d, f.loca_off + (gid + 1) * 2)) * 2;
        }
        if (end <= start) return null; // empty glyph (space)
        return .{ .start = f.glyf_off + start, .end = f.glyf_off + end };
    }

    const Pt = struct { x: f32, y: f32, on: bool };

    /// Append the glyph's contours (as on/off-curve points, font units, y-up)
    /// to `points`, with contour end indices in `ends`. Handles composites.
    fn collectContours(
        f: Font,
        gid: u16,
        dx: f32,
        dy: f32,
        depth: u8,
        points: *std.ArrayList(Pt),
        ends: *std.ArrayList(usize),
        gpa: std.mem.Allocator,
    ) Error!void {
        if (depth > 5) return;
        const r = f.glyfRange(gid) orelse return;
        const d = f.data;
        var o = r.start;
        if (o + 10 > d.len) return;
        const n_contours = rdI16(d, o);
        o += 10;

        if (n_contours >= 0) {
            const nc: usize = @intCast(n_contours);
            var end_pts = try gpa.alloc(u16, nc);
            defer gpa.free(end_pts);
            var ci: usize = 0;
            while (ci < nc) : (ci += 1) {
                end_pts[ci] = rdU16(d, o);
                o += 2;
            }
            const n_points: usize = if (nc == 0) 0 else @as(usize, end_pts[nc - 1]) + 1;
            const instr_len = rdU16(d, o);
            o += 2 + instr_len;

            // flags
            var flags = try gpa.alloc(u8, n_points);
            defer gpa.free(flags);
            var fi: usize = 0;
            while (fi < n_points) {
                const fl = d[o];
                o += 1;
                flags[fi] = fl;
                fi += 1;
                if (fl & 0x08 != 0) { // repeat
                    var rep = d[o];
                    o += 1;
                    while (rep > 0 and fi < n_points) : (rep -= 1) {
                        flags[fi] = fl;
                        fi += 1;
                    }
                }
            }

            // x coords
            var xs = try gpa.alloc(f32, n_points);
            defer gpa.free(xs);
            var ys = try gpa.alloc(f32, n_points);
            defer gpa.free(ys);
            var acc: i32 = 0;
            var pi: usize = 0;
            while (pi < n_points) : (pi += 1) {
                const fl = flags[pi];
                if (fl & 0x02 != 0) { // x short
                    const v: i32 = d[o];
                    o += 1;
                    acc += if (fl & 0x10 != 0) v else -v;
                } else if (fl & 0x10 == 0) {
                    acc += rdI16(d, o);
                    o += 2;
                }
                xs[pi] = @floatFromInt(acc);
            }
            acc = 0;
            pi = 0;
            while (pi < n_points) : (pi += 1) {
                const fl = flags[pi];
                if (fl & 0x04 != 0) { // y short
                    const v: i32 = d[o];
                    o += 1;
                    acc += if (fl & 0x20 != 0) v else -v;
                } else if (fl & 0x20 == 0) {
                    acc += rdI16(d, o);
                    o += 2;
                }
                ys[pi] = @floatFromInt(acc);
            }

            var startp: usize = 0;
            for (end_pts) |ep| {
                const last: usize = ep;
                var k = startp;
                while (k <= last) : (k += 1) {
                    try points.append(gpa, .{ .x = xs[k] + dx, .y = ys[k] + dy, .on = flags[k] & 0x01 != 0 });
                }
                try ends.append(gpa, points.items.len);
                startp = last + 1;
            }
        } else {
            // composite
            while (true) {
                const comp_flags = rdU16(d, o);
                const comp_gid = rdU16(d, o + 2);
                o += 4;
                var arg1: i32 = 0;
                var arg2: i32 = 0;
                if (comp_flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                    arg1 = rdI16(d, o);
                    arg2 = rdI16(d, o + 2);
                    o += 4;
                } else {
                    arg1 = @as(i8, @bitCast(d[o]));
                    arg2 = @as(i8, @bitCast(d[o + 1]));
                    o += 2;
                }
                // Skip scale info (we ignore scaling of components — rare in
                // text fonts, and the label copes without it).
                if (comp_flags & 0x0008 != 0) o += 2 // WE_HAVE_A_SCALE
                else if (comp_flags & 0x0040 != 0) o += 4 // X_AND_Y_SCALE
                else if (comp_flags & 0x0080 != 0) o += 8; // 2x2

                const cdx: f32 = if (comp_flags & 0x0002 != 0) @floatFromInt(arg1) else 0;
                const cdy: f32 = if (comp_flags & 0x0002 != 0) @floatFromInt(arg2) else 0;
                try f.collectContours(comp_gid, dx + cdx, dy + cdy, depth + 1, points, ends, gpa);

                if (comp_flags & 0x0020 == 0) break; // MORE_COMPONENTS
            }
        }
    }

    /// Rasterise glyph `gid` at `px_scale` font-units-to-pixels, offset by the
    /// sub-pixel fraction (`frac_x`, `frac_y`). Returns a coverage bitmap and
    /// its integer offset from the pen origin (y-down). `null` for empty glyphs.
    pub fn rasterize(f: Font, gpa: std.mem.Allocator, gid: u16, px_scale: f32, frac_x: f32, frac_y: f32) Error!?Glyph {
        var points: std.ArrayList(Pt) = .empty;
        defer points.deinit(gpa);
        var ends: std.ArrayList(usize) = .empty;
        defer ends.deinit(gpa);
        try f.collectContours(gid, 0, 0, 0, &points, &ends, gpa);
        if (points.items.len == 0 or ends.items.len == 0) return null;

        // Flatten to device-space edges (y-down). device_x = x*scale + frac_x
        // (relative to pen), device_y = -y*scale + frac_y.
        var edges: std.ArrayList([4]f32) = .empty; // x0,y0,x1,y1
        defer edges.deinit(gpa);

        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        const tx = struct {
            fn x(p: Pt, s: f32, fx: f32) f32 {
                return p.x * s + fx;
            }
            fn y(p: Pt, s: f32, fy: f32) f32 {
                return -p.y * s + fy;
            }
        };

        var start: usize = 0;
        for (ends.items) |end| {
            const n = end - start;
            if (n >= 2) {
                // Build a closed list of on-curve/off-curve, inserting implied
                // midpoints between consecutive off-curve points.
                var seq: std.ArrayList(Pt) = .empty;
                defer seq.deinit(gpa);
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    const cur = points.items[start + k];
                    if (seq.items.len > 0) {
                        const prev = seq.items[seq.items.len - 1];
                        if (!prev.on and !cur.on) {
                            try seq.append(gpa, .{ .x = (prev.x + cur.x) / 2, .y = (prev.y + cur.y) / 2, .on = true });
                        }
                    }
                    try seq.append(gpa, cur);
                }
                // Ensure it starts on-curve.
                if (!seq.items[0].on) {
                    const lastp = seq.items[seq.items.len - 1];
                    if (lastp.on) {
                        try seq.insert(gpa, 0, lastp);
                        _ = seq.pop();
                    } else {
                        const mid = Pt{ .x = (seq.items[0].x + lastp.x) / 2, .y = (seq.items[0].y + lastp.y) / 2, .on = true };
                        try seq.insert(gpa, 0, mid);
                    }
                }

                const m = seq.items.len;
                var cur_on = seq.items[0];
                var j: usize = 1;
                while (j <= m) : (j += 1) {
                    const a = seq.items[j % m];
                    if (a.on) {
                        try pushLine(gpa, &edges, tx.x(cur_on, px_scale, frac_x), tx.y(cur_on, px_scale, frac_y), tx.x(a, px_scale, frac_x), tx.y(a, px_scale, frac_y), &min_x, &min_y, &max_x, &max_y);
                        cur_on = a;
                    } else {
                        const b = seq.items[(j + 1) % m];
                        const p0 = cur_on;
                        const p1 = a;
                        const p2 = b;
                        const steps: usize = 10;
                        var t_i: usize = 1;
                        var prevx = tx.x(p0, px_scale, frac_x);
                        var prevy = tx.y(p0, px_scale, frac_y);
                        while (t_i <= steps) : (t_i += 1) {
                            const t = @as(f32, @floatFromInt(t_i)) / @as(f32, @floatFromInt(steps));
                            const mt = 1 - t;
                            const qx = mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x;
                            const qy = mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y;
                            const qp = Pt{ .x = qx, .y = qy, .on = true };
                            const cx = tx.x(qp, px_scale, frac_x);
                            const cy = tx.y(qp, px_scale, frac_y);
                            try pushLine(gpa, &edges, prevx, prevy, cx, cy, &min_x, &min_y, &max_x, &max_y);
                            prevx = cx;
                            prevy = cy;
                        }
                        cur_on = p2;
                        j += 1;
                    }
                }
            }
            start = end;
        }

        if (edges.items.len == 0) return null;

        const left: i32 = @intFromFloat(@floor(min_x));
        const top: i32 = @intFromFloat(@floor(min_y));
        const right: i32 = @intFromFloat(@ceil(max_x));
        const bottom: i32 = @intFromFloat(@ceil(max_y));
        const w: usize = @intCast(@max(right - left, 1));
        const h: usize = @intCast(@max(bottom - top, 1));

        const cov = try gpa.alloc(f32, w * h);
        @memset(cov, 0);

        const ss: usize = 5;
        const inv_ss: f32 = 1.0 / @as(f32, @floatFromInt(ss));
        const off_x: f32 = @floatFromInt(left);
        const off_y: f32 = @floatFromInt(top);

        var xs_buf: std.ArrayList([2]f32) = .empty; // x, dir
        defer xs_buf.deinit(gpa);

        var row: usize = 0;
        while (row < h) : (row += 1) {
            var sub: usize = 0;
            while (sub < ss) : (sub += 1) {
                const sy = off_y + @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sub)) + 0.5) * inv_ss;
                xs_buf.clearRetainingCapacity();
                for (edges.items) |e| {
                    const y0 = e[1];
                    const y1 = e[3];
                    if ((y0 <= sy) == (y1 <= sy)) continue;
                    const t = (sy - y0) / (y1 - y0);
                    const x = e[0] + t * (e[2] - e[0]);
                    const dir: f32 = if (y1 > y0) 1 else -1;
                    xs_buf.append(gpa, .{ x, dir }) catch return error.OutOfMemory;
                }
                if (xs_buf.items.len < 2) continue;
                std.mem.sort([2]f32, xs_buf.items, {}, struct {
                    fn lt(_: void, a: [2]f32, b: [2]f32) bool {
                        return a[0] < b[0];
                    }
                }.lt);
                var wind: f32 = 0;
                var k: usize = 0;
                while (k + 1 < xs_buf.items.len) : (k += 1) {
                    wind += xs_buf.items[k][1];
                    if (wind == 0) continue;
                    addSpan(cov, w, row, xs_buf.items[k][0] - off_x, xs_buf.items[k + 1][0] - off_x, inv_ss);
                }
            }
        }

        return .{ .left = left, .top = top, .w = @intCast(w), .h = @intCast(h), .coverage = cov };
    }
};

fn pushLine(gpa: std.mem.Allocator, edges: *std.ArrayList([4]f32), x0: f32, y0: f32, x1: f32, y1: f32, min_x: *f32, min_y: *f32, max_x: *f32, max_y: *f32) !void {
    try edges.append(gpa, .{ x0, y0, x1, y1 });
    min_x.* = @min(min_x.*, @min(x0, x1));
    min_y.* = @min(min_y.*, @min(y0, y1));
    max_x.* = @max(max_x.*, @max(x0, x1));
    max_y.* = @max(max_y.*, @max(y0, y1));
}

fn addSpan(cov: []f32, w: usize, row: usize, x0_in: f32, x1_in: f32, weight: f32) void {
    var x0 = std.math.clamp(x0_in, 0, @as(f32, @floatFromInt(w)));
    var x1 = std.math.clamp(x1_in, 0, @as(f32, @floatFromInt(w)));
    if (x1 <= x0) return;
    if (x0 < 0) x0 = 0;
    if (x1 < 0) x1 = 0;
    const base = row * w;
    const ix0: usize = @intFromFloat(@floor(x0));
    const ix1: usize = @intFromFloat(@floor(x1));
    if (ix0 == ix1) {
        if (ix0 < w) cov[base + ix0] += weight * (x1 - x0);
        return;
    }
    if (ix0 < w) cov[base + ix0] += weight * (@as(f32, @floatFromInt(ix0 + 1)) - x0);
    var ix = ix0 + 1;
    while (ix < ix1 and ix < w) : (ix += 1) cov[base + ix] += weight;
    if (ix1 < w) cov[base + ix1] += weight * (x1 - @as(f32, @floatFromInt(ix1)));
}

pub const Glyph = struct {
    left: i32,
    top: i32,
    w: u32,
    h: u32,
    /// Row-major coverage, `w*h` floats in 0..1 (may slightly exceed 1).
    coverage: []f32,

    pub fn deinit(self: *Glyph, gpa: std.mem.Allocator) void {
        gpa.free(self.coverage);
    }
};

const testing = std.testing;

test "parse bundled font and rasterise a glyph" {
    const font_bytes = @embedFile("dejavu_font");
    const f = try Font.parse(font_bytes);
    try testing.expect(f.units_per_em > 0);
    try testing.expect(f.num_glyphs > 100);

    const gid = f.glyphId('A');
    try testing.expect(gid != 0);
    try testing.expect(f.advance(gid) > 0);

    const scale = 48.0 / f.unitsPerEm();
    var g = (try f.rasterize(testing.allocator, gid, scale, 0, 0)).?;
    defer g.deinit(testing.allocator);
    try testing.expect(g.w > 5 and g.h > 5);

    var ink: f32 = 0;
    for (g.coverage) |c| ink += c;
    try testing.expect(ink > 1.0); // the glyph actually drew something
}
