//! astro2png command-line interface.

const std = @import("std");
const engine = @import("astro2png");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_fw.interface;

    const args = try init.minimal.args.toSlice(gpa);
    const code = try cli.run(gpa, io, out, args);
    try out.flush();
    if (code != 0) std.process.exit(code);
}
