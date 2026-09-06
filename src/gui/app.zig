//! The GUI application state and per-frame UI. Port of the Rust
//! `src/bin/gui/main.rs` `App`.

const std = @import("std");
const dvui = @import("dvui");
const engine = @import("astro2png");
const batch = engine.batch;

const shell = @import("shell.zig");

const BUF = 1024;

/// Tiny spin lock (0.16 dropped `std.Thread.Mutex`). Critical sections here
/// only append a string and bump two counters, so spinning is fine.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    should_close: bool = false,

    // form
    input_buf: [BUF]u8 = [_]u8{0} ** BUF,
    output_buf: [BUF]u8 = [_]u8{0} ** BUF,
    font_buf: [BUF]u8 = [_]u8{0} ** BUF,
    recursive: bool = false,
    overwrite: bool = false,
    resize4k: bool = true,
    png_only: bool = false,
    lookup: bool = true,

    /// Explicit files (from the command line, "Add files…", or a drop).
    files: std.ArrayList([]const u8) = .empty,

    // desktop integration
    integration_installed: bool = false,
    integration_msg: ?[]const u8 = null,

    // run state
    job: ?*Job = null,
    last_summary: ?SummarySnapshot = null,
    last_error: ?[]const u8 = null,
    job_lines_snapshot: ?std.ArrayList([]const u8) = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, win: *dvui.Window) App {
        return .{
            .gpa = gpa,
            .io = io,
            .win = win,
            .integration_installed = shell.isInstalled(io),
        };
    }

    pub fn deinit(self: *App) void {
        self.requestCancelAndJoin();
        for (self.files.items) |f| self.gpa.free(f);
        self.files.deinit(self.gpa);
        if (self.last_error) |e| self.gpa.free(e);
        if (self.integration_msg) |m| self.gpa.free(m);
        self.clearSummary();
    }

    fn clearSummary(self: *App) void {
        if (self.last_summary) |*s| s.deinit(self.gpa);
        self.last_summary = null;
    }

    pub fn addPath(self: *App, path: []const u8) void {
        const is_dir = blk: {
            var d = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch break :blk false;
            d.close(self.io);
            break :blk true;
        };
        if (is_dir) {
            setBuf(&self.input_buf, path);
        } else {
            for (self.files.items) |f| if (std.mem.eql(u8, f, path)) return;
            const dup = self.gpa.dupe(u8, path) catch return;
            self.files.append(self.gpa, dup) catch self.gpa.free(dup);
        }
    }

    pub fn requestCancelAndJoin(self: *App) void {
        if (self.job) |job| {
            job.cancel.store(true, .monotonic);
            job.thread.join();
            job.deinit(self.gpa);
            self.gpa.destroy(job);
            self.job = null;
        }
    }

    // --- per-frame UI ---------------------------------------------------

    pub fn frame(self: *App) !void {
        self.pollDrops();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .style = .window });
        defer scroll.deinit();

        {
            var pad = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = dvui.Rect.all(10) });
            defer pad.deinit();

            dvui.label(@src(), "XISF / FITS \u{2192} PNG batch converter", .{}, .{ .font = .theme(.title) });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 6 } });

            const running = self.job != null;
            const file_mode = self.files.items.len != 0;

            // ---- inputs ----
            {
                var dis = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
                defer dis.deinit();

                if (file_mode) {
                    var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                    defer hb.deinit();
                    dvui.label(@src(), "{d} file(s) selected", .{self.files.items.len}, .{ .gravity_y = 0.5 });
                    if (!running and dvui.button(@src(), "Add files\u{2026}", .{}, .{})) try self.pickFiles();
                    if (!running and dvui.button(@src(), "Clear", .{}, .{})) self.clearFiles();
                } else {
                    try self.pathRow(@src(), "Input folder", &self.input_buf, "current folder", running, .folder);
                    var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                    defer hb.deinit();
                    if (!running and dvui.button(@src(), "Add files\u{2026}", .{}, .{})) try self.pickFiles();
                    dvui.label(@src(), "  or drop files / a folder onto this window", .{}, .{});
                }

                try self.pathRow(@src(), "Output folder", &self.output_buf, "same as input", running, .folder);
                try self.pathRow(@src(), "Stamp font", &self.font_buf, "bundled DejaVu Sans Condensed Bold", running, .font);

                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 6 } });

                if (!running) {
                    _ = dvui.checkbox(@src(), &self.recursive, "Recurse into subfolders", .{});
                    _ = dvui.checkbox(@src(), &self.overwrite, "Overwrite existing PNGs", .{});
                    _ = dvui.checkbox(@src(), &self.png_only, "PNG only (no XISF/FITS conversion)", .{});
                    _ = dvui.checkbox(@src(), &self.resize4k, "Resize to 3840\u{00d7}2160 and stamp object name", .{});
                    _ = dvui.checkbox(@src(), &self.lookup, "Stamp object name (SIMBAD lookup); off = file name", .{});
                } else {
                    dvui.label(@src(), "Recurse: {}   Overwrite: {}   PNG-only: {}   4K: {}   Lookup: {}", .{
                        self.recursive, self.overwrite, self.png_only, self.resize4k, self.lookup,
                    }, .{});
                }
            }

            // ---- desktop integration (Windows / Linux) ----
            if (shell.supported()) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 8 } });
                var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                defer hb.deinit();
                const label = if (self.integration_installed) shell.uninstall_label else shell.install_label;
                if (dvui.button(@src(), label, .{}, .{})) {
                    const outcome = if (self.integration_installed) shell.uninstall(self.io) else shell.install(self.io);
                    self.integration_installed = shell.isInstalled(self.io);
                    if (self.integration_msg) |m| self.gpa.free(m);
                    self.integration_msg = self.gpa.dupe(u8, outcome.message) catch null;
                }
                if (self.integration_msg) |m| dvui.label(@src(), "{s}", .{m}, .{});
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 10 } });

            // ---- run / cancel ----
            {
                var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer hb.deinit();
                if (running) {
                    if (dvui.button(@src(), "Cancel", .{}, .{})) {
                        if (self.job) |j| j.cancel.store(true, .monotonic);
                    }
                    const j = self.job.?;
                    j.mutex.lock();
                    const done = j.done;
                    const total = j.total;
                    j.mutex.unlock();
                    const frac: f32 = if (total > 0) @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total)) else 0;
                    dvui.progress(@src(), .{ .percent = frac }, .{ .expand = .horizontal, .min_size_content = .{ .w = 100, .h = 20 }, .gravity_y = 0.5 });
                    dvui.label(@src(), "  {d} / {d}", .{ done, total }, .{ .gravity_y = 0.5 });
                } else {
                    const btn: []const u8 = if (file_mode) "Convert files" else if (self.png_only) "Resize && stamp PNGs" else "Convert";
                    if (dvui.button(@src(), btn, .{}, .{ .font = .theme(.title) })) try self.start();
                }
            }

            if (self.last_error) |e| dvui.label(@src(), "{s}", .{e}, .{});
            if (self.last_summary) |s| {
                dvui.label(@src(), "{s}: {d}   Skipped: {d}   Failed: {d}{s}", .{
                    if (self.png_only) "Processed" else "Converted",
                    s.converted,
                    s.skipped,
                    s.failed,
                    if (s.cancelled) "   (cancelled)" else "",
                }, .{});
                for (s.warnings.items) |w| dvui.label(@src(), "\u{26a0} {s}", .{w}, .{});
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = 6 } });
        }

        // ---- log ----
        {
            var logbox = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .w = 0, .h = 180 }, .background = true });
            defer logbox.deinit();
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer tl.deinit();

            if (self.job) |j| {
                j.mutex.lock();
                defer j.mutex.unlock();
                for (j.lines.items) |line| tl.addText(line, .{});
                if (j.finished) self.finishJob(j);
            } else if (self.job_lines_snapshot) |snap| {
                for (snap.items) |line| tl.addText(line, .{});
            }
        }
    }

    fn pathRow(self: *App, src: std.builtin.SourceLocation, label: []const u8, buf: []u8, hint: []const u8, disabled: bool, kind: enum { folder, font }) !void {
        var hb = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hb.deinit();
        dvui.label(@src(), "{s}", .{label}, .{ .min_size_content = .{ .w = 110, .h = 0 }, .gravity_y = 0.5 });
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = buf }, .placeholder = hint }, .{ .expand = .horizontal });
        te.deinit();
        if (!disabled and dvui.button(@src(), "Browse\u{2026}", .{}, .{})) {
            const picked = switch (kind) {
                .folder => dvui.dialogNativeFolderSelect(self.gpa, .{ .title = label }) catch null,
                .font => dvui.dialogNativeFileOpen(self.gpa, .{ .title = "Choose a font", .filters = &.{ "*.ttf", "*.otf" } }) catch null,
            };
            if (picked) |p| {
                defer self.gpa.free(p);
                setBuf(buf, p);
            }
        }
    }

    fn pickFiles(self: *App) !void {
        const picked = dvui.dialogNativeFileOpenMultiple(self.gpa, .{
            .title = "Choose images",
            .filters = &.{ "*.xisf", "*.fits", "*.fit", "*.fts", "*.png" },
        }) catch null;
        if (picked) |list| {
            defer {
                for (list) |p| self.gpa.free(p);
                self.gpa.free(list);
            }
            for (list) |p| self.addPath(p);
        }
    }

    fn clearFiles(self: *App) void {
        for (self.files.items) |f| self.gpa.free(f);
        self.files.clearRetainingCapacity();
    }

    fn pollDrops(self: *App) void {
        // TODO: dvui's SDL3 backend doesn't yet forward SDL_EVENT_DROP_FILE to
        // dvui events. Drag-and-drop will need a small backend patch or direct
        // SDL event polling. For now: command line + "Add files…".
        _ = self;
    }

    // --- worker -------------------------------------------------------

    fn start(self: *App) !void {
        self.requestCancelAndJoin();
        self.clearSummary();
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = null;
        if (self.job_lines_snapshot) |*snap| {
            for (snap.items) |l| self.gpa.free(l);
            snap.deinit(self.gpa);
            self.job_lines_snapshot = null;
        }

        const job = try self.gpa.create(Job);
        job.* = Job.init(self.gpa);

        // Snapshot the form into the job's arena.
        const a = job.arena.allocator();
        var opts = batch.Options{
            .input_dir = try a.dupe(u8, nonEmpty(sliceBuf(&self.input_buf), ".")),
            .output_dir = if (sliceBuf(&self.output_buf).len != 0) try a.dupe(u8, sliceBuf(&self.output_buf)) else null,
            .recursive = self.recursive,
            .overwrite = self.overwrite,
            .resize4k = self.resize4k,
            .png_only = self.png_only,
            .lookup = self.lookup,
            .font = if (sliceBuf(&self.font_buf).len != 0) try a.dupe(u8, sliceBuf(&self.font_buf)) else null,
        };
        for (self.files.items) |f| try opts.files.append(a, try a.dupe(u8, f));
        job.opts = opts;

        job.thread = try std.Thread.spawn(.{}, workerMain, .{ job, self.io, self.win });
        self.job = job;
    }

    fn finishJob(self: *App, job: *Job) void {
        // called with job.mutex held
        if (job.summary) |s| {
            var snap = SummarySnapshot{};
            snap.converted = s.converted;
            snap.skipped = s.skipped;
            snap.failed = s.failed;
            snap.cancelled = s.cancelled;
            for (s.warnings.items) |w| snap.warnings.append(self.gpa, self.gpa.dupe(u8, w) catch continue) catch {};
            self.last_summary = snap;
        }
        if (job.err) |e| self.last_error = self.gpa.dupe(u8, e) catch null;

        // Keep the log visible after the job goes away.
        var snap: std.ArrayList([]const u8) = .empty;
        for (job.lines.items) |l| snap.append(self.gpa, self.gpa.dupe(u8, l) catch continue) catch {};
        self.job_lines_snapshot = snap;

        job.mutex.unlock();
        job.thread.join();
        job.mutex.lock();
        job.deinit(self.gpa);
        self.gpa.destroy(job);
        self.job = null;
    }
};

