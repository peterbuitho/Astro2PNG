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

    // --- Desktop GUI (opt-in: -Dgui) ----------------------------------
    // Uses dvui with the SDL3 backend (SDL is built from source as a lazy
    // dependency, so no system libraries are needed). The CLI build above
    // never touches this.
    const want_gui = b.option(bool, "gui", "Also build the desktop GUI (astro2png-gui)") orelse false;
    if (want_gui) {
        const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
        const gui = b.addExecutable(.{
            .name = "astro2png-gui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "astro2png", .module = ctx.engine(target, optimize) },
                    .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                    .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") },
                },
            }),
        });
        gui.root_module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("assets/icon-256.png") });
        // No console window on Windows when the .exe is double-clicked.
        if (gui.rootModuleTarget().os.tag == .windows) gui.subsystem = .Windows;
        b.installArtifact(gui);

        const run_gui = b.addRunArtifact(gui);
        run_gui.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_gui.addArgs(args);
        b.step("run-gui", "Build and run the desktop GUI").dependOn(&run_gui.step);
    }

    // Release builds are now native-per-target (see .github/workflows/
    // release.yml): astropng-core is a Rust static library built for the
    // running machine's target, so the previous single-job, six-triple
    // cross-compile (which needed no C/Rust toolchain at all) no longer
    // applies. `zig build -Doptimize=ReleaseFast` on each release runner
    // produces that runner's native binary via the `cli`/`gui` artifacts
    // installed above.
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
        m.addIncludePath(ctx.b.path("third_party/astropng-core/include"));
        m.addLibraryPath(ctx.b.path("third_party/astropng-core/lib"));
        m.linkSystemLibrary("astropng_core", .{});
        m.link_libc = true;
        // Rust's default panic=unwind needs libunwind's _Unwind_* symbols;
        // gcc/link.exe normally link this automatically, but Zig's linker
        // doesn't. astropng-core's ureq/std also pull in several Win32
        // libraries that a plain `cc`-driven link would add implicitly.
        m.linkSystemLibrary("unwind", .{});
        if (target.result.os.tag == .windows) {
            m.linkSystemLibrary("ws2_32", .{}); // sockets (ureq)
            m.linkSystemLibrary("userenv", .{}); // GetUserProfileDirectoryW (std)
            m.linkSystemLibrary("bcrypt", .{}); // BCryptGenRandom (getrandom)
            m.linkSystemLibrary("ntdll", .{});
        }
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
