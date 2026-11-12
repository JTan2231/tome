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
    const install_tome = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_tome.step);
    b.step("install-tome", "Install the tome executable").dependOn(&install_tome.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run tome (optionally pass a file or directory after --)").dependOn(&run.step);

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

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("measurement/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content },
            .{ .name = "measurement", .module = measurement },
        },
    });
    const benchmark_exe = b.addExecutable(.{
        .name = "tome-bench",
        .root_module = benchmark_module,
    });
    const benchmark = b.addRunArtifact(benchmark_exe);
    b.step("benchmark", "Run generated file readiness scenarios").dependOn(&benchmark.step);

    const editor = b.createModule(.{
        .root_source_file = b.path("src/editor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "content", .module = content }},
    });
    const scroll_module = b.createModule(.{
        .root_source_file = b.path("measurement/scroll.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content },
            .{ .name = "editor", .module = editor },
        },
    });
    const scroll_exe = b.addExecutable(.{ .name = "tome-scroll", .root_module = scroll_module });
    const scroll_driver_module = b.createModule(.{
        .root_source_file = b.path("measurement/scroll_driver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "scroll_worker", .module = scroll_module }},
    });
    const scroll_driver_exe = b.addExecutable(.{ .name = "tome-benchmark-scroll", .root_module = scroll_driver_module });
    const scroll = b.addRunArtifact(scroll_driver_exe);
    scroll.addArg("--binary");
    scroll.addArtifactArg(scroll_exe);
    b.step("benchmark-scroll", "Measure headless scrolling through a repository").dependOn(&scroll.step);

    const search_module = b.createModule(.{
        .root_source_file = b.path("measurement/search.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content },
            .{ .name = "editor", .module = editor },
        },
    });
    const search_exe = b.addExecutable(.{ .name = "tome-search", .root_module = search_module });
    const search = b.addRunArtifact(search_exe);
    b.step("benchmark-search", "Measure generated search scenarios through result frames").dependOn(&search.step);

    for ([_]*std.Build.Step.Run{ benchmark, scroll, search }) |suite| {
        suite.setEnvironmentVariable("TOME_MEASUREMENT_ROOT", b.pathFromRoot("."));
        if (b.args) |args| suite.addArgs(args);
    }

    const test_step = b.step("test", "Run content, editor, and measurement correctness tests");
    for ([_]*std.Build.Module{ content, app, measurement }) |module| {
        const unit_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    const benchmark_tests = b.step("test-benchmark", "Test readiness fixtures and benchmark validation");
    const scroll_tests = b.step("test-scroll", "Test repository scrolling measurements");
    const search_tests = b.step("test-search", "Test search scenarios and measurement validation");
    for ([_]struct { *std.Build.Step, *std.Build.Module }{
        .{ benchmark_tests, benchmark_module },
        .{ scroll_tests, scroll_module },
        .{ scroll_tests, scroll_driver_module },
        .{ search_tests, search_module },
    }) |suite| {
        const unit_tests = b.addTest(.{ .root_module = suite[1] });
        suite[0].dependOn(&b.addRunArtifact(unit_tests).step);
        test_step.dependOn(suite[0]);
    }
}
