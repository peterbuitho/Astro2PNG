//! Desktop integration: a right-click / "Open with" entry for XISF and FITS
//! files that launches the GUI with the selected files.
//!
//! Port of the Rust `src/bin/gui/shell.rs`. Windows (per-user registry) and
//! Linux (`.desktop` + MIME) are implemented; macOS has nothing to install.

const std = @import("std");
const builtin = @import("builtin");

pub const EXTENSIONS = [_][]const u8{ "xisf", "fits", "fit", "fts" };

pub const Outcome = struct { ok: bool, message: []const u8 };

pub const install_label: []const u8 = switch (builtin.os.tag) {
    .windows => "Add to Explorer right-click menu",
    .macos => "",
    else => "Install \"Open with astro2png\" desktop entry",
};
pub const uninstall_label: []const u8 = switch (builtin.os.tag) {
    .windows => "Remove from Explorer right-click menu",
    .macos => "",
    else => "Remove desktop entry",
};

pub fn supported() bool {
    return install_label.len != 0;
}

pub fn isInstalled(io: std.Io) bool {
    return impl.isInstalled(io);
}
pub fn install(io: std.Io) Outcome {
    return impl.install(io);
}
pub fn uninstall(io: std.Io) Outcome {
    return impl.uninstall(io);
}

const impl = switch (builtin.os.tag) {
    .windows => WindowsImpl,
    .macos => MacImpl,
    else => LinuxImpl,
};

// ---------------------------------------------------------------------------
// Linux / XDG
// ---------------------------------------------------------------------------
const LinuxImpl = struct {
    fn dataHome(buf: []u8) ?[]const u8 {
        if (std.posix.getenv("XDG_DATA_HOME")) |x| {
            if (x.len != 0 and x[0] == '/') return x;
        }
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.local/share", .{home}) catch null;
    }

    fn desktopPath(buf: []u8) ?[]const u8 {
        var hb: [512]u8 = undefined;
        const dh = dataHome(&hb) orelse return null;
        return std.fmt.bufPrint(buf, "{s}/applications/astro2png.desktop", .{dh}) catch null;
    }

    fn isInstalled(io: std.Io) bool {
        var b: [512]u8 = undefined;
        const p = desktopPath(&b) orelse return false;
        std.Io.Dir.cwd().access(io, p, .{}) catch return false;
        return true;
    }

    fn install(io: std.Io) Outcome {
        const exe = std.process.executablePathAlloc(io, std.heap.page_allocator) catch
            return .{ .ok = false, .message = "cannot determine this program's path" };
        defer std.heap.page_allocator.free(exe);

        var hb: [512]u8 = undefined;
        const dh = dataHome(&hb) orelse return .{ .ok = false, .message = "no XDG data home" };
        const cwd = std.Io.Dir.cwd();

        var pb: [640]u8 = undefined;
        const apps = std.fmt.bufPrint(&pb, "{s}/applications", .{dh}) catch return badPath();
        cwd.createDirPath(io, apps) catch {};

        var db: [700]u8 = undefined;
        const desktop = std.fmt.bufPrint(&db, "{s}/applications/astro2png.desktop", .{dh}) catch return badPath();
        var content_buf: [1024]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf,
            \\[Desktop Entry]
            \\Type=Application
            \\Name=astro2png
            \\Comment=Convert XISF / FITS astrophotos to PNG
            \\Exec="{s}" %F
            \\Icon=astro2png
            \\Terminal=false
            \\Categories=Graphics;Photography;
            \\MimeType=image/fits;application/fits;image/x-fits;application/x-xisf;
            \\
        , .{exe}) catch return badPath();
        cwd.writeFile(io, .{ .sub_path = desktop, .data = content }) catch
            return .{ .ok = false, .message = "could not write the .desktop file" };

        return .{ .ok = true, .message = "Installed — astro2png now appears under \"Open with\" for FITS and XISF files." };
    }

    fn uninstall(io: std.Io) Outcome {
        var b: [512]u8 = undefined;
        if (desktopPath(&b)) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
        return .{ .ok = true, .message = "Removed the desktop entry." };
    }

    fn badPath() Outcome {
        return .{ .ok = false, .message = "path too long" };
    }
};

