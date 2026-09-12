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
const instance = @import("instance.zig");

const icon_png = @embedFile("icon_png");

var g_app: App = undefined;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    const gpa = init.gpa;

    // Command-line paths (Explorer launches one process per selected file).
    const initial: []const []const u8 = blk: {
        const args = init.minimal.args.toSlice(init.arena.allocator()) catch break :blk &.{};
        break :blk if (args.len > 1) args[1..] else &.{};
    };

    // Single-instance: the first launch owns the window; every later launch
    // spools its paths and exits.
    if (!instance.claim(init.io, init.environ_map, initial)) return;

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

    for (initial) |a| g_app.addPath(a);

    const c = SDLBackend.c;
    var interrupted = false;
    main_loop: while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        // Paths spooled by a second instance.
        instance.poll(init.io, init.environ_map, &g_app);

        // Custom event pump so we can pick up file drops, which dvui's SDL3
        // backend does not forward. Everything else goes to dvui as usual.
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_DROP_FILE) {
                if (event.drop.data) |data| g_app.addPath(std.mem.span(data));
                dvui.refresh(&win, @src(), null);
            } else {
                _ = try backend.addEvent(&win, event);
            }
        }

        g_app.frame() catch |e| std.log.err("frame error: {s}", .{@errorName(e)});

        const end_micros = try win.end(.{});

        const wait_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_micros);

        if (g_app.should_close) break :main_loop;
    }

    g_app.requestCancelAndJoin();
}
