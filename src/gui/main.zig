//! astro2png desktop GUI — dvui + SDL3. Same conversion engine as the CLI
//! (`astro2png` module); the batch runs on a worker thread and streams
//! progress back to the window.
//!
//! Port of the Rust `src/bin/gui/main.rs`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const engine = @import("astro2png");

const App = @import("app.zig").App;

const icon_png = @embedFile("icon_png");

var g_app: App = undefined;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    const gpa = init.gpa;

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 780.0, .h = 620.0 },
        .min_size = .{ .w = 560.0, .h = 440.0 },
        .vsync = true,
        .title = "astro2png " ++ engine.VERSION,
        .icon = icon_png,
    });
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .dark) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
        .open_flag = &window_open,
    });
    defer win.deinit();

    g_app = App.init(gpa, init.io, &win);
    defer g_app.deinit();

    // Files / folders passed on the command line.
    {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        for (args[@min(args.len, 1)..]) |a| g_app.addPath(a);
    }

    var interrupted = false;
    main_loop: while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        try backend.addAllEvents(&win);

        g_app.frame() catch |e| std.log.err("frame error: {s}", .{@errorName(e)});

        const end_micros = try win.end(.{});
        const wait_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_micros);

        if (g_app.should_close) break :main_loop;
    }

    g_app.requestCancelAndJoin();
}
