const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nuklear = b.dependency("nuklear", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("SDL2", .{});
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
