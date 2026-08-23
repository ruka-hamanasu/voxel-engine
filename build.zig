const std = @import("std");
const sdl = @import("build/sdl.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseSafe so plain `zig build`/`run` gives a
    // manually testable binary: decent performance, safety checks on.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseSafe;

    const nuklear = b.dependency("nuklear", .{});
    const clap = b.dependency("clap", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("clap", clap.module("clap"));
    // Vendored SDL2, compiled from source and linked statically (works
    // for every target, incl. pinned old-glibc release builds).
    sdl.addSdl(b, exe_mod);
    exe_mod.addIncludePath(nuklear.path(""));
    exe_mod.addIncludePath(nuklear.path("demo/sdl_renderer"));
    exe_mod.addIncludePath(b.path("src"));
    exe_mod.addCSourceFile(.{
        .file = b.path("src/nk_impl.c"),
        .flags = &.{},
    });

    const exe = b.addExecutable(.{
        .name = "voxel_engine",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
