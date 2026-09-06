//! Identify the object in an image and fetch its catalogue information from
//! the CDS Sesame name resolver (backed by SIMBAD), to stamp a proper name
//! like "Andromeda Galaxy (M 31)" instead of the bare file name.
//!
//! Port of the Rust `lookup.rs`. This file has the identity/formatting logic
//! and the SIMBAD response parsers; the network `Resolver` is in
//! `resolver.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const catalog = @import("catalog.zig");
const wcs = @import("wcs.zig");
const post = @import("post.zig");

pub const SESAME_URL = "https://cds.unistra.fr/cgi-bin/nph-sesame/-oxI/S?";
pub const TAP_URL = "https://simbad.cds.unistra.fr/simbad/sim-tap/sync";

pub const DSO_TYPES = [_][]const u8{
    "G",   "AGN", "GiG", "GiP", "GiC", "IG",  "PaG", "GrG", "ClG", "SBG", "EmG", "LIN", "SyG", "Sy1",
    "Sy2", "HII", "PN",  "SNR", "RNe", "DNe", "GNe", "MoC", "Cld", "ISM", "EmO", "bub", "OpC", "GlC",
    "Cl*", "As*", "SFR", "glb",
};

pub const NEBULA_TYPES = [_][]const u8{
    "HII", "RNe", "DNe", "GNe", "MoC", "Cld", "ISM", "EmO", "bub", "SNR", "SFR", "PN",
};

pub const COMPANION_HOST_TYPES = [_][]const u8{
    "OpC", "Cl*", "As*", "SFR", "HII", "GNe", "ISM", "Cld", "MoC", "EmO", "RNe", "DNe",
};

pub const COMPANION_RADIUS_DEG: f64 = 0.5;

pub const Catalog = struct {
    keys: []const []const u8,
    pretty: []const u8,
    simbad: []const []const u8,
    max: u32,
    adjacent_only: bool,
};

pub const CATALOGS = [_]Catalog{
    .{ .keys = &.{ "M", "MESSIER" }, .pretty = "M ", .simbad = &.{"M "}, .max = 110, .adjacent_only = true },
    .{ .keys = &.{ "C", "CALDWELL" }, .pretty = "C ", .simbad = &.{}, .max = 109, .adjacent_only = true },
    .{ .keys = &.{"NGC"}, .pretty = "NGC ", .simbad = &.{"NGC "}, .max = 7840, .adjacent_only = false },
    .{ .keys = &.{"IC"}, .pretty = "IC ", .simbad = &.{"IC "}, .max = 5386, .adjacent_only = false },
    .{ .keys = &.{ "SH2", "SH" }, .pretty = "Sh2-", .simbad = &.{ "SH 2-", "SH2-" }, .max = 313, .adjacent_only = false },
    .{ .keys = &.{ "B", "BARNARD" }, .pretty = "Barnard ", .simbad = &.{"Barnard "}, .max = 370, .adjacent_only = true },
    .{ .keys = &.{"LBN"}, .pretty = "LBN ", .simbad = &.{"LBN "}, .max = 1125, .adjacent_only = false },
    .{ .keys = &.{"LDN"}, .pretty = "LDN ", .simbad = &.{"LDN "}, .max = 1802, .adjacent_only = false },
    .{ .keys = &.{"VDB"}, .pretty = "vdB ", .simbad = &.{ "VdB ", "vdB " }, .max = 158, .adjacent_only = false },
    .{ .keys = &.{ "CR", "COLLINDER" }, .pretty = "Cr ", .simbad = &.{ "Cr ", "Cl Collinder " }, .max = 471, .adjacent_only = false },
    .{ .keys = &.{ "MEL", "MELOTTE" }, .pretty = "Mel ", .simbad = &.{ "Cl Melotte ", "Mel " }, .max = 245, .adjacent_only = false },
    .{ .keys = &.{ "CED", "CEDERBLAD" }, .pretty = "Ced ", .simbad = &.{"Ced "}, .max = 215, .adjacent_only = false },
    .{ .keys = &.{"ARP"}, .pretty = "Arp ", .simbad = &.{ "APG ", "Arp " }, .max = 338, .adjacent_only = false },
    .{ .keys = &.{"UGC"}, .pretty = "UGC ", .simbad = &.{"UGC "}, .max = 12921, .adjacent_only = false },
    .{ .keys = &.{"PGC"}, .pretty = "PGC ", .simbad = &.{ "LEDA ", "PGC " }, .max = 9_999_999, .adjacent_only = false },
    .{ .keys = &.{"HD"}, .pretty = "HD ", .simbad = &.{"HD "}, .max = 359083, .adjacent_only = false },
    .{ .keys = &.{"HIP"}, .pretty = "HIP ", .simbad = &.{"HIP "}, .max = 120404, .adjacent_only = false },
};

// --- normalisation --------------------------------------------------------

const NORM_REPLACEMENTS = [_][2][]const u8{
    .{ "MESSIER", "M" },
    .{ "CALDWELL", "C" },
    .{ "CLMELOTTE", "MEL" },
    .{ "MELOTTE", "MEL" },
    .{ "CLCOLLINDER", "CR" },
    .{ "COLLINDER", "CR" },
    .{ "CEDERBLAD", "CED" },
    .{ "LEDA", "PGC" },
    .{ "APG", "ARP" },
    .{ "SH2-", "SH2-" },
};

