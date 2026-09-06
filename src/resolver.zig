//! The online object resolver: CDS Sesame (name → object) and SIMBAD TAP
//! (cone search) over HTTPS, with per-run caching, plus the `identify`
//! decision function that turns a header OBJECT / file-name / coordinates into
//! the two-line label to stamp.
//!
//! Port of the `Resolver` and `identify` parts of the Rust `lookup.rs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;

const lk = @import("lookup.zig");
const catalog = @import("catalog.zig");
const wcs = @import("wcs.zig");
const post = @import("post.zig");

const ObjectInfo = lk.ObjectInfo;
pub const Label = post.Label;

const USER_AGENT = "astro2png (+https://github.com/peterbuitho/Astro2PNG)";

const ConeKind = enum { any_dso, named_nebula };

pub const Resolver = struct {
    gpa: Allocator,
    arena: Allocator, // long-lived: ObjectInfo + strings for the whole run
    io: std.Io,
    enabled: bool,
    client: ?http.Client = null,
    cache: std.StringHashMapUnmanaged(?*ObjectInfo) = .empty,
    nearby_cache: std.StringHashMapUnmanaged(?*ObjectInfo) = .empty,
    failure: ?[]const u8 = null,

    pub fn init(gpa: Allocator, arena: Allocator, io: std.Io, enabled: bool) Resolver {
        return .{
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .enabled = enabled,
            .client = if (enabled) http.Client{ .allocator = gpa, .io = io } else null,
        };
    }

    pub fn deinit(self: *Resolver) void {
        if (self.client) |*c| c.deinit();
        self.cache.deinit(self.gpa);
        self.nearby_cache.deinit(self.gpa);
    }

    pub fn enabledNow(self: *const Resolver) bool {
        return self.enabled and self.failure == null;
    }

    fn httpGet(self: *Resolver, url: []const u8) ![]const u8 {
        const client = &(self.client orelse return error.Disabled);
        var body: std.Io.Writer.Allocating = .init(self.arena);
        const res = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
            .extra_headers = &.{.{ .name = "user-agent", .value = USER_AGENT }},
        }) catch return error.RequestFailed;
        if (res.status != .ok) return error.BadStatus;
        return body.toOwnedSlice() catch error.OutOfMemory;
    }

    /// Look a name up. `null` when disabled, not found, or after a failure.
    pub fn resolve(self: *Resolver, query_in: []const u8) ?*const ObjectInfo {
        if (!self.enabledNow()) return null;
        var kb: [128]u8 = undefined;
        const key = lk.normalize(query_in, &kb) catch return null;
        if (key.len == 0) return null;

        if (self.cache.get(key)) |cached| return cached;

        // "C 7" means Caldwell 7 to an astrophotographer; SIMBAD would not know.
        const query = catalog.caldwellTarget(query_in) orelse query_in;

        var result = self.fetchSesame(query);
        if (result) |r| {
            if (r == null) {
                if (spelledOut(self.arena, query) catch null) |alt| {
                    result = self.fetchSesame(alt);
                }
            }
        } else |_| {}

        const info: ?*ObjectInfo = result catch |e| {
            self.failure = @errorName(e);
            return null;
        };
        const key_dup = self.arena.dupe(u8, key) catch return null;
        self.cache.put(self.gpa, key_dup, info) catch {};
        return info;
    }

    fn fetchSesame(self: *Resolver, query: []const u8) !?*ObjectInfo {
        const enc = try percentEncode(self.arena, std.mem.trim(u8, query, " \t"));
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ lk.SESAME_URL, enc });
        const body = try self.httpGet(url);
        return lk.parseSesame(self.arena, body) catch error.BadResponse;
    }

    pub fn nearby(self: *Resolver, ra: f64, dec: f64, radius: f64) ?*const ObjectInfo {
        return self.cone(ra, dec, radius, .any_dso);
    }
    pub fn nearbyNamedNebula(self: *Resolver, ra: f64, dec: f64, radius: f64) ?*const ObjectInfo {
        return self.cone(ra, dec, radius, .named_nebula);
    }

    fn cone(self: *Resolver, ra: f64, dec: f64, radius: f64, kind: ConeKind) ?*const ObjectInfo {
        if (!self.enabledNow()) return null;
        var kb: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}|{d:.2}|{d:.2}|{d:.2}", .{ @tagName(kind), ra, dec, radius }) catch return null;
        if (self.nearby_cache.get(key)) |cached| return cached;

        const info: ?*ObjectInfo = self.coneSearch(ra, dec, radius, kind) catch |e| {
            self.failure = @errorName(e);
            return null;
        };
        const key_dup = self.arena.dupe(u8, key) catch return null;
        self.nearby_cache.put(self.gpa, key_dup, info) catch {};
        return info;
    }

    fn coneSearch(self: *Resolver, ra: f64, dec: f64, radius: f64, kind: ConeKind) !?*ObjectInfo {
        const types = if (kind == .any_dso) &lk.DSO_TYPES else &lk.NEBULA_TYPES;
        var type_list: std.ArrayList(u8) = .empty;
        for (types, 0..) |t, i| {
            if (i != 0) try type_list.append(self.arena, ',');
            try type_list.append(self.arena, '\'');
            try type_list.appendSlice(self.arena, t);
            try type_list.append(self.arena, '\'');
        }
        const name_filter: []const u8 = if (kind == .named_nebula) " AND i.ids LIKE '%NAME %'" else "";
        const adql = try std.fmt.allocPrint(
            self.arena,
            "SELECT TOP 400 b.main_id, b.otype, b.ra, b.dec, " ++
                "DISTANCE(POINT('ICRS', b.ra, b.dec), POINT('ICRS', {d:.6}, {d:.6})) AS d, i.ids, b.morph_type " ++
                "FROM basic AS b JOIN ids AS i ON i.oidref = b.oid " ++
                "WHERE CONTAINS(POINT('ICRS', b.ra, b.dec), CIRCLE('ICRS', {d:.6}, {d:.6}, {d:.4})) = 1 " ++
                "AND b.otype IN ({s}){s} ORDER BY d ASC",
            .{ ra, dec, ra, dec, radius, type_list.items, name_filter },
        );
        const enc = try percentEncode(self.arena, adql);
        const url = try std.fmt.allocPrint(self.arena, "{s}?request=doQuery&lang=adql&format=tsv&query={s}", .{ lk.TAP_URL, enc });
        const body = try self.httpGet(url);
        return lk.pickFromTapTsv(self.arena, body, kind == .named_nebula) catch error.BadResponse;
    }

    /// If `info` is a cluster/nebula without a common name, borrow the name of
    /// the named nebula it sits in, if SIMBAD has one at the same position.
    pub fn adoptCompanionNebula(self: *Resolver, info: *ObjectInfo) void {
        if (info.common_name != null) return;
        const ot = std.mem.trimEnd(u8, info.otype, "?");
        var host = false;
        for (lk.COMPANION_HOST_TYPES) |t| {
            if (std.mem.eql(u8, ot, t)) host = true;
        }
        if (!host) return;
        const ra = info.ra_deg orelse return;
        const dec = info.dec_deg orelse return;
        const neb = self.nearbyNamedNebula(ra, dec, lk.COMPANION_RADIUS_DEG) orelse return;
        if (neb.sameObject(info)) return;

        info.common_name = neb.common_name;
        for (neb.designations) |d| {
            var present = false;
            for (info.designations) |e| {
                if (std.mem.eql(u8, e, d)) present = true;
            }
            if (!present) {
                var list = std.ArrayList([]const u8).fromOwnedSlice(info.designations);
                list.append(self.arena, d) catch return;
                info.designations = list.items;
            }
        }
        var it = neb.aliases_norm.keyIterator();
        while (it.next()) |k| info.aliases_norm.put(self.arena, k.*, {}) catch {};
        info.otype = neb.otype;
    }
};

