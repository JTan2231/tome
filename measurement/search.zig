//! Search submission through the first result frame, without terminal I/O.
const std = @import("std");
const builtin = @import("builtin");
const content = @import("content");
const Editor = @import("editor").Editor;
const common = @import("common.zig");
const fixtures = @import("search_fixtures.zig");
const Config = fixtures.Config;

const usage =
    \\Usage: zig build benchmark-search -- [options]
    \\
    \\  --repetitions N    Samples per scenario (default 30)
    \\  --scenario PREFIX  Select matching scenarios (repeatable)
    \\  --list             Print selected scenarios without running them
    \\  --output PATH      Write to a new JSONL file
    \\  -h, --help         Print this help
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("benchmark-search: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    const options = common.ScenarioOptions.parse(allocator, args[1..]) catch |err| {
        std.debug.print("{s}benchmark-search: {s}\n", .{ usage, @errorName(err) });
        std.process.exit(2);
    } orelse return common.print("{s}", .{usage});
    var matched = false;
    for (fixtures.scenarios) |case| {
        if (!options.selects(case.name)) continue;
        matched = true;
        if (options.list) try common.print("{s}\n", .{case.name});
    }
    if (!matched) return error.NoMatchingScenarios;
    if (options.list) return;

    common.installInterruptHandler();
    const path = try common.resultPath(allocator, options.output_path, "search-", null);
    const file = try common.createResult(path);
    defer file.close();
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    const output = &writer.interface;
    runSuite(allocator, options, path, output) catch |err| {
        common.finish(output, err) catch {};
        return err;
    };
    try common.finish(output, null);
}

fn runSuite(allocator: std.mem.Allocator, options: common.ScenarioOptions, path: []const u8, output: *std.Io.Writer) !void {
    try common.emitRun(output, try common.runMetadata(allocator), .{
        .suite = "search",
        .suite_version = 1,
        .generator_version = 1,
        .repetitions = options.repetitions,
        .rows = fixtures.rows,
        .cols = fixtures.cols,
        .warmups = "none discarded; new workspace and editor for each sample",
        .boundary = "Enter submission through search completion and first result frame",
        .scheduling = "headless tick servicing with Thread.yield; no terminal poll delay",
        .distance = "bytes before match start in forward order, excluding origin byte; positional, not bytes actually read",
        .excluded = "fixture generation, discovery, initial file loading/frame, preload, query entry, JSON reporting, terminal I/O/display",
        .os_cache = "uncontrolled; fixtures just generated",
        .fixture_storage = "system temporary directory; deleted after each scenario",
    });
    try common.print("Results: {s}\n", .{path});
    try common.print("Scenario                        n   Median ms      p95 ms      Min ms      Max ms\n", .{});
    if (content.max_file_size != fixtures.max_file_size) return error.UnexpectedFileSizeLimit;
    for (fixtures.scenarios) |case| {
        if (!options.selects(case.name)) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const scoped = arena.allocator();
        try common.checkInterrupted();
        var temporary = try common.TempDir.init(scoped, "tome-search-");
        defer temporary.deinit();
        var directory = try std.fs.openDirAbsolute(temporary.path, .{});
        defer directory.close();
        try directory.makeDir("workspace");
        var workspace = try directory.openDir("workspace", .{});
        defer workspace.close();
        const root = try std.fs.path.join(scoped, &.{ temporary.path, "workspace" });
        const metadata = try fixtures.generate(scoped, workspace, case, options.repetitions);
        const summary = try runScenario(scoped, root, metadata, output);
        try common.print("{s:<28} {d:>4} {d:>11.3} {d:>11.3} {d:>11.3} {d:>11.3}\n", .{
            summary.scenario,
            summary.sample_count,
            summary.median_ns / std.time.ns_per_ms,
            milliseconds(summary.p95_ns),
            milliseconds(summary.min_ns),
            milliseconds(summary.max_ns),
        });
    }
}

const Summary = struct {
    type: []const u8 = "summary",
    scenario: []const u8,
    metric: []const u8 = "search_to_frame",
    sample_count: usize,
    median_ns: f64,
    p95_ns: u64,
    min_ns: u64,
    max_ns: u64,
    outcome: []const u8,
    search_distance_bytes: ?usize,
    file_boundaries_before_match: ?usize,
    target_resident_before: ?bool,
};

