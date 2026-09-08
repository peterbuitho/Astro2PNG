//! The batch job itself: find files, convert / post-process each one, report
//! progress. Used by both the CLI and (later) the GUI.
//!
//! Port of the Rust `batch.rs`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const xisf = @import("xisf.zig");
const fits = @import("fits.zig");
const pixels = @import("pixels.zig");
const png = @import("png.zig");
const post = @import("post.zig");
const img = @import("image.zig");
const resolver_mod = @import("resolver.zig");
const lookup = @import("lookup.zig");

pub const IMAGE_EXTS = [_][]const u8{ "xisf", "fits", "fit", "fts" };
const FITS_EXTS = [_][]const u8{ "fits", "fit", "fts" };

const MAX_FILE = Io.Limit.limited(1 << 32); // 4 GiB per input file

/// Tiny spin lock (0.16 dropped `std.Thread.Mutex`). Guards the shared object
/// resolver and the progress reporter; the heavy per-file work runs outside it.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};

/// Worker count for `job_count` files: `Options.concurrency`, or
/// `min(cpu_count, 8)` when it is zero.
fn workerCount(requested: usize, job_count: usize) usize {
    var n = requested;
    if (n == 0) {
        n = std.Thread.getCpuCount() catch 1;
        if (n > 8) n = 8;
    }
    if (n < 1) n = 1;
    if (n > job_count) n = job_count;
    return n;
}

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
    /// Files to convert in parallel. `0` means `min(cpu_count, 8)`.
    concurrency: usize = 0,

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
    /// Run-level warnings; each string is owned and freed by `deinit`.
    warnings: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Summary, gpa: Allocator) void {
        for (self.warnings.items) |w| gpa.free(w);
        self.warnings.deinit(gpa);
    }
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

    // One stamper for the whole run, if we will resize/label at all.
    var font_bytes: ?[]u8 = null;
    defer if (font_bytes) |fb| gpa.free(fb);
    var stamper: ?post.Stamper = null;
    if (opts.resize4kEffective()) {
        if (opts.font) |font_path| {
            font_bytes = cwd.readFileAlloc(io, font_path, gpa, Io.Limit.limited(32 << 20)) catch
                return error.CannotReadFont;
            stamper = post.Stamper.init(font_bytes.?) catch return error.InvalidFont;
        } else {
            stamper = post.Stamper.initBundled();
        }
    }
    const stamper_ptr: ?*const post.Stamper = if (stamper) |*s| s else null;

    // Online object resolver — lives for the whole run so a folder of 300 subs
    // of one target costs one or two requests.
    var res_arena = std.heap.ArenaAllocator.init(gpa);
    defer res_arena.deinit();
    var resolver = resolver_mod.Resolver.init(gpa, res_arena.allocator(), io, opts.lookup and stamper_ptr != null);
    defer resolver.deinit();
    const resolver_ptr: ?*resolver_mod.Resolver = if (opts.lookup and stamper_ptr != null) &resolver else null;

    var summary = Summary{ .total = files.items.len };
    if (files.items.len == 0) return summary;

    // Files are converted in parallel: a pool of worker tasks (one per CPU,
    // capped at 8) each runs the decode -> stretch -> resize -> stamp -> encode
    // pipeline. The online object lookup and the progress reporter are the only
    // things behind the lock, so 300 subs of one target still cost one or two
    // SIMBAD requests.
    const R = @TypeOf(reporter);
    const Ctx = struct {
        gpa: Allocator,
        io: Io,
        opts: *const Options,
        files: []const []const u8,
        explicit: bool,
        stamper: ?*const post.Stamper,
        resolver: ?*resolver_mod.Resolver,
        reporter: R,
        summary: *Summary,
        cancel: ?*const std.atomic.Value(bool),
        lock: *SpinLock,
        next: std.atomic.Value(usize) = .init(0),
    };

    var lock = SpinLock{};
    var ctx = Ctx{
        .gpa = gpa,
        .io = io,
        .opts = opts,
        .files = files.items,
        .explicit = explicit,
        .stamper = stamper_ptr,
        .resolver = resolver_ptr,
        .reporter = reporter,
        .summary = &summary,
        .cancel = cancel,
        .lock = &lock,
    };

    const Worker = struct {
        fn go(c: *Ctx) void {
            while (true) {
                if (c.cancel) |cf| {
                    if (cf.load(.monotonic)) {
                        c.lock.lock();
                        c.summary.cancelled = true;
                        c.lock.unlock();
                        return;
                    }
                }
                const i = c.next.fetchAdd(1, .monotonic);
                if (i >= c.files.len) return;
                const file = c.files[i];

                var scratch = std.heap.ArenaAllocator.init(c.gpa);
                defer scratch.deinit();
                const sa = scratch.allocator();

                const rel: []const u8 = if (c.explicit)
                    std.fs.path.basename(file)
                else
                    relativeTo(file, c.opts.input_dir);

                const dest = destPath(sa, c.opts, rel, file, c.explicit) catch {
                    c.lock.lock();
                    defer c.lock.unlock();
                    c.summary.failed += 1;
                    c.reporter.report(.{ .index = i + 1, .total = c.files.len, .rel = rel, .status = .{ .failed = "cannot compute output path" } });
                    continue;
                };

                const result = processOne(sa, c.io, file, dest, c.opts, c.stamper, c.resolver, c.lock) catch |err| {
                    c.lock.lock();
                    defer c.lock.unlock();
                    c.summary.failed += 1;
                    c.reporter.report(.{ .index = i + 1, .total = c.files.len, .rel = rel, .status = .{ .failed = @errorName(err) } });
                    continue;
                };

                c.lock.lock();
                defer c.lock.unlock();
                if (result.written) {
                    c.summary.converted += 1;
                    c.reporter.report(.{ .index = i + 1, .total = c.files.len, .rel = rel, .status = .ok, .label = result.label, .note = result.note });
                } else {
                    c.summary.skipped += 1;
                    c.reporter.report(.{ .index = i + 1, .total = c.files.len, .rel = rel, .status = .skipped, .note = result.note });
                }
            }
        }
    };

    const workers = workerCount(opts.concurrency, files.items.len);
    if (workers <= 1) {
        Worker.go(&ctx);
    } else {
        var group: Io.Group = .init;
        var spawned: usize = 0;
        var w: usize = 0;
        while (w < workers) : (w += 1) {
            group.concurrent(io, Worker.go, .{&ctx}) catch break;
            spawned += 1;
        }
        if (spawned == 0) {
            Worker.go(&ctx); // concurrency unavailable: run inline
        } else {
            group.await(io) catch {};
        }
    }

    if (resolver_ptr) |rp| {
        if (rp.failure) |e| {
            const w = std.fmt.allocPrint(gpa, "Online object lookup unavailable ({s}); file names were stamped instead.", .{e}) catch return summary;
            summary.warnings.append(gpa, w) catch gpa.free(w);
        }
    }

    return summary;
}

