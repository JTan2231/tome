const std = @import("std");
const builtin = @import("builtin");
const content = @import("content");
const Editor = @import("editor").Editor;

const usage =
    \\Usage: tome-scroll <workspace-root> <steps> <rows> <cols>
    \\
    \\Send PageDown through the editor and prepare each frame without terminal I/O.
    \\Zero steps traverses the workspace once; a positive count sends exactly N keys.
    \\Write timings, discovered file metadata, and completion as JSON lines.
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("tome-scroll: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var output: Output = .{ .allocator = allocator, .file = .{ .handle = std.posix.STDOUT_FILENO } };
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try output.file.writeAll(usage);
        return;
    }
    if (args.len != 5) {
        std.debug.print("{s}", .{usage});
        return error.ExpectedWorkspaceStepsRowsAndCols;
    }
    const steps = std.fmt.parseInt(usize, args[2], 10) catch return error.InvalidSteps;
    const rows = std.fmt.parseInt(usize, args[3], 10) catch return error.InvalidRows;
    const cols = std.fmt.parseInt(usize, args[4], 10) catch return error.InvalidCols;
    if (rows < 3) return error.InvalidRows;
    if (cols < 2) return error.InvalidCols;
    try runScroll(allocator, args[1], steps, rows, cols, &output);
}

fn runScroll(allocator: std.mem.Allocator, root: []const u8, steps: usize, rows: usize, cols: usize, sink: anytype) !void {
    var timer = try std.time.Timer.start();
    var workspace = try content.Workspace.open(allocator, root, null);
    const discovery_ns = timer.read();
    defer workspace.deinit();
    try sink.json(.{
        .type = "worker",
        .optimize = @tagName(builtin.mode),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .cpu_arch = @tagName(builtin.cpu.arch),
        .max_file_size = content.max_file_size,
        .cache_file_limit = content.cache_file_limit,
        .cache_byte_limit = content.cache_byte_limit,
        .root = workspace.root,
        .steps = steps,
        .rows = rows,
        .cols = cols,
        .discovery_ns = discovery_ns,
        .discovered_files = workspace.entries.items.len,
    });

    timer.reset();
    var editor = try Editor.initWorkspace(allocator, &workspace);
    defer editor.deinit();
    const initial_frame = try editor.renderFrame(.{ .rows = rows, .cols = cols });
    const startup_ns = timer.read();
    try sink.json(.{
        .type = "sample",
        .metric = "startup_to_frame",
        .iteration = @as(usize, 0),
        .elapsed_ns = startup_ns,
        .file_index = editor.current_file,
        .cursor_byte = editor.document.buffer.cursor,
        .rendered_bytes = initial_frame.len,
    });

    var iteration: usize = 0;
    var stop_reason: []const u8 = "step_limit";
    while (steps == 0 or iteration < steps) {
        if (steps == 0 and editor.current_file == null) {
            stop_reason = "end";
            break;
        }
        const before_file_index = editor.current_file;
        const before_cursor_byte = editor.document.buffer.cursor;
        timer.reset();
        _ = try editor.handle(.page_down);
        const frame = try editor.renderFrame(.{ .rows = rows, .cols = cols });
        const elapsed_ns = timer.read();
        // Serialization and sample storage are deliberately outside the interval.
        try sink.json(.{
            .type = "sample",
            .metric = "scroll_to_frame",
            .iteration = iteration,
            .elapsed_ns = elapsed_ns,
            .before_file_index = before_file_index,
            .before_cursor_byte = before_cursor_byte,
            .file_index = editor.current_file,
            .cursor_byte = editor.document.buffer.cursor,
            .rendered_bytes = frame.len,
        });
        iteration += 1;
        if (steps == 0) {
            const before_file = before_file_index.?;
            const after_file = editor.current_file.?;
            const after_cursor = editor.document.buffer.cursor;
            if (after_file == before_file and after_cursor == before_cursor_byte) {
                stop_reason = "end";
                break;
            }
            // Wrapping is enabled only when content lines exceed the viewport.
            // Therefore one PageDown cannot make a complete circuit, even with
            // the extra separator row when it lands across a file boundary.
            if (after_file < before_file or (after_file == before_file and after_cursor < before_cursor_byte)) {
                stop_reason = "wrapped";
                break;
            }
        }
    }
    var loaded_files: usize = 0;
    var failed_files: usize = 0;
    for (workspace.entries.items, 0..) |entry, index| {
        if (entry.line_count != null) loaded_files += 1;
        if (entry.load_error != null) failed_files += 1;
        try sink.json(.{
            .type = "file",
            .file_index = index,
            .file_name = entry.name,
            .line_count = entry.line_count,
            .error_name = if (entry.load_error) |err| @as(?[]const u8, @errorName(err)) else null,
        });
    }
    try sink.json(.{
        .type = "complete",
        .steps = iteration,
        .stop_reason = stop_reason,
        .discovered_files = workspace.entries.items.len,
        .loaded_files = loaded_files,
        .failed_files = failed_files,
    });
}