// ---------------------------------------------------------------------------
// Windows — per-user registry under HKCU\Software\Classes\SystemFileAssociations
// ---------------------------------------------------------------------------
const WindowsImpl = struct {
    const w = std.os.windows;
    const HKEY_CURRENT_USER: w.HKEY = @ptrFromInt(0x80000001);
    const KEY_READ: w.REGSAM = @bitCast(@as(u32, 0x20019));
    const KEY_WRITE: w.REGSAM = @bitCast(@as(u32, 0x20006));
    const REG_SZ: w.DWORD = 1;

    extern "advapi32" fn RegCreateKeyExW(hKey: w.HKEY, lpSubKey: [*:0]const u16, Reserved: w.DWORD, lpClass: ?[*:0]const u16, dwOptions: w.DWORD, samDesired: w.REGSAM, lpSecurityAttributes: ?*anyopaque, phkResult: *w.HKEY, lpdwDisposition: ?*w.DWORD) callconv(.winapi) w.LSTATUS;
    extern "advapi32" fn RegSetValueExW(hKey: w.HKEY, lpValueName: ?[*:0]const u16, Reserved: w.DWORD, dwType: w.DWORD, lpData: [*]const u8, cbData: w.DWORD) callconv(.winapi) w.LSTATUS;
    extern "advapi32" fn RegOpenKeyExW(hKey: w.HKEY, lpSubKey: [*:0]const u16, ulOptions: w.DWORD, samDesired: w.REGSAM, phkResult: *w.HKEY) callconv(.winapi) w.LSTATUS;
    extern "advapi32" fn RegCloseKey(hKey: w.HKEY) callconv(.winapi) w.LSTATUS;
    extern "advapi32" fn RegDeleteTreeW(hKey: w.HKEY, lpSubKey: ?[*:0]const u16) callconv(.winapi) w.LSTATUS;

    const VERB = "astro2png";
    const LABEL = "Convert to PNG with astro2png";

    fn keyPathW(ext: []const u8, out: []u16) [:0]const u16 {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "Software\\Classes\\SystemFileAssociations\\.{s}\\shell\\" ++ VERB, .{ext}) catch unreachable;
        const n = std.unicode.utf8ToUtf16Le(out, s) catch unreachable;
        out[n] = 0;
        return out[0..n :0];
    }

    fn isInstalled(io: std.Io) bool {
        _ = io;
        var wbuf: [300]u16 = undefined;
        var base: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&base, "Software\\Classes\\SystemFileAssociations\\.{s}\\shell\\" ++ VERB ++ "\\command", .{EXTENSIONS[0]}) catch return false;
        const n = std.unicode.utf8ToUtf16Le(&wbuf, s) catch return false;
        wbuf[n] = 0;
        var hk: w.HKEY = undefined;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, wbuf[0..n :0], 0, KEY_READ, &hk) != 0) return false;
        _ = RegCloseKey(hk);
        return true;
    }

    fn install(io: std.Io) Outcome {
        const exe = std.process.executablePathAlloc(io, std.heap.page_allocator) catch
            return .{ .ok = false, .message = "cannot determine this program's path" };
        defer std.heap.page_allocator.free(exe);

        var cmd_buf: [1024]u8 = undefined;
        const command = std.fmt.bufPrint(&cmd_buf, "\"{s}\" \"%1\"", .{exe}) catch return .{ .ok = false, .message = "path too long" };

        for (EXTENSIONS) |ext| {
            var wkey: [300]u16 = undefined;
            const kp = keyPathW(ext, &wkey);
            var hk: w.HKEY = undefined;
            if (RegCreateKeyExW(HKEY_CURRENT_USER, kp.ptr, 0, null, 0, KEY_WRITE, null, &hk, null) != 0)
                return .{ .ok = false, .message = "registry write failed" };
            defer _ = RegCloseKey(hk);
            setStr(hk, null, LABEL);
            setStr(hk, utf16z("Icon", wkey[280..]), exe);
            setStr(hk, utf16z("MultiSelectModel", wkey[290..]), "Player");

            var chk: w.HKEY = undefined;
            if (RegCreateKeyExW(hk, utf16z("command", wkey[260..]).ptr, 0, null, 0, KEY_WRITE, null, &chk, null) != 0)
                return .{ .ok = false, .message = "registry write failed" };
            defer _ = RegCloseKey(chk);
            setStr(chk, null, command);
        }
        return .{ .ok = true, .message = "Added \"" ++ LABEL ++ "\" to the right-click menu (current user)." };
    }

    fn uninstall(io: std.Io) Outcome {
        _ = io;
        for (EXTENSIONS) |ext| {
            var wkey: [300]u16 = undefined;
            const kp = keyPathW(ext, &wkey);
            _ = RegDeleteTreeW(HKEY_CURRENT_USER, kp.ptr);
        }
        return .{ .ok = true, .message = "Removed the right-click menu entry." };
    }

    fn utf16z(comptime s: []const u8, out: []u16) [:0]const u16 {
        const n = std.unicode.utf8ToUtf16Le(out, s) catch unreachable;
        out[n] = 0;
        return out[0..n :0];
    }

    fn setStr(hk: w.HKEY, name: ?[:0]const u16, val: []const u8) void {
        var wbuf: [1200]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wbuf, val) catch return;
        wbuf[n] = 0;
        const bytes = std.mem.sliceAsBytes(wbuf[0 .. n + 1]);
        _ = RegSetValueExW(hk, if (name) |nm| nm.ptr else null, 0, REG_SZ, bytes.ptr, @intCast(bytes.len));
    }
};

// ---------------------------------------------------------------------------
// macOS — nothing to install
// ---------------------------------------------------------------------------
const MacImpl = struct {
    fn isInstalled(io: std.Io) bool {
        _ = io;
        return false;
    }
    fn install(io: std.Io) Outcome {
        _ = io;
        return .{ .ok = false, .message = "Not needed on macOS: drop files onto the window." };
    }
    fn uninstall(io: std.Io) Outcome {
        return MacImpl.install(io);
    }
};