fn workerMain(job: *Job, io: std.Io, win: *dvui.Window) void {
    var reporter = Reporter{ .job = job, .win = win };
    const summary = batch.run(job.arena.allocator(), io, &job.opts, &reporter, &job.cancel) catch |err| {
        job.mutex.lock();
        job.err = @errorName(err);
        job.finished = true;
        job.mutex.unlock();
        dvui.refresh(win, @src(), null);
        return;
    };
    job.mutex.lock();
    job.summary = summary;
    job.total = summary.total;
    job.finished = true;
    job.mutex.unlock();
    dvui.refresh(win, @src(), null);
}

const Reporter = struct {
    job: *Job,
    win: *dvui.Window,

    pub fn report(self: *Reporter, p: batch.Progress) void {
        const job = self.job;
        job.mutex.lock();
        defer job.mutex.unlock();
        const a = job.arena.allocator();
        const tag: []const u8 = switch (p.status) {
            .ok => "OK   ",
            .skipped => "SKIP ",
            .failed => "ERROR",
        };
        var line = std.ArrayList(u8).initCapacity(a, 96) catch return;
        line.print(a, "{s} {s}", .{ tag, p.rel }) catch {};
        if (p.status == .failed) line.print(a, ": {s}", .{p.status.failed}) catch {};
        if (p.label) |l| line.print(a, "  \u{2192} {s}", .{l}) catch {};
        line.append(a, '\n') catch {};
        if (p.note) |n| line.print(a, "      note: {s}\n", .{n}) catch {};
        job.lines.append(a, line.items) catch {};
        job.done = p.index;
        job.total = p.total;
        dvui.refresh(self.win, @src(), null);
    }
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    opts: batch.Options = .{},
    thread: std.Thread = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    mutex: SpinLock = .{},
    lines: std.ArrayList([]const u8) = .empty,
    done: usize = 0,
    total: usize = 0,
    finished: bool = false,
    summary: ?batch.Summary = null,
    err: ?[]const u8 = null,

    fn init(gpa: std.mem.Allocator) Job {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }
    fn deinit(self: *Job, gpa: std.mem.Allocator) void {
        _ = gpa;
        if (self.summary) |*s| s.warnings.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

const SummarySnapshot = struct {
    converted: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
    cancelled: bool = false,
    warnings: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *SummarySnapshot, gpa: std.mem.Allocator) void {
        for (self.warnings.items) |w| gpa.free(w);
        self.warnings.deinit(gpa);
    }
};

fn sliceBuf(buf: []const u8) []const u8 {
    const z = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.trim(u8, buf[0..z], " \t");
}

fn setBuf(buf: []u8, val: []const u8) void {
    const n = @min(val.len, buf.len - 1);
    @memcpy(buf[0..n], val[0..n]);
    buf[n] = 0;
}

fn nonEmpty(s: []const u8, dflt: []const u8) []const u8 {
    return if (s.len == 0) dflt else s;
}