/// Canonical form for comparing identifiers: upper-case, no whitespace, long
/// catalogue names shortened to the abbreviations SIMBAD also uses. Writes
/// into `buf`; returns the used slice.
pub fn normalize(s: []const u8, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (n >= buf.len) return error.NoSpaceLeft;
        buf[n] = std.ascii.toUpper(c);
        n += 1;
    }
    var out = buf[0..n];
    for (NORM_REPLACEMENTS) |pair| {
        if (std.mem.startsWith(u8, out, pair[0])) {
            const rest_len = out.len - pair[0].len;
            if (pair[1].len + rest_len > buf.len) return error.NoSpaceLeft;
            // shift the tail, then write the prefix
            std.mem.copyBackwards(u8, buf[pair[1].len .. pair[1].len + rest_len], out[pair[0].len..][0..rest_len]);
            @memcpy(buf[0..pair[1].len], pair[1]);
            out = buf[0 .. pair[1].len + rest_len];
            break;
        }
    }
    return out;
}

pub fn normalizeAlloc(a: Allocator, s: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const norm = normalize(s, &buf) catch return a.dupe(u8, s);
    return a.dupe(u8, norm);
}

pub fn normEql(a: []const u8, b: []const u8) bool {
    var ba: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    const na = normalize(a, &ba) catch return std.mem.eql(u8, a, b);
    const nb = normalize(b, &bb) catch return std.mem.eql(u8, a, b);
    return std.mem.eql(u8, na, nb);
}

pub fn collapseWsAlloc(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var first = true;
    while (it.next()) |w| {
        if (!first) try out.append(a, ' ');
        try out.appendSlice(a, w);
        first = false;
    }
    return out.toOwnedSlice(a);
}

// --- object info ---------------------------------------------------------

pub const ObjectInfo = struct {
    arena: Allocator,
    main_id: []const u8,
    common_name: ?[]const u8 = null,
    designations: [][]const u8,
    aliases_norm: std.StringHashMapUnmanaged(void) = .empty,
    otype: []const u8,
    morph_type: ?[]const u8 = null,
    ra_deg: ?f64 = null,
    dec_deg: ?f64 = null,

    pub fn matches(self: *const ObjectInfo, designation: []const u8) bool {
        var b: [128]u8 = undefined;
        const norm = normalize(designation, &b) catch return false;
        if (self.aliases_norm.contains(norm)) return true;
        if (catalog.caldwellNumber(self.designations)) |cn| {
            var b2: [32]u8 = undefined;
            const c_str = std.fmt.bufPrint(&b2, "C {d}", .{cn}) catch return false;
            return normEql(designation, c_str);
        }
        return false;
    }

    pub fn sameObject(self: *const ObjectInfo, other: *const ObjectInfo) bool {
        var it = self.aliases_norm.keyIterator();
        while (it.next()) |k| {
            if (other.aliases_norm.contains(k.*)) return true;
        }
        return false;
    }

    pub fn isNotable(self: *const ObjectInfo) bool {
        return self.prominence() <= 5 or self.common_name != null;
    }

    pub fn prominence(self: *const ObjectInfo) usize {
        for (CATALOGS, 0..) |cat, tier| {
            for (self.designations) |d| {
                if (std.mem.startsWith(u8, d, cat.pretty)) return tier;
            }
        }
        if (self.common_name != null) return CATALOGS.len;
        return std.math.maxInt(usize);
    }

    pub fn typeDescription(self: *const ObjectInfo, buf: []u8) []const u8 {
        if (isGalaxyType(self.otype)) {
            if (self.morph_type) |m| {
                if (morphologyDescription(m)) |md| return md;
            }
        }
        _ = buf;
        return otypeDescription(self.otype);
    }

    /// "RA 00h 42m 44s  Dec +41° 16′ 08″" into `buf`, or "" if unknown.
    pub fn coordinates(self: *const ObjectInfo, buf: []u8) []const u8 {
        const ra = self.ra_deg orelse return "";
        const dec = self.dec_deg orelse return "";
        var rb: [32]u8 = undefined;
        var db: [32]u8 = undefined;
        return std.fmt.bufPrint(buf, "RA {s}  Dec {s}", .{ fmtRa(ra, &rb), fmtDec(dec, &db) }) catch "";
    }

    pub fn deinit(self: *ObjectInfo) void {
        self.aliases_norm.deinit(self.arena);
    }
};

/// Build an ObjectInfo from a main id + alias list, all borrowed into `arena`.
pub fn objectFromAliases(
    arena: Allocator,
    main_id_in: []const u8,
    aliases: []const []const u8,
    otype: []const u8,
    morph_type: ?[]const u8,
    ra_deg: ?f64,
    dec_deg: ?f64,
) !*ObjectInfo {
    const info = try arena.create(ObjectInfo);
    const main_id = if (std.mem.startsWith(u8, main_id_in, "NAME "))
        try arena.dupe(u8, main_id_in["NAME ".len..])
    else
        try arena.dupe(u8, main_id_in);

    var designations: std.ArrayList([]const u8) = .empty;
    for (CATALOGS) |cat| {
        for (aliases) |alias| {
            if (catalogDesignation(arena, &cat, alias) catch null) |d| {
                var dup = true;
                for (designations.items) |ex| {
                    if (std.mem.eql(u8, ex, d)) {
                        dup = false;
                        break;
                    }
                }
                if (dup) try designations.append(arena, d);
            }
        }
    }

    var aliases_norm: std.StringHashMapUnmanaged(void) = .empty;
    for (aliases) |alias| {
        const na = try normalizeAlloc(arena, alias);
        try aliases_norm.put(arena, na, {});
    }

    // Caldwell number after any Messier id.
    if (catalog.caldwellNumber(designations.items)) |cn| {
        const c_str = try std.fmt.allocPrint(arena, "C {d}", .{cn});
        var present = false;
        for (designations.items) |d| {
            if (std.mem.eql(u8, d, c_str)) present = true;
        }
        if (!present) {
            var pos: usize = 0;
            while (pos < designations.items.len and std.mem.startsWith(u8, designations.items[pos], "M ")) pos += 1;
            try designations.insert(arena, pos, c_str);
        }
    }

    const common_name = catalog.popularName(designations.items) orelse pickCommonName(aliases);

    info.* = .{
        .arena = arena,
        .main_id = main_id,
        .common_name = if (common_name) |cn| try arena.dupe(u8, cn) else null,
        .designations = designations.items,
        .aliases_norm = aliases_norm,
        .otype = try arena.dupe(u8, std.mem.trim(u8, otype, " \t")),
        .morph_type = if (morph_type) |m| try arena.dupe(u8, m) else null,
        .ra_deg = ra_deg,
        .dec_deg = dec_deg,
    };
    return info;
}

