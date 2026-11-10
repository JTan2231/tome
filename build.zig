const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const content = b.addModule("content", .{
        .root_source_file = b.path("src/content/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "content", .module = content }},
    });
    const exe = b.addExecutable(.{
        .name = "tome",
        .root_module = app,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run tome (optionally pass a starting file after --)").dependOn(&run.step);

    const measurement = b.addModule("measurement", .{
        .root_source_file = b.path("measurement/file_ready.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "content", .module = content }},
    });
    const measure_exe = b.addExecutable(.{
        .name = "tome-measure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("measurement/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "content", .module = content },
                .{ .name = "measurement", .module = measurement },
            },
        }),
    });
    b.installArtifact(measure_exe);
    const measure = b.addRunArtifact(measure_exe);
    if (b.args) |args| measure.addArgs(args);
    b.step("measure", "Measure one file request without rendering").dependOn(&measure.step);

    const test_step = b.step("test", "Run content, editor, and measurement correctness tests");
    for ([_]*std.Build.Module{ content, app, measurement }) |module| {
        const unit_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
