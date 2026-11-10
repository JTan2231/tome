//! Search submission through the first result frame, without terminal I/O.
const std = @import("std");
const builtin = @import("builtin");
const content = @import("content");
const Editor = @import("editor").Editor;

const usage =
    \\Usage: tome-search <workspace-root> <config.json>
    \\
    \\Run a literal search in a fresh editor for each repetition. Configuration
    \\specifies the origin, expected destination, viewport, and target preload.
    \\Write build metadata, validated timings, and completion as JSON lines.
    \\
;

const Config = struct {
    repetitions: usize,
    rows: usize = 40,
    cols: usize = 120,
    origin_file: usize = 0,
    origin_offset: usize = 0,
    target_file: ?usize = null,
    target_offset: ?usize = null,
    preload_target: bool = false,
    query: []const u8,
    expected_message: []const u8,

    fn validate(self: Config) !void {
        if (self.repetitions == 0) return error.InvalidRepetitions;
        if (self.rows < 3 or self.cols < 2) return error.InvalidViewport;
        if ((self.target_file == null) != (self.target_offset == null)) return error.InvalidTarget;
        if (self.preload_target and self.target_file == null) return error.InvalidTarget;
        if (self.query.len == 0 or self.query.len > content.search.max_query_size) return error.InvalidQuery;
        // Generated scenarios use one printable ASCII literal, entered through
        // exactly the same key handling as a user typing it into the prompt.
        for (self.query) |byte| if (byte < 32 or byte > 126) return error.InvalidQuery;
        if (self.target_file == null) {
            if (!std.mem.eql(u8, self.expected_message, "Pattern not found")) return error.InvalidExpectedMessage;
        } else if (!std.mem.eql(u8, self.expected_message, "Match") and
            !std.mem.eql(u8, self.expected_message, "Search wrapped")) return error.InvalidExpectedMessage;
    }
};