const Output = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,

    fn json(self: *Output, value: anytype) !void {
        const serialized = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(serialized);
        try self.file.writeAll(serialized);
        try self.file.writeAll("\n");
    }
};

const TestSink = struct {
    samples: usize = 0,
    first_file: ?usize = null,
    first_cursor: usize = 0,
    loaded: usize = 0,
    failed: usize = 0,
    discovered: usize = 0,
    steps: usize = 0,
    wrapped: bool = false,

    fn json(self: *TestSink, value: anytype) !void {
        if (comptime @hasField(@TypeOf(value), "metric")) {
            try std.testing.expect(value.rendered_bytes > 0);
            if (comptime @hasField(@TypeOf(value), "before_file_index")) {
                if (self.samples == 0) {
                    self.first_file = value.file_index;
                    self.first_cursor = value.cursor_byte;
                }
                self.samples += 1;
            }
        }
        if (comptime @hasField(@TypeOf(value), "stop_reason")) {
            self.loaded = value.loaded_files;
            self.failed = value.failed_files;
            self.discovered = value.discovered_files;
            self.steps = value.steps;
            self.wrapped = std.mem.eql(u8, value.stop_reason, "wrapped");
        }
    }
};

test "headless pages cross file boundaries, wrap, and leave input bytes untouched" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for ("abcdefghijkl") |name| try temp.dir.writeFile(.{ .sub_path = &.{name}, .data = "a\nb" });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var sink: TestSink = .{};
    try runScroll(allocator, root, 30, 6, 20, &sink);
    try std.testing.expectEqual(@as(usize, 30), sink.samples);
    try std.testing.expectEqual(@as(?usize, 1), sink.first_file);
    try std.testing.expectEqual(@as(usize, 2), sink.first_cursor);
    try std.testing.expectEqual(@as(usize, 12), sink.loaded);
    try std.testing.expectEqual(@as(usize, 0), sink.failed);
    for ("abcdefghijkl") |name| {
        const bytes = try temp.dir.readFileAlloc(allocator, &.{name}, 16);
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings("a\nb", bytes);
    }

    var full: TestSink = .{};
    try runScroll(allocator, root, 0, 6, 20, &full);
    try std.testing.expect(full.wrapped);
    try std.testing.expectEqual(@as(usize, 12), full.loaded);
    try std.testing.expect(full.steps > 0 and full.steps < 30);
}

test "full traversal terminates for empty, short, single-file, and failed workspaces" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var empty: TestSink = .{};
    try runScroll(allocator, root, 0, 6, 20, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.steps);
    try std.testing.expectEqual(@as(usize, 0), empty.discovered);
    try std.testing.expect(!empty.wrapped);

    try temp.dir.writeFile(.{ .sub_path = "b", .data = "one" });
    var short: TestSink = .{};
    try runScroll(allocator, root, 0, 6, 20, &short);
    try std.testing.expectEqual(@as(usize, 1), short.steps);
    try std.testing.expectEqual(@as(usize, 1), short.loaded);
    try std.testing.expect(!short.wrapped);

    try temp.dir.writeFile(.{ .sub_path = "b", .data = "0\n1\n2\n3\n4" });
    var single: TestSink = .{};
    try runScroll(allocator, root, 0, 6, 20, &single);
    try std.testing.expectEqual(@as(usize, 2), single.steps);
    try std.testing.expect(single.wrapped);

    const huge = try temp.dir.createFile("a", .{});
    try huge.setEndPos(content.max_file_size + 1);
    huge.close();
    var skipped: TestSink = .{};
    try runScroll(allocator, root, 0, 6, 20, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.loaded);
    try std.testing.expectEqual(@as(usize, 1), skipped.failed);
    try std.testing.expectEqual(@as(usize, 2), skipped.discovered);
    try temp.dir.deleteFile("b");
    var failed: TestSink = .{};
    try runScroll(allocator, root, 0, 6, 20, &failed);
    try std.testing.expectEqual(@as(usize, 0), failed.steps);
    try std.testing.expectEqual(@as(usize, 0), failed.loaded);
    try std.testing.expectEqual(@as(usize, 1), failed.failed);
}