pub const Identification = struct {
    label: Label,
    note: ?[]const u8 = null,
};

const Named = struct {
    info: *ObjectInfo,
    preferred: ?[]const u8,
    note: ?[]const u8,
};

/// Work out what to stamp, given the header OBJECT (if any), the header
/// coordinates (if any) and the file-name stem.
pub fn identify(
    resolver: *Resolver,
    header_object: ?[]const u8,
    coords: ?wcs.SkyCoords,
    stem: []const u8,
) Identification {
    const arena = resolver.arena;
    const fallback = Identification{ .label = .{ .title = stem } };
    if (!resolver.enabledNow()) return fallback;

    var db: [32]u8 = undefined;
    const file_desig: ?[]const u8 = if (lk.designationInName(stem, &db)) |d| (arena.dupe(u8, d) catch null) else null;

    const header: ?[]const u8 = blk: {
        const h = header_object orelse break :blk null;
        const t = std.mem.trim(u8, std.mem.trim(u8, std.mem.trim(u8, h, " \t"), "'"), " \t");
        break :blk if (t.len == 0) null else t;
    };

    var named = identifyByName(resolver, header, file_desig);
    if (named) |*n| resolver.adoptCompanionNebula(n.info);

    if (coords) |c| {
        if (named) |nm| {
            const ra = nm.info.ra_deg;
            const dec = nm.info.dec_deg;
            if (ra == null or dec == null) {
                return .{ .label = compose(arena, nm.info, nm.preferred), .note = nm.note };
            }
            const sep = c.separationTo(ra.?, dec.?);
            if (sep <= c.toleranceDeg()) {
                if (sep <= c.searchRadiusDeg()) {
                    if (resolver.nearby(c.ra_deg, c.dec_deg, c.searchRadiusDeg())) |centre_c| {
                        var centre = centre_c.*;
                        resolver.adoptCompanionNebula(&centre);
                        if (!centre.sameObject(nm.info) and centre.isNotable() and !sameRegion(&centre, nm.info)) {
                            const what = nm.preferred orelse nm.info.main_id;
                            const at = actualTitle(arena, &centre);
                            var note = std.fmt.allocPrint(arena, "frame is centred on {s}; {s} is {d:.1}\u{00b0} off-centre, both in the field", .{ at, what, sep }) catch "";
                            if (nm.note) |pn| note = std.fmt.allocPrint(arena, "{s}; {s}", .{ pn, note }) catch note;
                            return .{ .label = composePair(arena, nm.info, nm.preferred, &centre, c), .note = note };
                        }
                    }
                }
                return .{ .label = compose(arena, nm.info, nm.preferred), .note = nm.note };
            }

            // Name does not fit where the frame points.
            const where_from: []const u8 = if (c.solved) "plate solution" else "header coordinates";
            const what = nm.preferred orelse nm.info.main_id;
            if (resolver.nearby(c.ra_deg, c.dec_deg, c.searchRadiusDeg())) |actual_c| {
                var actual = actual_c.*;
                resolver.adoptCompanionNebula(&actual);
                if (!actual.sameObject(nm.info) and actual.isNotable()) {
                    const at = actualTitle(arena, &actual);
                    return .{
                        .label = compose(arena, &actual, null),
                        .note = std.fmt.allocPrint(arena, "{s} is {d:.1}\u{00b0} from the {s}; the frame is centred on {s}, used that", .{ what, sep, where_from, at }) catch null,
                    };
                }
            }
            var note = std.fmt.allocPrint(arena, "{s} is {d:.1}\u{00b0} from the {s} (tolerance {d:.1}\u{00b0})", .{ what, sep, where_from, c.toleranceDeg() }) catch "";
            if (nm.note) |pn| note = std.fmt.allocPrint(arena, "{s}; {s}", .{ pn, note }) catch note;
            return .{ .label = compose(arena, nm.info, nm.preferred), .note = note };
        } else {
            if (resolver.nearby(c.ra_deg, c.dec_deg, c.searchRadiusDeg())) |actual_c| {
                var actual = actual_c.*;
                resolver.adoptCompanionNebula(&actual);
                const where_from: []const u8 = if (c.solved) "plate solution" else "header coordinates";
                return .{
                    .label = compose(arena, &actual, null),
                    .note = std.fmt.allocPrint(arena, "identified from the {s}", .{where_from}) catch null,
                };
            }
        }
    } else if (named) |nm| {
        return .{ .label = compose(arena, nm.info, nm.preferred), .note = nm.note };
    }

    var id = fallback;
    if (resolver.enabledNow() and (header != null or file_desig != null)) {
        id.note = "object not found in SIMBAD; used file name";
    }
    return id;
}

