//! Single-instance handoff. Windows Explorer starts one process per selected
//! file for a right-click verb (and dropping several files on the .exe does the
//! same). The first launch owns the window; every later launch drops its paths
//! in a spool directory and exits, and the primary picks them up each frame.
//!
//! Primary detection is a named mutex on Windows (auto-released when the
//! process dies, so there is no stale-lock problem). On other platforms every
//! launch is primary — Linux/macOS file managers pass the whole selection to
//! one process anyway.

const std = @import("std");
const builtin = @import("builtin");

const App = @import("app.zig").App;

/// Try to become the primary instance. Returns true when this process owns the
/// window; false when another instance already runs (its `paths` have been
/// spooled and the caller should exit).
pub fn claim(io: std.Io, environ: *const std.process.Environ.Map, paths: []const []const u8) bool {
    return impl.claim(io, environ, paths);
}

/// Called once per frame by the primary: pick up any spooled paths.
pub fn poll(io: std.Io, environ: *const std.process.Environ.Map, app: *App) void {
    impl.poll(io, environ, app);
}

const impl = if (builtin.os.tag == .windows) Windows else Other;

const Other = struct {
    fn claim(_: std.Io, _: *const std.process.Environ.Map, _: []const []const u8) bool {
        return true;
    }
    fn poll(_: std.Io, _: *const std.process.Environ.Map, _: *App) void {}
};

const Windows = struct {
    const w = std.os.windows;
    const mutex_name = "Local\\astro2png-single-instance";

    var primary_handle: ?w.HANDLE = null;
    var spool_seq: std.atomic.Value(u32) = .init(0);

    extern "kernel32" fn CreateMutexW(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: w.BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?w.HANDLE;

    fn claim(io: std.Io, environ: *const std.process.Environ.Map, paths: []const []const u8) bool {
        var name_w: [mutex_name.len + 1]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&name_w, mutex_name) catch return true;
        name_w[n] = 0;

        const handle = CreateMutexW(null, .FALSE, name_w[0..n :0].ptr);
        const already = w.GetLastError() == .ALREADY_EXISTS;
        if (handle == null) return true; // can't tell — behave as primary

        if (!already) {
            primary_handle = handle; // keep for the life of the process
            var buf: [512]u8 = undefined;
            if (spoolDir(environ, &buf)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            return true;
        }

        spool(io, environ, paths);
        return false;
    }

    fn spoolDir(environ: *const std.process.Environ.Map, buf: []u8) ?[]const u8 {
        const base = environ.get("LOCALAPPDATA") orelse environ.get("TEMP") orelse return null;
        return std.fmt.bufPrint(buf, "{s}\\astro2png\\incoming", .{base}) catch null;
    }

    fn spool(io: std.Io, environ: *const std.process.Environ.Map, paths: []const []const u8) void {
        if (paths.len == 0) return;
        var dbuf: [512]u8 = undefined;
        const dir = spoolDir(environ, &dbuf) orelse return;
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir) catch {};

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(std.heap.page_allocator);
        for (paths) |p| {
            body.appendSlice(std.heap.page_allocator, p) catch return;
            body.append(std.heap.page_allocator, '\n') catch return;
        }

        var fbuf: [600]u8 = undefined;
        const seq = spool_seq.fetchAdd(1, .monotonic);
        const path = std.fmt.bufPrint(&fbuf, "{s}\\{d}-{d}.txt", .{ dir, w.GetCurrentProcessId(), seq }) catch return;
        cwd.writeFile(io, .{ .sub_path = path, .data = body.items }) catch {};
    }

    fn poll(io: std.Io, environ: *const std.process.Environ.Map, app: *App) void {
        var dbuf: [512]u8 = undefined;
        const dir_path = spoolDir(environ, &dbuf) orelse return;

        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var it = dir.iterate();
        var scratch: [64 * 1024]u8 = undefined;
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;

            var fbuf: [700]u8 = undefined;
            const full = std.fmt.bufPrint(&fbuf, "{s}\\{s}", .{ dir_path, entry.name }) catch continue;
            const data = std.Io.Dir.cwd().readFile(io, full, &scratch) catch continue;
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                const p = std.mem.trim(u8, line, " \t\r");
                if (p.len != 0) app.addPath(p);
            }
            std.Io.Dir.cwd().deleteFile(io, full) catch {};
        }
    }
};
