//! The batch job itself: find files, convert / post-process each one, report
//! progress. Used by both the CLI and (later) the GUI.
//!
//! Port of the Rust `batch.rs`. Online object lookup and the text stamp are
//! not wired up yet; `--resize4k` currently resizes without the label.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const xisf = @import("xisf.zig");
const fits = @import("fits.zig");
const pixels = @import("pixels.zig");
const png = @import("png.zig");
const post = @import("post.zig");
const img = @import("image.zig");

pub const IMAGE_EXTS = [_][]const u8{ "xisf", "fits", "fit", "fts" };
const FITS_EXTS = [_][]const u8{ "fits", "fit", "fts" };

const MAX_FILE = Io.Limit.limited(1 << 32); // 4 GiB per input file

pub const Options = struct {
    input_dir: []const u8 = ".",
    output_dir: ?[]const u8 = null,
    recursive: bool = false,
    overwrite: bool = false,
    resize4k: bool = false,
    png_only: bool = false,
    font: ?[]const u8 = null,
    lookup: bool = false,
    files: std.ArrayList([]const u8) = .empty,

    pub fn inputKind(self: Options) []const u8 {
        return if (self.png_only) ".png" else ".xisf / .fits";
    }

    pub fn resize4kEffective(self: Options) bool {
        return self.resize4k or self.png_only;
    }

    fn inputExts(self: Options) []const []const u8 {
        return if (self.png_only) &[_][]const u8{"png"} else &IMAGE_EXTS;
    }
};

pub const Status = union(enum) {
    ok,
    skipped,
    failed: []const u8,
};

pub const Progress = struct {
    index: usize,
    total: usize,
    rel: []const u8,
    status: Status,
    label: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Summary = struct {
    total: usize = 0,
    converted: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
    cancelled: bool = false,
    warnings: std.ArrayList([]const u8) = .empty,
};

const Outcome = struct {
    written: bool,
    label: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

/// Run the whole batch. `reporter` must have `fn report(self, Progress) void`.
/// `cancel` is an optional pointer to an atomic flag checked between files.
pub fn run(
    gpa: Allocator,
    io: Io,
    opts: *const Options,
    reporter: anytype,
    cancel: ?*const std.atomic.Value(bool),
) !Summary {
    const explicit = opts.files.items.len != 0;
    const cwd = Io.Dir.cwd();

    if (!explicit) {
        var d = cwd.openDir(io, opts.input_dir, .{ .iterate = true }) catch {
            return error.InputDirNotFound;
        };
        d.close(io);
    }

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        if (!explicit) for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    if (explicit) {
        try files.appendSlice(gpa, opts.files.items);
    } else {
        try collectFiles(gpa, io, opts.input_dir, opts.recursive, opts.inputExts(), &files);
        std.mem.sort([]const u8, files.items, {}, lessCaseInsensitive);
    }

    var summary = Summary{ .total = files.items.len };

    for (files.items, 0..) |file, i| {
        if (cancel) |cflag| {
            if (cflag.load(.monotonic)) {
                summary.cancelled = true;
                break;
            }
        }

        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const rel: []const u8 = if (explicit)
            std.fs.path.basename(file)
        else
            relativeTo(file, opts.input_dir);

        const dest = destPath(sa, opts, rel, file, explicit) catch {
            summary.failed += 1;
            reporter.report(.{ .index = i + 1, .total = files.items.len, .rel = rel, .status = .{ .failed = "cannot compute output path" } });
            continue;
        };

        const result = processOne(sa, io, file, dest, opts) catch |err| {
            summary.failed += 1;
            reporter.report(.{
                .index = i + 1,
                .total = files.items.len,
                .rel = rel,
                .status = .{ .failed = @errorName(err) },
            });
            continue;
        };

        if (result.written) {
            summary.converted += 1;
            reporter.report(.{ .index = i + 1, .total = files.items.len, .rel = rel, .status = .ok, .label = result.label, .note = result.note });
        } else {
            summary.skipped += 1;
            reporter.report(.{ .index = i + 1, .total = files.items.len, .rel = rel, .status = .skipped, .note = result.note });
        }
    }

    return summary;
}

fn processOne(a: Allocator, io: Io, src: []const u8, dest: []const u8, opts: *const Options) !Outcome {
    const cwd = Io.Dir.cwd();
    const is_png = hasExt(src, &[_][]const u8{"png"});
    const in_place = is_png and std.mem.eql(u8, src, dest);

    if (!in_place) {
        if (fileExists(io, dest) and !opts.overwrite) {
            return .{ .written = false };
        }
    }

    const bytes = cwd.readFileAlloc(io, src, a, MAX_FILE) catch return error.CannotReadInput;

    var image: img.Image8 = undefined;
    if (is_png) {
        image = try png.decode(a, bytes);
    } else {
        var data = if (hasExt(src, &FITS_EXTS))
            try fits.parse(a, bytes)
        else
            try xisf.parse(a, bytes);
        image = try pixels.toImage(a, &data);
    }

    if (opts.resize4kEffective()) {
        image = try post.resizeToFill(a, &image, post.TARGET_WIDTH, post.TARGET_HEIGHT);
        // TODO: stamp the object label (needs ttf.zig + lookup.zig).
    }

    const encoded = try png.encode(a, &image);

    if (std.fs.path.dirname(dest)) |parent| {
        cwd.createDirPath(io, parent) catch return error.CannotCreateOutputDir;
    }
    cwd.writeFile(io, .{ .sub_path = dest, .data = encoded }) catch return error.CannotWriteOutput;

    return .{ .written = true, .note = if (opts.resize4kEffective()) "stamp not implemented in this build" else null };
}

fn collectFiles(gpa: Allocator, io: Io, dir_path: []const u8, recursive: bool, exts: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    if (recursive) {
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!hasExt(entry.path, exts)) continue;
            const joined = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
            try out.append(gpa, joined);
        }
    } else {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!hasExt(entry.name, exts)) continue;
            const joined = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            try out.append(gpa, joined);
        }
    }
}

fn destPath(a: Allocator, opts: *const Options, rel: []const u8, src: []const u8, explicit: bool) ![]const u8 {
    if (opts.output_dir) |outd| {
        const joined = try std.fs.path.join(a, &.{ outd, rel });
        return withExtension(a, joined, "png");
    }
    if (explicit) return withExtension(a, src, "png");
    const joined = try std.fs.path.join(a, &.{ opts.input_dir, rel });
    return withExtension(a, joined, "png");
}

fn withExtension(a: Allocator, path: []const u8, new_ext: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(path);
    const stem = path[0 .. path.len - ext.len];
    return std.fmt.allocPrint(a, "{s}.{s}", .{ stem, new_ext });
}

fn relativeTo(path: []const u8, base: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, base)) {
        var r = path[base.len..];
        while (r.len != 0 and (r[0] == '/' or r[0] == '\\')) r = r[1..];
        if (r.len != 0) return r;
    }
    return std.fs.path.basename(path);
}

fn hasExt(path: []const u8, exts: []const []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    const e = ext[1..]; // drop '.'
    for (exts) |want| {
        if (std.ascii.eqlIgnoreCase(e, want)) return true;
    }
    return false;
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn lessCaseInsensitive(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

const testing = std.testing;

test "hasExt / withExtension" {
    try testing.expect(hasExt("a/b/c.XISF", &IMAGE_EXTS));
    try testing.expect(!hasExt("a/b/c.png", &IMAGE_EXTS));
    const p = try withExtension(testing.allocator, "dir/img.fits", "png");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("dir/img.png", p);
}