fn identifyByName(resolver: *Resolver, header: ?[]const u8, file_desig: ?[]const u8) ?Named {
    const arena = resolver.arena;
    if (header) |h| {
        if (resolver.resolve(h)) |info_c| {
            const info = @constCast(info_c);
            if (file_desig) |fd| {
                if (!info.matches(fd)) {
                    if (resolver.resolve(fd)) |info2_c| {
                        const resolved_as = if (lk.normEql(h, info.main_id))
                            ""
                        else
                            std.fmt.allocPrint(arena, " ({s})", .{info.main_id}) catch "";
                        return .{
                            .info = @constCast(info2_c),
                            .preferred = arena.dupe(u8, fd) catch fd,
                            .note = std.fmt.allocPrint(arena, "header OBJECT is '{s}'{s} but file name says {s}; used file name", .{ h, resolved_as, fd }) catch null,
                        };
                    } else {
                        var db: [32]u8 = undefined;
                        return .{
                            .info = info,
                            .preferred = if (lk.designationInName(h, &db)) |d| (arena.dupe(u8, d) catch null) else null,
                            .note = std.fmt.allocPrint(arena, "header OBJECT '{s}' ({s}) does not match file name designation {s}", .{ h, info.main_id, fd }) catch null,
                        };
                    }
                }
                return .{ .info = info, .preferred = arena.dupe(u8, fd) catch fd, .note = null };
            }
            var db: [32]u8 = undefined;
            return .{
                .info = info,
                .preferred = if (lk.designationInName(h, &db)) |d| (arena.dupe(u8, d) catch null) else null,
                .note = null,
            };
        }
    }
    if (file_desig) |fd| {
        if (resolver.resolve(fd)) |info_c| {
            return .{ .info = @constCast(info_c), .preferred = arena.dupe(u8, fd) catch fd, .note = null };
        }
    }
    return null;
}

