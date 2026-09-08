//! Argument parsing and the run loop for the `astro2png` CLI.
//! Port of the Rust `main.rs`.

const std = @import("std");
const engine = @import("astro2png");
const batch = engine.batch;

const usage_text =
    \\astro2png {s} - batch convert XISF and FITS astronomical images to PNG
    \\
    \\Usage:
    \\  astro2png [input_dir] [output_dir] [--recursive|-r] [--overwrite] [--resize4k] [--filename] [-j N]
    \\  astro2png [input_dir] [output_dir] --png-only [--recursive|-r] [--overwrite] [--filename]
    \\  astro2png <file>... [output_dir] [--overwrite] [--resize4k] [--filename]
    \\
    \\Converts every .xisf, .fits, .fit and .fts file found in input_dir, or the
    \\files given (.png files are only resized/stamped). If input_dir is omitted,
    \\the current folder is used. If output_dir is omitted, PNGs are written next
    \\to their source files.
    \\
    \\Options:
    \\  -r, --recursive   recurse into subfolders (output mirrors structure)
    \\      --overwrite    overwrite existing .png files (default: skip)
    \\      --resize4k     scale each PNG to exactly 3840x2160 (aspect kept,
    \\                     centre-cropped) and stamp the object name bottom-right
    \\      --filename     stamp the plain file name: no header OBJECT, no online
    \\                     lookup (aliases: --no-lookup, --offline)
    \\      --png-only     skip XISF/FITS conversion: take existing .png files and
    \\                     only resize/annotate them (implies --resize4k)
    \\      --font <file>  .ttf/.otf font file for the stamp (default: bundled
    \\                     DejaVu Sans Condensed Bold). Also accepts --font=<file>.
    \\  -j, --concurrency N  convert N files in parallel
    \\                     (default: number of CPUs, capped at 8)
    \\  -V, --version     print version
    \\  -h, --help        show this help
    \\
;

/// Returns the process exit code.
pub fn run(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, args: []const []const u8) !u8 {
    var opts = batch.Options{ .lookup = true };
    var input_dir: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--recursive") or eq(a, "-r")) {
            opts.recursive = true;
        } else if (eq(a, "--overwrite")) {
            opts.overwrite = true;
        } else if (eq(a, "--resize4k") or eq(a, "-resize4k")) {
            opts.resize4k = true;
        } else if (eq(a, "--png-only")) {
            opts.png_only = true;
        } else if (eq(a, "--filename") or eq(a, "--no-lookup") or eq(a, "--offline")) {
            opts.lookup = false;
        } else if (eq(a, "-j") or eq(a, "--concurrency")) {
            i += 1;
            const n = if (i < args.len) (std.fmt.parseInt(usize, args[i], 10) catch 0) else 0;
            if (n < 1) {
                try out.writeAll("-j requires a positive integer\n");
                try out.print(usage_text, .{engine.VERSION});
                return 2;
            }
            opts.concurrency = n;
        } else if (std.mem.startsWith(u8, a, "-j")) {
            const n = std.fmt.parseInt(usize, a[2..], 10) catch 0;
            if (n < 1) {
                try out.writeAll("-j requires a positive integer\n");
                try out.print(usage_text, .{engine.VERSION});
                return 2;
            }
            opts.concurrency = n;
        } else if (eq(a, "--font")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) {
                try out.writeAll("--font requires a path to a .ttf/.otf file\n");
                try out.print(usage_text, .{engine.VERSION});
                return 2;
            }
            opts.font = args[i];
        } else if (std.mem.startsWith(u8, a, "--font=")) {
            const f = a["--font=".len..];
            if (f.len == 0) {
                try out.writeAll("--font requires a path to a .ttf/.otf file\n");
                return 2;
            }
            opts.font = f;
        } else if (eq(a, "--version") or eq(a, "-V")) {
            try out.print("astro2png {s}\n", .{engine.VERSION});
            return 0;
        } else if (eq(a, "--help") or eq(a, "-h") or eq(a, "/?")) {
            try out.print(usage_text, .{engine.VERSION});
            return 0;
        } else if (std.mem.startsWith(u8, a, "-")) {
            try out.print("Unknown option: {s}\n", .{a});
            try out.print(usage_text, .{engine.VERSION});
            return 2;
        } else {
            if (isFile(io, a)) {
                try opts.files.append(gpa, a);
            } else if (input_dir == null and opts.files.items.len == 0) {
                input_dir = a;
            } else if (output_dir == null) {
                output_dir = a;
            } else {
                try out.print("Unexpected argument: {s}\n", .{a});
                return 2;
            }
        }
    }

    if (opts.files.items.len != 0 and output_dir == null) {
        output_dir = input_dir;
        input_dir = null;
    }
    opts.input_dir = input_dir orelse ".";
    opts.output_dir = output_dir;

    const verb: []const u8 = if (opts.png_only) "Processed" else "Converted";

    var reporter = Reporter{ .out = out };
    var summary = batch.run(gpa, io, &opts, &reporter, null) catch |err| {
        try out.print("{s}\n", .{@errorName(err)});
        return 2;
    };
    defer summary.deinit(gpa);

    if (summary.total == 0) {
        try out.print("No {s} files found.\n", .{opts.inputKind()});
        return 0;
    }

    try out.print("\n{s}: {d}   Skipped: {d}   Failed: {d}\n", .{
        verb, summary.converted, summary.skipped, summary.failed,
    });
    for (summary.warnings.items) |w| try out.print("WARNING: {s}\n", .{w});

    return if (summary.failed > 0) 1 else 0;
}

const Reporter = struct {
    out: *std.Io.Writer,

    pub fn report(self: *Reporter, p: batch.Progress) void {
        const w = self.out;
        switch (p.status) {
            .ok => {
                if (p.label) |label| {
                    w.print("OK    {s}  ->  {s}\n", .{ p.rel, label }) catch {};
                } else {
                    w.print("OK    {s}\n", .{p.rel}) catch {};
                }
            },
            .skipped => w.print("SKIP  {s}\n", .{p.rel}) catch {},
            .failed => |e| w.print("ERROR {s}: {s}\n", .{ p.rel, e }) catch {},
        }
        if (p.note) |note| w.print("      note: {s}\n", .{note}) catch {};
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isFile(io: std.Io, p: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, p, .{}) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;
    return st.kind == .file;
}
