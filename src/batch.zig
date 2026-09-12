//! FFI wrapper around astropng-core's C ABI
//! (https://github.com/peterbuitho/astropng-core), which holds the actual
//! conversion pipeline (XISF/FITS parsing, stretch, resize/stamp, WCS,
//! SIMBAD lookup, batch orchestration). Also used, via the same C ABI, by
//! the Go/Rust/Scala ports of this program.
//!
//! The public surface here (Options/Status/Progress/Summary/run) is
//! unchanged from before this module called into the shared core, so
//! src/cli.zig and src/gui/ need no changes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("astropng_core.h");
});

pub const IMAGE_EXTS = [_][]const u8{ "xisf", "fits", "fit", "fts" };

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
    /// Files to convert in parallel. `0` means the core's default
    /// (min(available_parallelism, 8)).
    concurrency: usize = 0,

    pub fn inputKind(self: Options) []const u8 {
        return if (self.png_only) ".png" else ".xisf / .fits";
    }

    pub fn resize4kEffective(self: Options) bool {
        return self.resize4k or self.png_only;
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

/// Batch-level (not per-file) failures. Known astropng-core error messages
/// are mapped back to the specific error the CLI/GUI already print;
/// anything else (including an internal core panic) becomes `CoreError`.
pub const Error = error{
    InputDirNotFound,
    CannotReadFont,
    InvalidFont,
    CoreError,
    OutOfMemory,
};

/// Context threaded through the C progress callback via `user_data`. Zig has
/// no moving GC, so the address of this stack-local struct stays valid for
/// the whole (blocking) astropng_run call.
fn Ctx(comptime R: type) type {
    return struct {
        gpa: Allocator,
        reporter: R,
        alloc_failed: bool = false,
    };
}

fn progressTrampoline(comptime R: type) fn (p: [*c]const c.AstropngProgress, user_data: ?*anyopaque) callconv(.c) void {
    return struct {
        fn cb(p: [*c]const c.AstropngProgress, user_data: ?*anyopaque) callconv(.c) void {
            const ctx: *Ctx(R) = @ptrCast(@alignCast(user_data.?));
            const progress = p.*;

            const status: Status = switch (progress.status) {
                c.AstropngFileStatus_Ok => .ok,
                c.AstropngFileStatus_Skipped => .skipped,
                c.AstropngFileStatus_Failed => .{ .failed = cStrOr(progress.status_message, "unknown error") },
                else => .{ .failed = "unknown status" },
            };

            ctx.reporter.report(.{
                .index = progress.index,
                .total = progress.total,
                .rel = cStrOr(progress.rel_path, ""),
                .status = status,
                .label = cStrOpt(progress.label),
                .note = cStrOpt(progress.note),
            });
        }
    }.cb;
}

fn cStrOpt(s: [*c]const u8) ?[]const u8 {
    if (s == null) return null;
    return std.mem.sliceTo(s, 0);
}

fn cStrOr(s: [*c]const u8, default: []const u8) []const u8 {
    return cStrOpt(s) orelse default;
}

/// Run the whole batch. `reporter` must have `fn report(self, Progress) void`.
/// `cancel` is an optional pointer to an atomic flag checked between files.
pub fn run(
    gpa: Allocator,
    io: Io,
    opts: *const Options,
    reporter: anytype,
    cancel: ?*const std.atomic.Value(bool),
) Error!Summary {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const copts = toCOptions(arena, opts) catch return error.OutOfMemory;

    const token: ?*c.AstropngCancelToken = c.astropng_cancel_token_new();
    defer if (token) |t| c.astropng_cancel_token_free(t);

    var watcher: ?std.Thread = null;
    var stop_watching = std.atomic.Value(bool).init(false);
    if (cancel != null and token != null) {
        watcher = std.Thread.spawn(.{}, watchCancel, .{ io, cancel.?, token.?, &stop_watching }) catch null;
    }
    defer {
        stop_watching.store(true, .monotonic);
        if (watcher) |w| w.join();
    }

    const R = @TypeOf(reporter);
    var ctx = Ctx(R){ .gpa = gpa, .reporter = reporter };

    var out_summary: [*c]c.AstropngSummary = null;
    var out_error: [*c]u8 = null;
    const rc = c.astropng_run(
        &copts,
        token,
        progressTrampoline(R),
        @ptrCast(&ctx),
        &out_summary,
        &out_error,
    );

    if (rc != 0) {
        const msg = cStrOr(out_error, "");
        defer if (out_error != null) c.astropng_string_free(out_error);
        if (std.mem.indexOf(u8, msg, "Input directory not found") != null) return error.InputDirNotFound;
        if (std.mem.indexOf(u8, msg, "cannot read font file") != null) return error.CannotReadFont;
        if (std.mem.indexOf(u8, msg, "is not a valid TrueType/OpenType font") != null) return error.InvalidFont;
        return error.CoreError;
    }
    defer c.astropng_summary_free(out_summary);
    const s = out_summary.*;

    var summary = Summary{
        .total = s.total,
        .converted = s.converted,
        .skipped = s.skipped,
        .failed = s.failed,
        .cancelled = s.cancelled,
    };
    if (s.warnings != null) {
        const warnings = s.warnings[0..s.warnings_len];
        for (warnings) |w| {
            const owned = gpa.dupe(u8, cStrOr(w, "")) catch return error.OutOfMemory;
            summary.warnings.append(gpa, owned) catch {
                gpa.free(owned);
                return error.OutOfMemory;
            };
        }
    }
    return summary;
}

fn watchCancel(io: Io, cancel: *const std.atomic.Value(bool), token: *c.AstropngCancelToken, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.monotonic)) {
        if (cancel.load(.monotonic)) {
            c.astropng_cancel_token_cancel(token);
            return;
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch return;
    }
}

fn toCOptions(a: Allocator, opts: *const Options) !c.AstropngOptions {
    var files: [*c]?[*:0]const u8 = null;
    if (opts.files.items.len > 0) {
        const arr = try a.alloc(?[*:0]const u8, opts.files.items.len);
        for (opts.files.items, 0..) |f, i| arr[i] = (try a.dupeZ(u8, f)).ptr;
        files = @ptrCast(arr.ptr);
    }

    return .{
        .input_dir = (try a.dupeZ(u8, opts.input_dir)).ptr,
        .output_dir = if (opts.output_dir) |d| (try a.dupeZ(u8, d)).ptr else null,
        .recursive = opts.recursive,
        .overwrite = opts.overwrite,
        .resize4k = opts.resize4k,
        .png_only = opts.png_only,
        .font_path = if (opts.font) |f| (try a.dupeZ(u8, f)).ptr else null,
        .lookup = opts.lookup,
        .files = files,
        .files_len = opts.files.items.len,
        .concurrency = opts.concurrency,
    };
}

const testing = std.testing;

test "status mapping" {
    try testing.expect(@as(Status, .ok) == .ok);
}