fn catalogDesignation(arena: Allocator, cat: *const Catalog, alias: []const u8) !?[]const u8 {
    for (cat.simbad) |prefix| {
        if (alias.len > prefix.len and std.ascii.eqlIgnoreCase(alias[0..prefix.len], prefix)) {
            const rest = std.mem.trim(u8, alias[prefix.len..], " \t");
            const n = std.fmt.parseInt(u32, rest, 10) catch continue;
            if (n >= 1 and n <= cat.max) {
                return try std.fmt.allocPrint(arena, "{s}{d}", .{ cat.pretty, n });
            }
        }
    }
    return null;
}

// --- type descriptions --------------------------------------------------

pub fn isGalaxyType(otype_in: []const u8) bool {
    const otype = std.mem.trimEnd(u8, otype_in, "?");
    const gal = [_][]const u8{
        "G",   "AGN", "GiG", "GiP", "GiC", "BiC", "SBG", "EmG", "H2G",
        "LSB", "rG",  "SyG", "Sy1", "Sy2", "LIN", "IG",  "PaG", "BLL",
        "Bla", "QSO",
    };
    for (gal) |g| {
        if (std.mem.eql(u8, otype, g)) return true;
    }
    return false;
}

pub fn morphologyDescription(code_in: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (code_in) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    if (n == 0) return null;
    const c = buf[0..n];

    var dwarf = false;
    var body = c;
    if (c.len >= 2 and c[0] == 'd' and std.ascii.isUpper(c[1])) {
        dwarf = true;
        body = c[1..];
    }
    var up_buf: [64]u8 = undefined;
    const up = std.ascii.upperString(up_buf[0..body.len], body);

    const class: []const u8 = blk: {
        if (std.mem.startsWith(u8, up, "SPH") or std.mem.startsWith(u8, up, "DSPH")) break :blk "Spheroidal";
        if (std.mem.startsWith(u8, up, "CD")) break :blk "Giant elliptical";
        if (std.mem.startsWith(u8, up, "E")) break :blk "Elliptical";
        if (std.mem.startsWith(u8, up, "S0") or std.mem.startsWith(u8, up, "SA0") or
            std.mem.startsWith(u8, up, "SB0") or std.mem.startsWith(u8, up, "SAB0")) break :blk "Lenticular";
        if (std.mem.startsWith(u8, up, "SB")) break :blk "Barred spiral";
        if (std.mem.startsWith(u8, up, "SA") or std.mem.startsWith(u8, up, "S")) break :blk "Spiral";
        if (std.mem.startsWith(u8, up, "I")) break :blk "Irregular";
        if (std.mem.startsWith(u8, up, "RING")) break :blk "Ring";
        return null;
    };

    if (dwarf) {
        if (std.mem.eql(u8, class, "Elliptical")) return "Dwarf elliptical galaxy";
        if (std.mem.eql(u8, class, "Spheroidal")) return "Dwarf spheroidal galaxy";
        if (std.mem.eql(u8, class, "Irregular")) return "Dwarf irregular galaxy";
        if (std.mem.eql(u8, class, "Spiral") or std.mem.eql(u8, class, "Barred spiral")) return "Dwarf spiral galaxy";
        return "Dwarf galaxy";
    }
    if (std.mem.eql(u8, class, "Spheroidal")) return "Spheroidal galaxy";
    if (std.mem.eql(u8, class, "Giant elliptical")) return "Giant elliptical galaxy";
    if (std.mem.eql(u8, class, "Elliptical")) return "Elliptical galaxy";
    if (std.mem.eql(u8, class, "Lenticular")) return "Lenticular galaxy";
    if (std.mem.eql(u8, class, "Barred spiral")) return "Barred spiral galaxy";
    if (std.mem.eql(u8, class, "Spiral")) return "Spiral galaxy";
    if (std.mem.eql(u8, class, "Irregular")) return "Irregular galaxy";
    if (std.mem.eql(u8, class, "Ring")) return "Ring galaxy";
    return null;
}