fn processOne(a: Allocator, io: Io, src: []const u8, dest: []const u8, opts: *const Options, stamper: ?*const post.Stamper, resolver: ?*resolver_mod.Resolver, lock: *SpinLock) !Outcome {
    const cwd = Io.Dir.cwd();
    const is_png = hasExt(src, &[_][]const u8{"png"});
    const in_place = is_png and std.mem.eql(u8, src, dest);

    if (!in_place) {
        if (fileExists(io, dest) and !opts.overwrite) {
            return .{ .written = false };
        }
    }

    const bytes = cwd.readFileAlloc(io, src, a, MAX_FILE) catch return error.CannotReadInput;

    var header_object: ?[]const u8 = null;
    var coords: ?@import("wcs.zig").SkyCoords = null;
    var image: img.Image8 = undefined;
    if (is_png) {
        image = try png.decode(a, bytes);
    } else {
        var data = if (hasExt(src, &FITS_EXTS))
            try fits.parse(a, bytes)
        else
            try xisf.parse(a, bytes);
        header_object = data.object;
        coords = data.coords;
        image = try pixels.toImage(a, &data);
    }

    var label_title: ?[]const u8 = null;
    var note: ?[]const u8 = null;
    if (stamper) |st| {
        const stem = std.fs.path.stem(dest);
        var label = post.Label{ .title = stem };
        if (resolver) |res| {
            lock.lock();
            const id = resolver_mod.identify(res, header_object, coords, stem);
            lock.unlock();
            label = id.label;
            note = id.note;
            if (!std.mem.eql(u8, label.title, stem)) label_title = label.title;
        }
        image = try st.resizeAndLabel(a, &image, label);
    } else if (opts.resize4kEffective()) {
        image = try post.resizeToFill(a, &image, post.TARGET_WIDTH, post.TARGET_HEIGHT);
    }

    const encoded = try png.encode(a, &image);

    if (std.fs.path.dirname(dest)) |parent| {
        cwd.createDirPath(io, parent) catch return error.CannotCreateOutputDir;
    }
    cwd.writeFile(io, .{ .sub_path = dest, .data = encoded }) catch return error.CannotWriteOutput;

    return .{ .written = true, .label = label_title, .note = note };
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
