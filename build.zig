const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string reported by --version") orelse "0.1.0-dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const ctx = Ctx{ .b = b, .build_options = build_options };

    // --- CLI (native target) ---------------------------------------------
    const cli = ctx.exe(target, optimize);
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Build and run the CLI").dependOn(&run_cli.step);

    // --- Tests ----------------------------------------------------------
    const engine = ctx.engine(target, optimize);
    const engine_tests = b.addTest(.{ .root_module = engine });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    b.step("test", "Run unit tests").dependOn(&run_engine_tests.step);

    // --- Cross-platform release archives -------------------------------
    // A pure-Zig CLI cross-compiles from one runner, so a single job emits
    // every platform's binary into zig-out/release/<triple>/.
    const release_step = b.step("release", "Cross-compile release binaries for all platforms");
    const triples = [_][]const u8{
        "x86_64-windows",
        "aarch64-windows",
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "x86_64-macos",
        "aarch64-macos",
    };
    for (triples) |triple| {
        const rt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        const rexe = ctx.exe(rt, .ReleaseFast);
        const install = b.addInstallArtifact(rexe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{triple}) } },
        });
        release_step.dependOn(&install.step);
    }
}

const Ctx = struct {
    b: *std.Build,
    build_options: *std.Build.Step.Options,

    /// The conversion engine as an importable module for `target`.
    fn engine(ctx: Ctx, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const m = ctx.b.createModule(.{
            .root_source_file = ctx.b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        m.addOptions("build_options", ctx.build_options);
        m.addAnonymousImport("dejavu_font", .{
            .root_source_file = ctx.b.path("assets/fonts/DejaVuSansCondensed-Bold.ttf"),
        });
        return m;
    }

    /// The CLI executable for `target`.
    fn exe(ctx: Ctx, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        return ctx.b.addExecutable(.{
            .name = "astro2png",
            .root_module = ctx.b.createModule(.{
                .root_source_file = ctx.b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "astro2png", .module = ctx.engine(target, optimize) }},
            }),
        });
    }
};