pub fn otypeDescription(code_in: []const u8) []const u8 {
    const code = std.mem.trimEnd(u8, code_in, "?");
    const table = [_][2][]const u8{
        .{ "G", "Galaxy" },
        .{ "AGN", "Galaxy (active nucleus)" },
        .{ "GiG", "Galaxy in a group" },
        .{ "GiP", "Galaxy in a pair" },
        .{ "GiC", "Galaxy in a cluster" },
        .{ "BiC", "Brightest cluster galaxy" },
        .{ "IG", "Interacting galaxies" },
        .{ "PaG", "Pair of galaxies" },
        .{ "GrG", "Group of galaxies" },
        .{ "CGG", "Compact group of galaxies" },
        .{ "ClG", "Cluster of galaxies" },
        .{ "SCG", "Supercluster of galaxies" },
        .{ "SBG", "Starburst galaxy" },
        .{ "EmG", "Emission-line galaxy" },
        .{ "H2G", "HII galaxy" },
        .{ "LSB", "Low surface brightness galaxy" },
        .{ "rG", "Radio galaxy" },
        .{ "SyG", "Seyfert galaxy" },
        .{ "Sy1", "Seyfert 1 galaxy" },
        .{ "Sy2", "Seyfert 2 galaxy" },
        .{ "LIN", "LINER galaxy" },
        .{ "QSO", "Quasar" },
        .{ "BLL", "Blazar" },
        .{ "Bla", "Blazar" },
        .{ "PoG", "Part of a galaxy" },
        .{ "HII", "HII region (emission nebula)" },
        .{ "PN", "Planetary nebula" },
        .{ "SNR", "Supernova remnant" },
        .{ "RNe", "Reflection nebula" },
        .{ "DNe", "Dark nebula" },
        .{ "GNe", "Nebula" },
        .{ "Neb", "Nebula" },
        .{ "EmO", "Emission object" },
        .{ "MoC", "Molecular cloud" },
        .{ "Cld", "Cloud" },
        .{ "ISM", "Interstellar medium" },
        .{ "bub", "Bubble" },
        .{ "HH", "Herbig-Haro object" },
        .{ "SFR", "Star-forming region" },
        .{ "PoC", "Part of a cloud" },
        .{ "glb", "Globule" },
        .{ "cor", "Dense core" },
        .{ "out", "Outflow" },
        .{ "sh", "Interstellar shell" },
        .{ "reg", "Region" },
        .{ "OpC", "Open cluster" },
        .{ "GlC", "Globular cluster" },
        .{ "Cl*", "Star cluster" },
        .{ "As*", "Stellar association" },
        .{ "MGr", "Moving group" },
        .{ "St*", "Stellar stream" },
        .{ "*", "Star" },
        .{ "**", "Double or multiple star" },
        .{ "V*", "Variable star" },
        .{ "Pe*", "Peculiar star" },
        .{ "Em*", "Emission-line star" },
        .{ "Be*", "Be star" },
        .{ "WR*", "Wolf-Rayet star" },
        .{ "Ce*", "Cepheid variable" },
        .{ "Mi*", "Mira variable" },
        .{ "LP*", "Long-period variable" },
        .{ "RR*", "RR Lyrae variable" },
        .{ "EB*", "Eclipsing binary" },
        .{ "SB*", "Spectroscopic binary" },
        .{ "Or*", "Orion variable" },
        .{ "TT*", "T Tauri star" },
        .{ "Y*O", "Young stellar object" },
        .{ "sg*", "Supergiant" },
        .{ "s*b", "Blue supergiant" },
        .{ "s*r", "Red supergiant" },
        .{ "s*y", "Yellow supergiant" },
        .{ "RG*", "Red giant" },
        .{ "AB*", "AGB star" },
        .{ "pA*", "Post-AGB star" },
        .{ "C*", "Carbon star" },
        .{ "WD*", "White dwarf" },
        .{ "N*", "Neutron star" },
        .{ "Psr", "Pulsar" },
        .{ "BH", "Black hole" },
        .{ "XB*", "X-ray binary" },
        .{ "SN*", "Supernova" },
        .{ "No*", "Nova" },
        .{ "Sy*", "Symbiotic star" },
        .{ "PM*", "High proper-motion star" },
        .{ "HS*", "Hot subdwarf" },
        .{ "BD*", "Brown dwarf" },
        .{ "LM*", "Low-mass star" },
        .{ "Pl", "Exoplanet" },
        .{ "gLe", "Gravitational lens" },
        .{ "X", "X-ray source" },
        .{ "Rad", "Radio source" },
        .{ "IR", "Infrared source" },
        .{ "UV", "UV source" },
        .{ "gam", "Gamma-ray source" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, code, row[0])) return row[1];
    }
    if (std.mem.eql(u8, code, "err") or std.mem.eql(u8, code, "?") or code.len == 0) return "";
    return code;
}

// --- common-name selection --------------------------------------------

const TYPE_WORDS = [_][]const u8{
    "nebula", "galaxy",      "cluster", "cloud",    "remnant", "loop",    "complex", "star",
    "group",  "association", "region",  "filament", "chain",   "triplet", "quintet", "sextet",
    "arc",    "wall",        "bubble",  "shell",    "ring",    "pair",    "stream",  "dwarf",
};

pub fn endsWithTypeWord(name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, name, " \t");
    var last: ?[]const u8 = null;
    while (it.next()) |w| last = w;
    const w = last orelse return false;
    var lb: [32]u8 = undefined;
    if (w.len > lb.len) return false;
    const lw = std.ascii.lowerString(lb[0..w.len], w);
    for (TYPE_WORDS) |t| {
        if (std.mem.eql(u8, lw, t)) return true;
    }
    return false;
}

pub fn isCleanName(name: []const u8) bool {
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, name, " \t");
    while (it.next()) |w| {
        words += 1;
        var alnum: usize = 0;
        var last_alnum: u8 = 0;
        for (w) |c| {
            if (std.ascii.isDigit(c)) return false;
            if (std.ascii.isAlphanumeric(c)) {
                alnum += 1;
                last_alnum = c;
            }
        }
        if (alnum == 1 and std.ascii.isUpper(last_alnum)) return false;
    }
    return words > 0;
}

