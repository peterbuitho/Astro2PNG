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

    const shot_path: ?[]const u8 = init.environ_map.get("A2P_SHOT");
    var frames: u32 = 0;

    const c = SDLBackend.c;
    var interrupted = false;
    main_loop: while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

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

        frames += 1;
        if (shot_path) |p| {
            if (frames == 3) {
                screenshot(gpa, &backend, p) catch |e| std.log.err("screenshot: {s}", .{@errorName(e)});
                break :main_loop;
            }
            dvui.refresh(&win, @src(), null);
        }

        const wait_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_micros);

        if (g_app.should_close) break :main_loop;
    }

    g_app.requestCancelAndJoin();
}

/// Debug aid: dump the current SDL back buffer to a PNG (A2P_SHOT=<path>).
fn screenshot(gpa: std.mem.Allocator, backend: *SDLBackend, path: []const u8) !void {
    const c = SDLBackend.c;
    var surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(surface);
    if (surface.*.format != c.SDL_PIXELFORMAT_ABGR8888) {
        surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ABGR8888) orelse return error.Convert;
    }
    const w: u32 = @intCast(surface.*.w);
    const h: u32 = @intCast(surface.*.h);
    const src: [*]const u8 = @ptrCast(surface.*.pixels.?);
    const pitch: usize = @intCast(surface.*.pitch);

    const rgb = try gpa.alloc(u8, @as(usize, w) * h * 3);
    defer gpa.free(rgb);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s = src[y * pitch + x * 4 ..];
            const d = rgb[(y * w + x) * 3 ..];
            d[0] = s[0];
            d[1] = s[1];
            d[2] = s[2];
        }
    }
    var image = engine.image.Image8{ .width = w, .height = h, .channels = 3, .pixels = rgb };
    const bytes = try engine.png.encode(gpa, &image);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(g_app.io, .{ .sub_path = path, .data = bytes });
    std.log.info("screenshot -> {s} ({d}x{d})", .{ path, w, h });
}