fn actualTitle(arena: Allocator, info: *const ObjectInfo) []const u8 {
    return compose(arena, info, null).title;
}

fn compose(arena: Allocator, info: *const ObjectInfo, preferred: ?[]const u8) Label {
    return lk.compose(arena, info, preferred) catch .{ .title = info.main_id };
}

fn composePair(arena: Allocator, first: *const ObjectInfo, first_pref: ?[]const u8, second: *const ObjectInfo, centre: wcs.SkyCoords) Label {
    return lk.composePair(arena, first, first_pref, second, centre) catch .{ .title = first.main_id };
}

/// Do two records describe the same region under slightly different names?
fn sameRegion(a: *const ObjectInfo, b: *const ObjectInfo) bool {
    const an = a.common_name orelse return false;
    const bn = b.common_name orelse return false;
    if (lk.normEql(an, bn)) return false;

    var a_words: [16][]const u8 = undefined;
    var an_n: usize = 0;
    var b_words: [16][]const u8 = undefined;
    var bn_n: usize = 0;
    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    an_n = wordSet(an, a_buf[0..], a_words[0..]);
    bn_n = wordSet(bn, b_buf[0..], b_words[0..]);

    var shared: usize = 0;
    for (a_words[0..an_n]) |aw| {
        for (b_words[0..bn_n]) |bw| {
            if (std.mem.eql(u8, aw, bw)) shared += 1;
        }
    }
    if (shared >= 2) return true;
    // subset either way
    const a_sub = subset(a_words[0..an_n], b_words[0..bn_n]);
    const b_sub = subset(b_words[0..bn_n], a_words[0..an_n]);
    return a_sub or b_sub;
}

fn subset(small: []const []const u8, big: []const []const u8) bool {
    for (small) |s| {
        var found = false;
        for (big) |b| {
            if (std.mem.eql(u8, s, b)) found = true;
        }
        if (!found) return false;
    }
    return small.len > 0;
}

fn wordSet(s: []const u8, buf: []u8, out: [][]const u8) usize {
    var n: usize = 0;
    var w: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok_in| {
        var tok = tok_in;
        if (std.mem.endsWith(u8, tok, "'s")) tok = tok[0 .. tok.len - 2];
        const start = w;
        for (tok) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                if (w >= buf.len) break;
                buf[w] = std.ascii.toLower(c);
                w += 1;
            }
        }
        if (w > start and n < out.len) {
            out[n] = buf[start..w];
            n += 1;
        }
    }
    return n;
}

fn spelledOut(arena: Allocator, query: []const u8) !?[]const u8 {
    const q = try lk.collapseWsAlloc(arena, query);
    const sp = std.mem.indexOfScalar(u8, q, ' ') orelse return null;
    const prefix = q[0..sp];
    const rest = q[sp + 1 ..];
    var pb: [16]u8 = undefined;
    if (prefix.len > pb.len) return null;
    const up = std.ascii.upperString(pb[0..prefix.len], prefix);
    const long: []const u8 = if (std.mem.eql(u8, up, "CR"))
        "Collinder"
    else if (std.mem.eql(u8, up, "MEL"))
        "Melotte"
    else if (std.mem.eql(u8, up, "CED"))
        "Cederblad"
    else if (std.mem.eql(u8, up, "B"))
        "Barnard"
    else
        return null;
    return try std.fmt.allocPrint(arena, "{s} {s}", .{ long, rest });
}

fn percentEncode(arena: Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len * 3);
    for (s) |b| {
        switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(arena, b),
            else => {
                try out.append(arena, '%');
                try out.append(arena, hex[b >> 4]);
                try out.append(arena, hex[b & 0x0f]);
            },
        }
    }
    return out.items;
}

const testing = std.testing;

test "percent encode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("NGC%207000", try percentEncode(arena.allocator(), "NGC 7000"));
    try testing.expectEqualStrings("M31", try percentEncode(arena.allocator(), "M31"));
}

test "identify falls back to stem when disabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r = Resolver.init(testing.allocator, arena.allocator(), undefined, false);
    defer r.deinit();
    const id = identify(&r, "M 31", null, "M31_stack");
    try testing.expectEqualStrings("M31_stack", id.label.title);
}