const CONSTELLATION_ABBR = [_][]const u8{
    "And", "Ant", "Aps", "Aqr", "Aql", "Ara", "Ari", "Aur", "Boo", "Cae", "Cam", "Cnc", "CVn",
    "CMa", "CMi", "Cap", "Car", "Cas", "Cen", "Cep", "Cet", "Cha", "Cir", "Col", "Com", "CrA",
    "CrB", "Crv", "Crt", "Cru", "Cyg", "Del", "Dor", "Dra", "Equ", "Eri", "For", "Gem", "Gru",
    "Her", "Hor", "Hya", "Hyi", "Ind", "Lac", "Leo", "LMi", "Lep", "Lib", "Lup", "Lyn", "Lyr",
    "Men", "Mic", "Mon", "Mus", "Nor", "Oct", "Oph", "Ori", "Pav", "Peg", "Per", "Phe", "Pic",
    "Psc", "PsA", "Pup", "Pyx", "Ret", "Sge", "Sgr", "Sco", "Scl", "Sct", "Ser", "Sex", "Tau",
    "Tel", "Tri", "TrA", "Tuc", "UMa", "UMi", "Vel", "Vir", "Vol", "Vul",
};
const OTHER_ABBR = [_][]const u8{ "Neb", "Gal", "Cl", "Nebul", "Amer" };

/// Choose the most presentable "NAME ..." alias.
pub fn pickCommonName(aliases: []const []const u8) ?[]const u8 {
    var candidates_buf: [64][]const u8 = undefined;
    var nc: usize = 0;
    for (aliases) |a| {
        if (!std.mem.startsWith(u8, a, "NAME ")) continue;
        const nm = std.mem.trim(u8, a["NAME ".len..], " \t");
        if (nm.len == 0) continue;
        if (!isCleanName(nm)) continue;
        if (nc < candidates_buf.len) {
            candidates_buf[nc] = nm;
            nc += 1;
        }
    }
    if (nc == 0) return null;
    const candidates = candidates_buf[0..nc];

    // "nice" = not shouting, no abbreviations
    var nice_buf: [64][]const u8 = undefined;
    var nn: usize = 0;
    for (candidates) |nm| {
        if (isShouting(nm) or hasAbbreviation(nm)) continue;
        nice_buf[nn] = nm;
        nn += 1;
    }
    const nice = nice_buf[0..nn];

    for (nice) |nm| {
        if (endsWithTypeWord(nm)) return nm;
    }
    if (nice.len > 0) return nice[0];
    return candidates[0];
}

fn isShouting(n: []const u8) bool {
    var letters: usize = 0;
    var all_upper = true;
    for (n) |c| {
        if (std.ascii.isAlphabetic(c)) {
            letters += 1;
            if (!std.ascii.isUpper(c)) all_upper = false;
        }
    }
    return letters >= 4 and all_upper;
}

fn hasAbbreviation(n: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, n, " \t");
    while (it.next()) |w_in| {
        const w = std.mem.trim(u8, w_in, ".,:;!?'\"()");
        for (CONSTELLATION_ABBR) |ab| {
            if (std.mem.eql(u8, w, ab)) return true;
        }
        for (OTHER_ABBR) |ab| {
            if (std.mem.eql(u8, w, ab)) return true;
        }
    }
    return false;
}

// --- file-name designation scanner ------------------------------------

/// First catalogue designation in a file-name stem, e.g.
/// "2026-09-05_NGC7000_Ha" -> "NGC 7000". Writes into `buf`.
pub fn designationInName(name: []const u8, buf: []u8) ?[]const u8 {
    var up_buf: [256]u8 = undefined;
    if (name.len > up_buf.len) return null;
    const upper = std.ascii.upperString(up_buf[0..name.len], name);
    const n = upper.len;
    const isSep = struct {
        fn f(c: u8) bool {
            return c == ' ' or c == '_' or c == '-' or c == '.';
        }
    }.f;

    var i: usize = 0;
    while (i < n) {
        if (!std.ascii.isAlphabetic(upper[i]) or (i > 0 and std.ascii.isAlphanumeric(upper[i - 1]))) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < n and std.ascii.isAlphabetic(upper[i])) i += 1;
        const word = upper[start..i];

        for (CATALOGS) |cat| {
            var key_hit = false;
            for (cat.keys) |k| {
                if (std.mem.eql(u8, k, word)) key_hit = true;
            }
            if (!key_hit) continue;

            var j = i;
            if (std.mem.eql(u8, word, "SH")) {
                if (j < n and isSep(upper[j])) j += 1;
                if (j < n and upper[j] == '2') j += 1 else continue;
            }
            const sep_here = j < n and isSep(upper[j]);
            if (sep_here) {
                if (cat.adjacent_only) continue;
                j += 1;
            }
            const dstart = j;
            while (j < n and std.ascii.isDigit(upper[j]) and j - dstart < 8) j += 1;
            if (j == dstart or (j < n and std.ascii.isAlphabetic(upper[j]))) continue;
            const digits = upper[dstart..j];
            const num = std.fmt.parseInt(u32, digits, 10) catch continue;
            if (num >= 1 and num <= cat.max) {
                return std.fmt.bufPrint(buf, "{s}{d}", .{ cat.pretty, num }) catch null;
            }
        }
    }
    return null;
}

// --- coordinate formatting ------------------------------------------

