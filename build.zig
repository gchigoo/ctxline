const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const library = b.createModule(.{
        .root_source_file = b.path("src/ctxline.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ctxline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("ctxline", library);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .name = "ctxline-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ctxline.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_exe = b.addRunArtifact(unit_tests);
    test_step.dependOn(&test_exe.step);
}