pub fn main() void {
    run() catch |err| {
        std.debug.print("tome-search: {s}\n", .{@errorName(err)});
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
    if (args.len != 3) {
        std.debug.print("{s}", .{usage});
        return error.ExpectedWorkspaceAndConfig;
    }
    const bytes = try std.fs.cwd().readFileAlloc(allocator, args[2], 64 * 1024);
    defer allocator.free(bytes);
    const config = try std.json.parseFromSlice(Config, allocator, bytes, .{});
    defer config.deinit();
    try runSearch(allocator, args[1], config.value, &output);
}

fn runSearch(allocator: std.mem.Allocator, root: []const u8, config: Config, sink: anytype) !void {
    try config.validate();
    try sink.json(.{
        .type = "worker",
        .optimize = @tagName(builtin.mode),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .cpu_arch = @tagName(builtin.cpu.arch),
        .max_file_size = content.max_file_size,
        .cache_file_limit = content.cache_file_limit,
        .cache_byte_limit = content.cache_byte_limit,
        .search_chunk_size = content.search.chunk_size,
        .repetitions = config.repetitions,
        .rows = config.rows,
        .cols = config.cols,
        .polling = "dense editor ticks with thread yield; no terminal poll wait",
        .timeout_ns = 30 * std.time.ns_per_s,
    });
    for (0..config.repetitions) |iteration| {
        try runSample(allocator, root, config, iteration, sink);
    }
    try sink.json(.{ .type = "complete", .samples = config.repetitions });
}

fn runSample(allocator: std.mem.Allocator, root: []const u8, config: Config, iteration: usize, sink: anytype) !void {
    // Discovery, loading the origin, positioning, and prompt entry are setup.
    // Every sample starts with a fresh application workspace, not a cold OS cache.
    var workspace = try content.Workspace.open(allocator, root, null);
    defer workspace.deinit();
    if (config.origin_file >= workspace.entries.items.len) return error.InvalidOriginFile;
    if (config.target_file) |index| if (index >= workspace.entries.items.len) return error.InvalidTargetFile;
    workspace.initial_index = config.origin_file;
    var editor = try Editor.initWorkspace(allocator, &workspace);
    defer editor.deinit();
    if (editor.current_file != config.origin_file) return error.OriginUnavailable;
    if (config.origin_offset > editor.document.buffer.bytes.items.len) return error.InvalidOriginOffset;
    editor.document.buffer.setCursor(config.origin_offset);
    if (editor.document.buffer.cursor != config.origin_offset) return error.InvalidOriginOffset;
    editor.stream.?.async_load = true;

    // Finish any ordinary initial-viewport requests before measuring. This
    // avoids mixing setup I/O with search and records the actual resulting cache.
    var setup_timer = try std.time.Timer.start();
    var initial_frame = try editor.renderFrame(.{ .rows = config.rows, .cols = config.cols });
    while (workspace.hasPendingRequest()) {
        if (setup_timer.read() > 30 * std.time.ns_per_s) return error.SetupTimeout;
        _ = try editor.handle(.tick);
        if (!workspace.hasPendingRequest()) initial_frame = try editor.renderFrame(.{ .rows = config.rows, .cols = config.cols });
        std.Thread.yield() catch {};
    }
    // Scenario fixtures contain one occurrence of the literal, so seeing it in
    // this frame identifies the destination. This flag is not a visibility
    // oracle for arbitrary inputs containing multiple occurrences.
    const target_visible_before: ?bool = if (config.target_file) |target|
        target == editor.current_file and std.mem.indexOf(u8, initial_frame, config.query) != null
    else
        null;
    if (config.preload_target) _ = try workspace.ensure(config.target_file.?);
    const target_resident_before: ?bool = if (config.target_file) |index|
        workspace.entries.items[index].document != null
    else
        null;
    const resident_files_before = workspace.resident.items.len;

    _ = try editor.handle(.{ .byte = '/' });
    for (config.query) |byte| _ = try editor.handle(.{ .byte = byte });
    if (!std.mem.eql(u8, editor.search_text.items, config.query)) return error.QueryEntryFailed;

    var timer = try std.time.Timer.start();
    _ = try editor.handle(.{ .byte = '\r' });
    while (editor.search_job != null or editor.search_next != null) {
        if (timer.read() > 30 * std.time.ns_per_s) return error.SearchTimeout;
        _ = try editor.handle(.tick);
        // Service the real mailbox as soon as the worker requests it. Terminal
        // read timeouts and intermediate frames are outside this boundary.
        if (editor.search_job != null or editor.search_next != null) std.Thread.yield() catch {};
    }
    const frame = try editor.renderFrame(.{ .rows = config.rows, .cols = config.cols });
    const elapsed_ns = timer.read();

    // Validation and output happen after the timer stops. Skips, search failures,
    // wrong matches, and unexpected wrapping must never become fast successes.
    const message = editor.message[0..editor.message_len];
    if (!std.mem.eql(u8, message, config.expected_message)) return error.UnexpectedSearchMessage;
    if (frame.len == 0) return error.EmptyResultFrame;
    if (config.target_file) |target| {
        if (editor.current_file != target or editor.document.buffer.cursor != config.target_offset.?) return error.UnexpectedSearchDestination;
        const offset = config.target_offset.?;
        const text = editor.document.buffer.bytes.items;
        if (offset > text.len or config.query.len > text.len - offset or
            !std.mem.eql(u8, text[offset..][0..config.query.len], config.query)) return error.DestinationDoesNotMatch;
        // A long-line match can begin in the rightmost screen column, so only
        // its first character, rather than the entire literal, may be rendered.
    } else if (editor.current_file != config.origin_file or editor.document.buffer.cursor != config.origin_offset) {
        return error.MissMovedCursor;
    }
    try sink.json(.{
        .type = "sample",
        .metric = "search_to_frame",
        .iteration = iteration,
        .elapsed_ns = elapsed_ns,
        .outcome = @as([]const u8, if (config.target_file != null) "match" else "not_found"),
        .message = message,
        .origin_file = config.origin_file,
        .origin_offset = config.origin_offset,
        .file_index = editor.current_file,
        .cursor_byte = editor.document.buffer.cursor,
        .discovered_files = workspace.entries.items.len,
        .resident_files_before = resident_files_before,
        .target_resident_before = target_resident_before,
        .target_visible_before = target_visible_before,
        .rendered_bytes = frame.len,
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
    complete: bool = false,
    resident: ?bool = null,
    visible: ?bool = null,

    fn json(self: *TestSink, value: anytype) !void {
        if (comptime @hasField(@TypeOf(value), "metric")) {
            try std.testing.expect(value.rendered_bytes > 0);
            try std.testing.expectEqual(self.samples, value.iteration);
            self.samples += 1;
            self.resident = value.target_resident_before;
            self.visible = value.target_visible_before;
        }
        if (comptime @hasField(@TypeOf(value), "samples")) {
            try std.testing.expectEqual(self.samples, value.samples);
            self.complete = true;
        }
    }
};

test "search samples validate next match, wrap, and full-pass miss" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "needle\nx\nneedle\nx\nx\nx\nx\nx\nx\n" });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var config: Config = .{
        .repetitions = 2,
        .rows = 6,
        .cols = 40,
        .query = "needle",
        .target_file = 0,
        .target_offset = 9,
        .expected_message = "Match",
    };
    var next: TestSink = .{};
    try runSearch(allocator, root, config, &next);
    try std.testing.expect(next.complete);
    try std.testing.expectEqual(@as(?bool, true), next.resident);
    try std.testing.expectEqual(@as(?bool, true), next.visible);
    config.origin_offset = 9;
    config.target_offset = 0;
    config.expected_message = "Search wrapped";
    var wrapped: TestSink = .{};
    try runSearch(allocator, root, config, &wrapped);
    try std.testing.expect(wrapped.complete);
    config.query = "missing";
    config.target_file = null;
    config.target_offset = null;
    config.expected_message = "Pattern not found";
    var missing: TestSink = .{};
    try runSearch(allocator, root, config, &missing);
    try std.testing.expect(missing.complete);
    try std.testing.expectEqual(@as(?bool, null), missing.resident);
    config.target_file = 0;
    config.target_offset = 0;
    config.expected_message = "Match";
    var invalid: TestSink = .{};
    try std.testing.expectError(error.UnexpectedSearchMessage, runSearch(allocator, root, config, &invalid));
    try std.testing.expectEqual(@as(usize, 0), invalid.samples);
}