pub fn fmtRa(deg: f64, buf: []u8) []const u8 {
    const hours = @mod(deg, 360.0) / 15.0;
    const total: u64 = @intFromFloat(@round(hours * 3600.0));
    const h = total / 3600 % 24;
    const m = total / 60 % 60;
    const s = total % 60;
    return std.fmt.bufPrint(buf, "{d:0>2}h {d:0>2}m {d:0>2}s", .{ h, m, s }) catch "";
}

pub fn fmtDec(deg: f64, buf: []u8) []const u8 {
    const sign: []const u8 = if (deg < 0.0) "\u{2212}" else "+";
    const total: u64 = @intFromFloat(@round(@abs(deg) * 3600.0));
    const d = total / 3600;
    const m = total / 60 % 60;
    const s = total % 60;
    return std.fmt.bufPrint(buf, "{s}{d:0>2}\u{00b0} {d:0>2}\u{2032} {d:0>2}\u{2033}", .{ sign, d, m, s }) catch "";
}

// --- Sesame / TAP parsers --------------------------------------------

fn childText(doc: *const xml.Document, node: *const xml.Node, name: []const u8) ?[]const u8 {
    const c = doc.childByName(node, name) orelse return null;
    return c.text;
}

fn cleanMorph(m: ?[]const u8) ?[]const u8 {
    const s = m orelse return null;
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0 or std.mem.eql(u8, t, "~")) return null;
    return t;
}

/// Parse Sesame's `-ox` XML output. `null` (Ok) = nothing found.
pub fn parseSesame(arena: Allocator, xml_src: []const u8) !?*ObjectInfo {
    var doc = xml.parse(arena, xml_src) catch return error.BadSesameXml;
    // arena owns doc's memory; do not deinit here (arena freed by caller)

    var resolver_node: ?*const xml.Node = null;
    for (doc.nodes) |*node| {
        if (!std.mem.eql(u8, node.tagName(), "Resolver")) continue;
        if (childText(&doc, node, "oname") != null) {
            resolver_node = node;
            break;
        }
    }
    const rnode = resolver_node orelse return null;

    const oname = childText(&doc, rnode, "oname") orelse return null;
    const main_id = try collapseWsAlloc(arena, oname);

    const otype = std.mem.trim(u8, childText(&doc, rnode, "otype") orelse "", " \t");
    const morph = cleanMorph(childText(&doc, rnode, "MType"));
    const ra_deg = if (childText(&doc, rnode, "jradeg")) |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null else null;
    const dec_deg = if (childText(&doc, rnode, "jdedeg")) |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null else null;

    var aliases: std.ArrayList([]const u8) = .empty;
    for (rnode.children) |ci| {
        const c = &doc.nodes[ci];
        if (!std.mem.eql(u8, c.tagName(), "alias")) continue;
        if (c.text.len == 0) continue;
        try aliases.append(arena, try collapseWsAlloc(arena, c.text));
    }
    try aliases.append(arena, main_id);

    return try objectFromAliases(arena, main_id, aliases.items, otype, morph, ra_deg, dec_deg);
}

/// Pick the best hit from a TAP TSV result. Rows are distance-sorted; take the
/// most prominent tier and, within it, the closest.
pub fn pickFromTapTsv(arena: Allocator, tsv: []const u8, require_name: bool) !?*ObjectInfo {
    var best: ?*ObjectInfo = null;
    var best_rank: [2]u32 = .{ std.math.maxInt(u32), std.math.maxInt(u32) };

    var lines = std.mem.splitScalar(u8, tsv, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0) continue;
        var cols_buf: [8][]const u8 = undefined;
        var nc: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |c| {
            if (nc < cols_buf.len) {
                cols_buf[nc] = c;
                nc += 1;
            }
        }
        if (nc < 6) continue;
        const cols = cols_buf[0..nc];

        const morph_col: ?[]const u8 = if (nc >= 7) unquote(cols[6]) else null;
        const info = try objectFromTap(
            arena,
            unquote(cols[0]),
            unquote(cols[5]),
            unquote(cols[1]),
            morph_col,
            std.fmt.parseFloat(f64, std.mem.trim(u8, cols[2], " \t")) catch null,
            std.fmt.parseFloat(f64, std.mem.trim(u8, cols[3], " \t")) catch null,
        );
        const tier = info.prominence();
        if (tier == std.math.maxInt(usize)) continue;

        var rank: [2]u32 = undefined;
        if (require_name) {
            const nm = info.common_name orelse continue;
            if (!isCleanName(nm)) continue;
            rank = .{ @intFromBool(!endsWithTypeWord(nm)), @intCast(tier) };
        } else {
            rank = .{ 0, @intCast(tier) };
        }
        if (rankLess(rank, best_rank)) {
            best_rank = rank;
            best = info;
            if (rank[0] == 0 and rank[1] == 0) break;
        }
    }
    return best;
}

fn rankLess(a: [2]u32, b: [2]u32) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] < b[1];
}

fn unquote(s: []const u8) []const u8 {
    return std.mem.trim(u8, std.mem.trim(u8, s, " \t"), "\"");
}

fn objectFromTap(
    arena: Allocator,
    main_id: []const u8,
    ids: []const u8,
    otype: []const u8,
    morph: ?[]const u8,
    ra: ?f64,
    dec: ?f64,
) !*ObjectInfo {
    const mid = try collapseWsAlloc(arena, main_id);
    const mid2 = if (std.mem.startsWith(u8, mid, "NAME ")) mid["NAME ".len..] else mid;
    var aliases: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, ids, '|');
    while (it.next()) |a| {
        const ca = try collapseWsAlloc(arena, a);
        if (ca.len != 0) try aliases.append(arena, ca);
    }
    try aliases.append(arena, try arena.dupe(u8, mid2));
    return objectFromAliases(arena, mid2, aliases.items, otype, cleanMorph(morph), ra, dec);
}