fn runScenario(allocator: std.mem.Allocator, root: []const u8, metadata: fixtures.Metadata, output: *std.Io.Writer) !Summary {
    const config = metadata.config;
    try common.emit(output, metadata);
    try common.emit(output, .{
        .type = "worker",
        .scenario = metadata.scenario,
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

    const timings = try allocator.alloc(u64, config.repetitions);
    defer allocator.free(timings);
    var invalid = false;
    for (timings, 0..) |*elapsed_ns, iteration| {
        try common.checkInterrupted();
        const sample = try runSample(std.heap.page_allocator, root, config, iteration);
        const expected = .{
            .iteration = iteration,
            .origin_file = config.origin_file,
            .origin_offset = config.origin_offset,
            .file_index = config.target_file orelse config.origin_file,
            .cursor_byte = config.target_offset orelse config.origin_offset,
            .discovered_files = metadata.file_count,
            .target_resident_before = metadata.expected_target_resident,
            .target_visible_before = metadata.expected_target_visible,
        };
        var buffer: [std.meta.fields(@TypeOf(expected)).len + 2][]const u8 = undefined;
        var errors = std.ArrayList([]const u8).initBuffer(&buffer);
        inline for (std.meta.fields(@TypeOf(expected))) |field| {
            const wanted = @field(expected, field.name);
            const actual = @field(sample, field.name);
            if (wanted != actual) {
                errors.appendAssumeCapacity(try std.fmt.allocPrint(allocator, field.name ++ ": expected {any}, got {any}", .{ wanted, actual }));
            }
        }
        if (sample.rendered_bytes == 0) errors.appendAssumeCapacity("invalid rendered_bytes");
        if (sample.resident_files_before == 0) errors.appendAssumeCapacity("invalid resident_files_before");
        try common.emit(output, SampleReport{
            .scenario = metadata.scenario,
            .sample = sample,
            .validation_errors = errors.items,
        });
        invalid = invalid or errors.items.len != 0;
        elapsed_ns.* = sample.elapsed_ns;
    }
    try common.emit(output, .{ .type = "complete", .scenario = metadata.scenario, .samples = timings.len });
    if (invalid) return error.InvalidSearchSample;
    std.mem.sortUnstable(u64, timings, {}, std.sort.asc(u64));
    const summary: Summary = .{
        .scenario = metadata.scenario,
        .sample_count = timings.len,
        .median_ns = common.median(timings),
        .p95_ns = common.p95(timings),
        .min_ns = timings[0],
        .max_ns = timings[timings.len - 1],
        .outcome = if (config.target_file != null) "match" else "not_found",
        .search_distance_bytes = metadata.search_distance_bytes,
        .file_boundaries_before_match = metadata.file_boundaries_before_match,
        .target_resident_before = metadata.expected_target_resident,
    };
    try common.emit(output, summary);
    return summary;
}

fn milliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const Sample = struct {
    type: []const u8 = "sample",
    metric: []const u8 = "search_to_frame",
    iteration: usize,
    elapsed_ns: u64,
    outcome: []const u8,
    message: []const u8,
    origin_file: usize,
    origin_offset: usize,
    file_index: ?usize,
    cursor_byte: usize,
    discovered_files: usize,
    resident_files_before: usize,
    target_resident_before: ?bool,
    target_visible_before: ?bool,
    rendered_bytes: usize,
};

const SampleReport = struct {
    scenario: []const u8,
    sample: Sample,
    validation_errors: []const []const u8,

    pub fn jsonStringify(self: SampleReport, json: *std.json.Stringify) !void {
        try json.beginObject();
        try common.jsonFields(json, self.sample);
        try common.jsonFields(json, .{
            .scenario = self.scenario,
            .valid = self.validation_errors.len == 0,
            .validation_errors = self.validation_errors,
        });
        try json.endObject();
    }
};

fn runSample(allocator: std.mem.Allocator, root: []const u8, config: Config, iteration: usize) !Sample {
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
        try common.checkInterrupted();
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
        try common.checkInterrupted();
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
    return .{
        .iteration = iteration,
        .elapsed_ns = elapsed_ns,
        .outcome = @as([]const u8, if (config.target_file != null) "match" else "not_found"),
        .message = config.expected_message,
        .origin_file = config.origin_file,
        .origin_offset = config.origin_offset,
        .file_index = editor.current_file,
        .cursor_byte = editor.document.buffer.cursor,
        .discovered_files = workspace.entries.items.len,
        .resident_files_before = resident_files_before,
        .target_resident_before = target_resident_before,
        .target_visible_before = target_visible_before,
        .rendered_bytes = frame.len,
    };
}

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
    for (0..config.repetitions) |iteration| {
        const next = try runSample(allocator, root, config, iteration);
        try std.testing.expectEqual(iteration, next.iteration);
        try std.testing.expectEqual(@as(?bool, true), next.target_resident_before);
        try std.testing.expectEqual(@as(?bool, true), next.target_visible_before);
    }
    config.target_offset = 10;
    try std.testing.expectError(error.UnexpectedSearchDestination, runSample(allocator, root, config, 0));
    config.origin_offset = 9;
    config.target_offset = 0;
    config.expected_message = "Search wrapped";
    const wrapped = try runSample(allocator, root, config, 0);
    try std.testing.expectEqual(@as(usize, 0), wrapped.cursor_byte);
    config.query = "missing";
    config.target_file = null;
    config.target_offset = null;
    config.expected_message = "Pattern not found";
    const missing = try runSample(allocator, root, config, 0);
    try std.testing.expectEqual(@as(usize, 9), missing.cursor_byte);
    try std.testing.expectEqual(@as(?bool, null), missing.target_resident_before);
    config.target_file = 0;
    config.target_offset = 0;
    config.expected_message = "Match";
    try std.testing.expectError(error.UnexpectedSearchMessage, runSample(allocator, root, config, 0));
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
    for ([_]bool{ false, true }) |preload| {
        config.preload_target = preload;
        for (0..config.repetitions) |iteration| {
            const sample = try runSample(allocator, root, config, iteration);
            try std.testing.expectEqual(@as(?bool, preload), sample.target_resident_before);
            try std.testing.expectEqual(@as(?bool, false), sample.target_visible_before);
        }
    }
    const actual_origin = try temp.dir.readFileAlloc(allocator, "a", 1024);
    defer allocator.free(actual_origin);
    const actual_target = try temp.dir.readFileAlloc(allocator, "b", 1024);
    defer allocator.free(actual_target);
    try std.testing.expectEqualStrings(origin, actual_origin);
    try std.testing.expectEqualStrings(target, actual_target);
}

test "search samples reject a match with incomplete coverage" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "origin\nx\nx\nx\nx\nx\nx\nx\n" });
    const oversized = try temp.dir.createFile("b", .{});
    defer oversized.close();
    try oversized.setEndPos(content.max_file_size + 1);
    try temp.dir.writeFile(.{ .sub_path = "c", .data = "x\nneedle\nx\nx\nx\nx\nx\nx\n" });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try std.testing.expectError(error.UnexpectedSearchMessage, runSample(allocator, root, .{
        .repetitions = 1,
        .rows = 6,
        .cols = 40,
        .target_file = 2,
        .target_offset = 2,
        .query = "needle",
        .expected_message = "Match",
    }, 0));
    try std.testing.expectEqual(content.max_file_size + 1, try oversized.getEndPos());
}

test "search reports validated samples and suppresses summaries for invalid residency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    var metadata = try fixtures.generate(allocator, temp.dir, .{
        .name = "test/unloaded",
        .files = &.{ .{ .byte_count = 8192 }, .{ .byte_count = 8192, .needle_offset = 65 } },
        .target_file = 1,
    }, 2);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const summary = try runScenario(allocator, root, metadata, &output.writer);
    try std.testing.expectEqual(@as(usize, 2), summary.sample_count);
    try std.testing.expect(summary.median_ns >= @as(f64, @floatFromInt(summary.min_ns)));
    try std.testing.expect(summary.median_ns <= @as(f64, @floatFromInt(summary.p95_ns)));
    try std.testing.expect(summary.p95_ns <= summary.max_ns);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "\"valid\":true"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "\"target_resident_before\":false,\"target_visible_before\":false"));

    metadata.expected_target_resident = true;
    output.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidSearchSample, runScenario(allocator, root, metadata, &output.writer));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "\"valid\":false"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"type\":\"summary\"") == null);
}
