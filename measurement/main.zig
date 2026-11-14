const std = @import("std");
const Workspace = @import("content").Workspace;
const file_ready = @import("measurement");

const usage =
    \\Usage: tome-measure <file>
    \\
    \\Measure one file request through Tome's content-loading boundary.
    \\Write one JSON sample to stdout, without rendering or modifying the file.
    \\Workspace discovery and result formatting are outside the timed interval.
    \\
;

pub fn main() void {
    const failed = run() catch |err| {
        std.debug.print("tome-measure: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (failed) std.process.exit(1);
}

fn run() !bool {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const stdout = std.fs.File.stdout();
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try stdout.writeAll(usage);
        return false;
    }
    if (args.len != 2) {
        std.debug.print("{s}", .{usage});
        return error.ExpectedOneFile;
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const path = try std.fs.path.resolve(allocator, &.{ cwd, args[1] });
    defer allocator.free(path);
    var workspace = try Workspace.open(allocator, std.fs.path.dirname(path) orelse cwd, path);
    defer workspace.deinit();

    const sample = try file_ready.measure(&workspace, workspace.initial_index);
    const error_name: ?[]const u8 = switch (sample.outcome) {
        .ready => null,
        .failed => |err| @errorName(err),
    };
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .metric = "file_request_to_ready",
        .file_index = sample.index,
        .elapsed_ns = sample.elapsed_ns,
        .cache = @tagName(sample.cache),
        .byte_count = sample.byte_count,
        .is_new = sample.is_new,
        .outcome = @tagName(sample.outcome),
        .error_name = error_name,
    }, .{});
    defer allocator.free(json);
    try stdout.writeAll(json);
    try stdout.writeAll("\n");
    return sample.outcome == .failed;
}