test "fresh repetitions preserve target residency and input bytes" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const origin = "origin\nx\nx\nx\nx\nx\nx\nx\nx\nx\n";
    const target = "x\nneedle\nx\nx\nx\nx\nx\nx\nx\nx\n";
    try temp.dir.writeFile(.{ .sub_path = "a", .data = origin });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = target });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var config: Config = .{
        .repetitions = 3,
        .rows = 6,
        .cols = 40,
        .query = "needle",
        .target_file = 1,
        .target_offset = 2,
        .expected_message = "Match",
    };
    var unloaded: TestSink = .{};
    try runSearch(allocator, root, config, &unloaded);
    try std.testing.expectEqual(@as(?bool, false), unloaded.resident);
    try std.testing.expectEqual(@as(?bool, false), unloaded.visible);
    config.preload_target = true;
    var resident: TestSink = .{};
    try runSearch(allocator, root, config, &resident);
    try std.testing.expectEqual(@as(?bool, true), resident.resident);
    try std.testing.expectEqual(@as(?bool, false), resident.visible);
    const actual_origin = try temp.dir.readFileAlloc(allocator, "a", 1024);
    defer allocator.free(actual_origin);
    const actual_target = try temp.dir.readFileAlloc(allocator, "b", 1024);
    defer allocator.free(actual_target);
    try std.testing.expectEqualStrings(origin, actual_origin);
    try std.testing.expectEqualStrings(target, actual_target);
}