// --- label composition (see resolver.zig for identify()) --------------

pub const Label = post.Label;

pub fn titleDesignation(info: *const ObjectInfo, preferred: ?[]const u8) []const u8 {
    if (preferred) |p| return p;
    for (info.designations) |d| {
        if (!std.mem.startsWith(u8, d, "C ")) return d;
    }
    if (info.designations.len > 0) return info.designations[0];
    return info.main_id;
}

pub fn titleOf(arena: Allocator, info: *const ObjectInfo, designation: []const u8) ![]const u8 {
    if (info.common_name) |name| {
        if (!normEql(name, designation)) {
            return std.fmt.allocPrint(arena, "{s} ({s})", .{ name, designation });
        }
    }
    return arena.dupe(u8, designation);
}

/// Up to `max_ids` other catalogue ids plus the type, appended to `parts`.
fn objectParts(arena: Allocator, info: *const ObjectInfo, designation: []const u8, max_ids: usize, parts: *std.ArrayList([]const u8)) !void {
    var count: usize = 0;
    for (info.designations) |d| {
        if (normEql(d, designation)) continue;
        if (count >= max_ids) break;
        try parts.append(arena, d);
        count += 1;
    }
    var tb: [64]u8 = undefined;
    const ty = info.typeDescription(&tb);
    if (ty.len != 0) try parts.append(arena, try arena.dupe(u8, ty));
}

fn objectPartsJoined(arena: Allocator, info: *const ObjectInfo, designation: []const u8, max_ids: usize) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try objectParts(arena, info, designation, max_ids, &parts);
    return std.mem.join(arena, "  \u{00b7}  ", parts.items);
}

/// "Common Name (Designation)" over "other ids · type · coordinates".
pub fn compose(arena: Allocator, info: *const ObjectInfo, preferred: ?[]const u8) !Label {
    const designation = titleDesignation(info, preferred);
    const title = try titleOf(arena, info, designation);
    var parts: std.ArrayList([]const u8) = .empty;
    try objectParts(arena, info, designation, 3, &parts);
    var cb: [80]u8 = undefined;
    const coords = info.coordinates(&cb);
    if (coords.len != 0) try parts.append(arena, try arena.dupe(u8, coords));
    const subtitle: ?[]const u8 = if (parts.items.len != 0)
        try std.mem.join(arena, "  \u{00b7}  ", parts.items)
    else
        null;
    return .{ .title = title, .subtitle = subtitle };
}

pub fn composePair(arena: Allocator, first: *const ObjectInfo, first_pref: ?[]const u8, second: *const ObjectInfo, centre: wcs.SkyCoords) !Label {
    const d1 = titleDesignation(first, first_pref);
    const d2 = titleDesignation(second, null);
    var title: []const u8 = undefined;
    if (first.common_name != null and second.common_name != null and normEql(first.common_name.?, second.common_name.?)) {
        title = try std.fmt.allocPrint(arena, "{s} ({s} & {s})", .{ first.common_name.?, d1, d2 });
    } else {
        title = try std.fmt.allocPrint(arena, "{s} & {s}", .{ try titleOf(arena, first, d1), try titleOf(arena, second, d2) });
    }
    var parts: std.ArrayList([]const u8) = .empty;
    const p1 = try objectPartsJoined(arena, first, d1, 2);
    const p2 = try objectPartsJoined(arena, second, d2, 2);
    if (p1.len != 0) try parts.append(arena, p1);
    if (p2.len != 0) try parts.append(arena, p2);
    var rb: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    try parts.append(arena, try std.fmt.allocPrint(arena, "RA {s}  Dec {s}", .{ fmtRa(centre.ra_deg, &rb), fmtDec(centre.dec_deg, &db) }));
    return .{ .title = title, .subtitle = try std.mem.join(arena, "   +   ", parts.items) };
}

// --- tests -------------------------------------------------------------

const testing = std.testing;

test "normalize" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("M31", try normalize("M  31", &b));
    try testing.expectEqualStrings("SH2-155", try normalize("SH 2-155", &b));
    try testing.expectEqualStrings("MEL22", try normalize("Cl Melotte 22", &b));
    try testing.expectEqualStrings("MEL22", try normalize("Mel 22", &b));
    try testing.expectEqualStrings("M31", try normalize("Messier 31", &b));
}

test "designation in name" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("M 31", designationInName("M31_Andromeda_2026-09-05", &b).?);
    try testing.expectEqualStrings("NGC 7000", designationInName("2026-09-05_NGC7000_Ha_300s_0001", &b).?);
    try testing.expectEqualStrings("NGC 7000", designationInName("ngc_7000 stack", &b).?);
    try testing.expectEqualStrings("Sh2-155", designationInName("Sh2-155_RGB", &b).?);
    try testing.expectEqualStrings("Sh2-101", designationInName("SH2_101", &b).?);
    try testing.expectEqualStrings("IC 1396", designationInName("IC1396_Elephant", &b).?);
    try testing.expectEqualStrings("Barnard 33", designationInName("B33_horsehead", &b).?);
    try testing.expectEqual(@as(?[]const u8, null), designationInName("Messier 42", &b));
    try testing.expectEqualStrings("M 42", designationInName("Messier42", &b).?);
    try testing.expectEqual(@as(?[]const u8, null), designationInName("Light_B_120s_0001", &b));
    try testing.expectEqual(@as(?[]const u8, null), designationInName("M_31_L", &b));
    try testing.expectEqual(@as(?[]const u8, null), designationInName("NGC7000A", &b));
    try testing.expectEqual(@as(?[]const u8, null), designationInName("M999", &b));
    try testing.expectEqualStrings("C 7", designationInName("C7_L_300s", &b).?);
    try testing.expectEqualStrings("C 14", designationInName("Caldwell14_RGB", &b).?);
    try testing.expectEqual(@as(?[]const u8, null), designationInName("C 7", &b));
    try testing.expectEqual(@as(?[]const u8, null), designationInName("C200", &b));
}

