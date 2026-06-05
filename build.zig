const std = @import("std");

const ctxline_version = @import("src/version.zig").version;

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
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ctxline");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests and executable smoke gates");

    const unit_tests = b.addTest(.{
        .name = "ctxline-test",
        .root_module = library,
    });
    const unit_test_run = b.addRunArtifact(unit_tests);
    test_step.dependOn(&unit_test_run.step);

    const help_step = b.addRunArtifact(exe);
    help_step.addArg("--help");
    help_step.expectStdOutMatch("Usage:");
    help_step.expectStdErrEqual("");
    test_step.dependOn(&help_step.step);

    const version_step = b.addRunArtifact(exe);
    version_step.addArg("--version");
    version_step.expectStdOutEqual(b.fmt("ctxline {s}\n", .{ctxline_version}));
    version_step.expectStdErrEqual("");
    test_step.dependOn(&version_step.step);

    const malformed_step = b.addRunArtifact(exe);
    malformed_step.setStdIn(.{ .bytes = "not json" });
    malformed_step.expectStdOutEqual("ctxline │ no status json\n");
    malformed_step.expectStdErrEqual("");
    test_step.dependOn(&malformed_step.step);

    const native_step = b.addRunArtifact(exe);
    native_step.setStdIn(.{ .bytes = "{\"model\":{\"id\":\"deepseek-v4-pro[1m]\"},\"context_window\":{\"used_percentage\":38.2,\"total_input_tokens\":380000,\"total_output_tokens\":2000,\"context_window_size\":1000000}}" });
    native_step.expectStdOutMatch("deepseek-v4-pro[1m] │ ctx 38.2% │ 382K/1.0M");
    native_step.expectStdErrEqual("");
    test_step.dependOn(&native_step.step);

    const fallback_step = b.addRunArtifact(exe);
    fallback_step.setStdIn(.{ .bytes = "{\"model\":{\"id\":\"deepseek-v4-flash\"},\"context_window\":{\"used_percentage\":125.0,\"context_window_size\":128000}}" });
    fallback_step.expectStdOutMatch("deepseek-v4-flash │ ctx 0% │ 0/128K");
    fallback_step.expectStdErrEqual("");
    test_step.dependOn(&fallback_step.step);
}