test "coordinate formatting" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("00h 42m 44s", fmtRa(10.68470833, &b));
    try testing.expectEqualStrings("+41\u{00b0} 16\u{2032} 08\u{2033}", fmtDec(41.26875, &b));
}

test "morphology words" {
    try testing.expectEqualStrings("Spiral galaxy", morphologyDescription("SAB(s)cd").?);
    try testing.expectEqualStrings("Spiral galaxy", morphologyDescription("Sc").?);
    try testing.expectEqualStrings("Barred spiral galaxy", morphologyDescription("SB(r)b").?);
    try testing.expectEqualStrings("Elliptical galaxy", morphologyDescription("E+0-1 pec").?);
    try testing.expectEqualStrings("Lenticular galaxy", morphologyDescription("S0 pec").?);
    try testing.expectEqualStrings("Irregular galaxy", morphologyDescription("IB(s)m").?);
    try testing.expectEqualStrings("Dwarf elliptical galaxy", morphologyDescription("dE").?);
    try testing.expectEqualStrings("Dwarf spheroidal galaxy", morphologyDescription("dSph").?);
    try testing.expectEqualStrings("Giant elliptical galaxy", morphologyDescription("cD").?);
    try testing.expectEqual(@as(?[]const u8, null), morphologyDescription("~"));
}

test "sesame parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const xml_src =
        \\<?xml version="1.0"?><Sesame><Target option="S"><name>M31</name>
        \\<Resolver name="Sc=Simbad"><otype>AGN</otype><jradeg>10.68470833</jradeg><jdedeg>41.26875</jdedeg>
        \\<oname>M  31</oname><alias>M 31</alias><alias>NAME Andromeda</alias><alias>NAME Andromeda Galaxy</alias>
        \\<alias>NAME And Nebula</alias><alias>NGC 224</alias><alias>UGC 454</alias><alias>LEDA 2557</alias>
        \\</Resolver></Target></Sesame>
    ;
    const info = (try parseSesame(a, xml_src)).?;
    try testing.expectEqualStrings("M 31", info.main_id);
    try testing.expectEqualStrings("Andromeda Galaxy", info.common_name.?);
    try testing.expectEqual(@as(usize, 4), info.designations.len);
    try testing.expectEqualStrings("M 31", info.designations[0]);
    try testing.expectEqualStrings("NGC 224", info.designations[1]);
    try testing.expectEqualStrings("UGC 454", info.designations[2]);
    try testing.expectEqualStrings("PGC 2557", info.designations[3]);
    try testing.expect(info.matches("m31"));
    try testing.expect(info.matches("NGC224"));
    try testing.expect(!info.matches("NGC 7000"));

    const label = try compose(a, info, "M 31");
    try testing.expectEqualStrings("Andromeda Galaxy (M 31)", label.title);
    try testing.expectEqualStrings(
        "NGC 224  \u{00b7}  UGC 454  \u{00b7}  PGC 2557  \u{00b7}  Galaxy (active nucleus)  \u{00b7}  RA 00h 42m 44s  Dec +41\u{00b0} 16\u{2032} 08\u{2033}",
        label.subtitle.?,
    );

    const none = try parseSesame(a, "<Sesame><Target><name>ZZZ</name><INFO> *** Nothing found *** </INFO></Target></Sesame>");
    try testing.expectEqual(@as(?*ObjectInfo, null), none);
}

test "tap ranking prefers prominent objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tsv =
        "main_id\totype\tra\tdec\td\tids\n" ++
        "\"[PSC2013] 9\"\t\"PN\"\t10.6835\t41.2690\t0.0009\t\"[PSC2013] 9\"\n" ++
        "\"Ford M 31 574\"\t\"PN\"\t10.6873\t41.2678\t0.0022\t\"Ford M 31 574|[B2015] M31 B127-33\"\n" ++
        "\"NGC  206\"\t\"Cl*\"\t10.10\t40.73\t0.7\t\"NGC   206|OB 78\"\n" ++
        "\"M  31\"\t\"AGN\"\t10.6847\t41.2687\t0.9\t\"NAME Andromeda Galaxy|M  31|NGC   224|UGC   454\"\n";
    const best = (try pickFromTapTsv(a, tsv, false)).?;
    try testing.expectEqualStrings("M 31", best.main_id);
    try testing.expectEqualStrings("M 31", best.designations[0]);
    try testing.expectEqualStrings("Andromeda Galaxy", best.common_name.?);

    const only_obscure = "main_id\totype\tra\tdec\td\tids\n\"[PSC2013] 9\"\t\"PN\"\t1\t2\t0.1\t\"[PSC2013] 9\"\n";
    try testing.expectEqual(@as(?*ObjectInfo, null), try pickFromTapTsv(a, only_obscure, false));

    try testing.expect(isCleanName("Wizard Nebula"));
    try testing.expect(isCleanName("Barnard's Loop"));
    try testing.expect(!isCleanName("AFGL 333 Cloud"));
    try testing.expect(!isCleanName("Rosette B"));
    try testing.expect(!isCleanName("Lo 2"));
}
