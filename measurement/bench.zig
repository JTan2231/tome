const std = @import("std");
const builtin = @import("builtin");
const content = @import("content");
const Workspace = content.Workspace;
const file_ready = @import("measurement");
const common = @import("common.zig");
const fixtures = @import("fixtures.zig");

const Mode = enum { fresh, repeat, pressure };
const Role = enum { sample, prime, pressure };
const Cache = file_ready.Cache;
const Record = struct {
    iteration: usize,
    role: Role,
    sample: file_ready.Sample,
    line_count: ?usize,
};

const mib = 1024 * 1024;
const suite_version = 1;
const target_name = "file-000.txt";

const Scenario = struct {
    name: []const u8,
    recipe: fixtures.Recipe,
    missing: bool = false,
    expected_error: ?anyerror = null,
    pressure: ?struct { file_count: usize, cache: Cache } = null,

    fn patterns(scenario: Scenario) []const Mode {
        return if (scenario.pressure == null) &.{ .fresh, .repeat } else &.{.pressure};
    }
};

const scenarios = [_]Scenario{
    .{ .name = "size/64KiB", .recipe = .{ .byte_count = 64 * 1024 } },
    .{ .name = "size/1MiB", .recipe = .{ .byte_count = mib } },
    .{ .name = "size/8MiB", .recipe = .{ .byte_count = 8 * mib } },
    .{ .name = "size/32MiB", .recipe = .{ .byte_count = 32 * mib } },
    .{ .name = "size/64MiB", .recipe = .{ .byte_count = 64 * mib } },
    .{ .name = "shape/one-line", .recipe = .{ .byte_count = 8 * mib, .line_bytes = null, .final_newline = false } },
    .{ .name = "shape/4KiB-lines", .recipe = .{ .byte_count = 8 * mib, .line_bytes = 4096 } },
    .{ .name = "shape/one-byte-lines", .recipe = .{ .byte_count = 8 * mib, .line_bytes = 1 } },
    .{ .name = "shape/empty-lines", .recipe = .{ .byte_count = 8 * mib, .line_bytes = 0 } },
    .{ .name = "outlier/beginning", .recipe = .{ .byte_count = 8 * mib, .outlier_position = .beginning } },
    .{ .name = "outlier/middle", .recipe = .{ .byte_count = 8 * mib, .outlier_position = .middle } },
    .{ .name = "outlier/end", .recipe = .{ .byte_count = 8 * mib, .outlier_position = .end } },
    .{ .name = "variant/crlf", .recipe = .{ .byte_count = 8 * mib, .newline = .crlf } },
    .{ .name = "variant/no-final-newline", .recipe = .{ .byte_count = 8 * mib, .final_newline = false } },
    .{ .name = "variant/utf8", .recipe = .{ .byte_count = 8 * mib, .content = .utf8 } },
    .{ .name = "boundary/empty", .recipe = .{ .byte_count = 0 } },
    .{ .name = "boundary/missing", .recipe = .{ .byte_count = 0 }, .missing = true },
    .{ .name = "boundary/64MiB-minus-one", .recipe = .{ .byte_count = 64 * mib - 1 } },
    .{ .name = "boundary/64MiB-plus-one", .recipe = .{ .byte_count = 64 * mib + 1 }, .expected_error = error.FileTooBig },
    .{ .name = "cache/files-7", .recipe = .{ .byte_count = 4096 }, .pressure = .{ .file_count = 7, .cache = .hit } },
    .{ .name = "cache/files-8", .recipe = .{ .byte_count = 4096 }, .pressure = .{ .file_count = 8, .cache = .hit } },
    .{ .name = "cache/files-9", .recipe = .{ .byte_count = 4096 }, .pressure = .{ .file_count = 9, .cache = .miss } },
    .{ .name = "cache/bytes-below", .recipe = .{ .byte_count = 4 * mib - 1 }, .pressure = .{ .file_count = 2, .cache = .hit } },
    .{ .name = "cache/bytes-at", .recipe = .{ .byte_count = 4 * mib }, .pressure = .{ .file_count = 2, .cache = .hit } },
    .{ .name = "cache/bytes-above", .recipe = .{ .byte_count = 4 * mib + 1 }, .pressure = .{ .file_count = 2, .cache = .miss } },
};

const usage =
    \\Usage: zig build benchmark -- [options]
    \\
    \\  --repetitions N    Target requests per pattern (default 30)
    \\  --scenario PREFIX  Select scenario names by prefix (repeatable)
    \\  --list             List selected scenarios and patterns
    \\  --output PATH      Write a new JSONL report (default measurement/results)
    \\  -h, --help         Show this help
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("tome-bench: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    const options = common.ScenarioOptions.parse(allocator, args[1..]) catch |err| {
        std.debug.print("{s}tome-bench: {s}\n", .{ usage, @errorName(err) });
        std.process.exit(2);
    } orelse return common.print("{s}", .{usage});

    var selected: std.ArrayList(Scenario) = .empty;
    for (scenarios) |scenario| {
        if (options.selects(scenario.name)) try selected.append(allocator, scenario);
    }
    if (selected.items.len == 0) return error.NoMatchingScenarios;
    if (options.list) {
        for (selected.items) |scenario| {
            const patterns = if (scenario.pressure == null) "fresh, repeat" else "pressure";
            try common.print("{s:<30} {s}\n", .{ scenario.name, patterns });
        }
        return;
    }

    common.installInterruptHandler();
    const result_path = try common.resultPath(allocator, options.output_path, "", null);
    const result_file = try common.createResult(result_path);
    defer result_file.close();
    var result_buffer: [8192]u8 = undefined;
    var result_writer = result_file.writer(&result_buffer);
    const output = &result_writer.interface;
    const metadata = try common.runMetadata(allocator);
    try common.emitRun(output, metadata, .{
        .suite_version = suite_version,
        .generator_version = fixtures.generator_version,
        .repetitions = options.repetitions,
        .os_cache = "uncontrolled; fixtures just generated",
        .fixture_storage = "system temporary directory; deleted after each scenario",
        .warmups = "no discarded samples; repeat primes retained but not summarized",
    });
    report(selected.items, options.repetitions, result_path, output) catch |err| {
        try common.finish(output, err);
        return err;
    };
    try common.finish(output, null);
}

fn report(cases: []const Scenario, repetitions: usize, result_path: []const u8, output: *std.Io.Writer) !void {
    try common.print("Results: {s}\n", .{result_path});
    try common.print("Scenario                       Pattern  Cache        Outcome       n   Median ms      Min ms      Max ms\n", .{});
    // The named scenarios cover these production limits independently.
    if (content.max_file_size != 64 * mib or content.cache_file_limit != 8 or content.cache_byte_limit != 8 * mib) {
        return error.ReadinessScenarioLimitsChanged;
    }
    for (cases) |scenario| {
        try runScenario(std.heap.page_allocator, scenario, repetitions, output, true);
    }
    try common.checkInterrupted();
}

const Fixture = union(enum) {
    generated: fixtures.Metadata,
    missing,

    pub fn jsonStringify(fixture: Fixture, json: anytype) !void {
        switch (fixture) {
            .generated => |metadata| try json.write(metadata),
            .missing => try json.write(.{ .byte_count = 0, .line_count = 1, .exists = false }),
        }
    }

    fn lineCount(fixture: Fixture) usize {
        return switch (fixture) {
            .generated => |metadata| metadata.line_count,
            .missing => 1,
        };
    }
};

fn runScenario(backing_allocator: std.mem.Allocator, scenario: Scenario, repetitions: usize, output: *std.Io.Writer, print_summary: bool) !void {
    try common.checkInterrupted();
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = try common.TempDir.init(allocator, "tome-benchmark-");
    defer temp.deinit();
    var dir = try std.fs.openDirAbsolute(temp.path, .{});
    defer dir.close();

    var inputs: std.json.ArrayHashMap(Fixture) = .{};
    const file_count = if (scenario.pressure) |pressure| pressure.file_count else 1;
    for (0..file_count) |index| {
        try common.checkInterrupted();
        const filename = try std.fmt.allocPrint(allocator, "file-{d:0>3}.txt", .{index});
        const fixture: Fixture = if (scenario.missing)
            .missing
        else
            .{ .generated = try fixtures.generate(dir, filename, scenario.recipe) };
        try inputs.map.put(allocator, filename, fixture);
    }
    const patterns = scenario.patterns();
    try common.emit(output, .{
        .type = "scenario",
        .scenario = scenario.name,
        .patterns = patterns,
        .fixtures = inputs,
        .expected_error = errorName(scenario.expected_error),
        .active_file = @as(?usize, null),
    });

    const target = try std.fs.path.join(allocator, &.{ temp.path, target_name });
    for (patterns) |pattern| {
        const summary = try runCasePattern(backing_allocator, scenario, pattern, repetitions, temp.path, target, inputs, output);
        if (print_summary) try summary.print();
    }
}

fn runCasePattern(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    pattern: Mode,
    repetitions: usize,
    root: []const u8,
    target: []const u8,
    inputs: std.json.ArrayHashMap(Fixture),
    output: *std.Io.Writer,
) !Summary {
    try common.checkInterrupted();
    try common.emit(output, .{
        .type = "worker",
        .optimize = @tagName(builtin.mode),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .cpu_arch = @tagName(builtin.cpu.arch),
        .max_file_size = content.max_file_size,
        .cache_file_limit = content.cache_file_limit,
        .cache_byte_limit = content.cache_byte_limit,
        .scenario = scenario.name,
        .pattern = pattern,
    });

    const elapsed = try allocator.alloc(u64, repetitions);
    defer allocator.free(elapsed);
    const expected_requests = switch (pattern) {
        .fresh => repetitions,
        .repeat => try std.math.add(usize, repetitions, 1),
        .pressure => try std.math.mul(usize, repetitions, inputs.map.count() + 1),
    };
    var sink: ValidationSink = .{
        .output = output,
        .scenario = scenario,
        .pattern = pattern,
        .inputs = inputs,
        .elapsed = elapsed,
        .expected_requests = expected_requests,
    };
    try runPattern(allocator, pattern, repetitions, root, target, &sink);
    if (sink.invalid or sink.request_count != expected_requests or sink.sample_count != elapsed.len) {
        return error.ReadinessValidationFailed;
    }
    if (scenario.missing) {
        if (std.fs.cwd().access(target, .{})) |_| {
            return error.MissingFixtureCreated;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    try common.checkInterrupted();

    std.mem.sort(u64, elapsed, {}, comptime std.sort.asc(u64));
    const summary: Summary = .{
        .scenario = scenario.name,
        .pattern = pattern,
        .cache = targetCache(scenario, pattern),
        .outcome = if (scenario.expected_error == null) "ready" else "failed",
        .error_name = errorName(scenario.expected_error),
        .sample_count = elapsed.len,
        .median_ns = common.median(elapsed),
        .min_ns = elapsed[0],
        .max_ns = elapsed[elapsed.len - 1],
    };
    try common.emit(output, summary);
    return summary;
}

fn errorName(err: ?anyerror) ?[]const u8 {
    return if (err) |failure| @errorName(failure) else null;
}

fn targetCache(scenario: Scenario, pattern: Mode) Cache {
    return switch (pattern) {
        .fresh => .miss,
        .repeat => if (scenario.expected_error == null) .hit else .cached_error,
        .pressure => scenario.pressure.?.cache,
    };
}

const Summary = struct {
    type: []const u8 = "summary",
    scenario: []const u8,
    pattern: Mode,
    cache: Cache,
    outcome: []const u8,
    error_name: ?[]const u8,
    sample_count: usize,
    median_ns: f64,
    min_ns: u64,
    max_ns: u64,

    fn print(summary: Summary) !void {
        try common.print("{s:<30} {s:<8} {s:<12} {s:<10} {d:>4} {d:>11.6} {d:>11.6} {d:>11.6}\n", .{
            summary.scenario,     @tagName(summary.pattern),              @tagName(summary.cache),                                      summary.error_name orelse summary.outcome,
            summary.sample_count, summary.median_ns / std.time.ns_per_ms, @as(f64, @floatFromInt(summary.min_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(summary.max_ns)) / std.time.ns_per_ms,
        });
    }
};

const ExpectedRequest = struct {
    iteration: usize,
    role: Role = .sample,
    file_index: usize = 0,
    cache: Cache = .miss,

    fn at(index: usize, scenario: Scenario, pattern: Mode, file_count: usize) ExpectedRequest {
        return switch (pattern) {
            .fresh => .{ .iteration = index },
            .repeat => if (index == 0)
                .{ .iteration = 0, .role = .prime }
            else
                .{ .iteration = index - 1, .cache = targetCache(scenario, pattern) },
            .pressure => request: {
                const iteration = index / (file_count + 1);
                const offset = index % (file_count + 1);
                if (offset == 0) break :request .{ .iteration = iteration, .role = .prime };
                if (offset < file_count) break :request .{ .iteration = iteration, .role = .pressure, .file_index = offset };
                break :request .{ .iteration = iteration, .cache = targetCache(scenario, pattern) };
            },
        };
    }
};

const ValidationSink = struct {
    output: *std.Io.Writer,
    scenario: Scenario,
    pattern: Mode,
    inputs: std.json.ArrayHashMap(Fixture),
    elapsed: []u64,
    expected_requests: usize,
    request_count: usize = 0,
    sample_count: usize = 0,
    invalid: bool = false,

    fn write(sink: *ValidationSink, workspace: *const Workspace, record: Record) !void {
        const sample = record.sample;
        const filename = workspace.entries.items[sample.index].name;
        const actual_error: ?anyerror = switch (sample.outcome) {
            .ready => null,
            .failed => |err| err,
        };
        var error_buffer: [8][]const u8 = undefined;
        const validation_errors = if (sink.request_count >= sink.expected_requests)
            &[_][]const u8{"unexpected extra request"}
        else
            sink.validate(record, filename, actual_error, &error_buffer);
        sink.request_count += 1;
        sink.invalid = sink.invalid or validation_errors.len != 0;
        if (record.role == .sample and validation_errors.len == 0 and sink.sample_count < sink.elapsed.len) {
            sink.elapsed[sink.sample_count] = sample.elapsed_ns;
            sink.sample_count += 1;
        }
        try common.emit(sink.output, .{
            .type = "sample",
            .metric = "file_request_to_ready",
            .iteration = record.iteration,
            .role = record.role,
            .file_name = filename,
            .file_index = sample.index,
            .elapsed_ns = sample.elapsed_ns,
            .cache = sample.cache,
            .byte_count = sample.byte_count,
            .line_count = record.line_count,
            .is_new = sample.is_new,
            .outcome = @tagName(sample.outcome),
            .error_name = errorName(actual_error),
            .scenario = sink.scenario.name,
            .pattern = sink.pattern,
            .valid = validation_errors.len == 0,
            .validation_errors = validation_errors,
        });
    }

    fn validate(
        sink: *const ValidationSink,
        record: Record,
        filename: []const u8,
        actual_error: ?anyerror,
        errors: *[8][]const u8,
    ) []const []const u8 {
        const expected = ExpectedRequest.at(sink.request_count, sink.scenario, sink.pattern, sink.inputs.map.count());
        const expected_name = sink.inputs.map.keys()[expected.file_index];
        const fixture = sink.inputs.map.values()[expected.file_index];
        const ready = sink.scenario.expected_error == null;
        const expected_bytes: ?usize = if (ready) sink.scenario.recipe.byte_count else null;
        const expected_is_new: ?bool = if (ready) sink.scenario.missing else null;
        const expected_lines: ?usize = if (ready) fixture.lineCount() else null;
        const checks = .{
            .iteration = record.iteration == expected.iteration,
            .role = record.role == expected.role,
            .file_name = std.mem.eql(u8, filename, expected_name),
            .cache = record.sample.cache == expected.cache,
            .error_name = actual_error == sink.scenario.expected_error,
            .byte_count = record.sample.byte_count == expected_bytes,
            .is_new = record.sample.is_new == expected_is_new,
            .line_count = record.line_count == expected_lines,
        };
        var count: usize = 0;
        inline for (std.meta.fields(@TypeOf(checks))) |field| {
            if (!@field(checks, field.name)) {
                errors[count] = field.name ++ ": unexpected value";
                count += 1;
            }
        }
        return errors[0..count];
    }
};

// Keep recording allocations and JSON output outside each request sequence.
// Repeat requests use fixed batches so the memory cost does not grow with N.
fn runPattern(allocator: std.mem.Allocator, mode: Mode, repetitions: usize, root: []const u8, target: []const u8, sink: anytype) !void {
    switch (mode) {
        .fresh => for (0..repetitions) |iteration| {
            var workspace = try Workspace.open(allocator, root, target);
            defer workspace.deinit();
            const record = try measure(&workspace, workspace.initial_index, iteration, .sample);
            try sink.write(&workspace, record);
        },
        .repeat => {
            var workspace = try Workspace.open(allocator, root, target);
            defer workspace.deinit();
            var records: [256]Record = undefined;
            records[0] = try measure(&workspace, workspace.initial_index, 0, .prime);
            var count: usize = 1;
            for (0..repetitions) |iteration| {
                records[count] = try measure(&workspace, workspace.initial_index, iteration, .sample);
                count += 1;
                if (count == records.len) {
                    for (records[0..count]) |record| try sink.write(&workspace, record);
                    count = 0;
                }
            }
            for (records[0..count]) |record| try sink.write(&workspace, record);
        },
        .pressure => for (0..repetitions) |iteration| {
            var workspace = try Workspace.open(allocator, root, target);
            defer workspace.deinit();
            // No file is active: only the currently requested file is protected.
            const records = try allocator.alloc(Record, workspace.entries.items.len + 1);
            defer allocator.free(records);
            records[0] = try measure(&workspace, workspace.initial_index, iteration, .prime);
            var count: usize = 1;
            for (workspace.entries.items, 0..) |_, index| {
                if (index == workspace.initial_index) continue;
                records[count] = try measure(&workspace, index, iteration, .pressure);
                count += 1;
            }
            records[count] = try measure(&workspace, workspace.initial_index, iteration, .sample);
            for (records) |record| try sink.write(&workspace, record);
        },
    }
}

fn measure(workspace: *Workspace, index: usize, iteration: usize, role: Role) !Record {
    try common.checkInterrupted();
    const sample = try file_ready.measure(workspace, index);
    return .{
        .iteration = iteration,
        .role = role,
        .sample = sample,
        .line_count = if (sample.outcome == .ready) workspace.entries.items[index].line_count else null,
    };
}

const TestSink = struct {
    records: std.ArrayList(Record) = .empty,

    fn write(self: *TestSink, _: *const Workspace, record: Record) !void {
        try self.records.append(std.testing.allocator, record);
    }

    fn deinit(self: *TestSink) void {
        self.records.deinit(std.testing.allocator);
    }
};

test "fresh workspaces miss while repeats retain one primed buffer" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "target", .data = "a\nb\n" });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "target" });
    defer allocator.free(target);
    var fresh: TestSink = .{};
    defer fresh.deinit();
    try runPattern(allocator, .fresh, 2, root, target, &fresh);
    try std.testing.expectEqual(@as(usize, 2), fresh.records.items.len);
    for (fresh.records.items, 0..) |record, iteration| {
        try std.testing.expectEqual(iteration, record.iteration);
        try std.testing.expectEqual(Role.sample, record.role);
        try std.testing.expectEqual(file_ready.Cache.miss, record.sample.cache);
        try std.testing.expectEqual(@as(?usize, 3), record.line_count);
    }
    var repeated: TestSink = .{};
    defer repeated.deinit();
    // Cross a batch boundary to verify that buffering never adds a new prime.
    try runPattern(allocator, .repeat, 257, root, target, &repeated);
    try std.testing.expectEqual(@as(usize, 258), repeated.records.items.len);
    try std.testing.expectEqual(Role.prime, repeated.records.items[0].role);
    try std.testing.expectEqual(file_ready.Cache.miss, repeated.records.items[0].sample.cache);
    for (repeated.records.items[1..], 0..) |record, iteration| {
        try std.testing.expectEqual(iteration, record.iteration);
        try std.testing.expectEqual(Role.sample, record.role);
        try std.testing.expectEqual(file_ready.Cache.hit, record.sample.cache);
    }
}

test "pressure revisits hit at the file budget and reload above it" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var name_buffer: [32]u8 = undefined;
    for (0..content.cache_file_limit) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "file-{d}", .{index});
        try temp.dir.writeFile(.{ .sub_path = name, .data = "small\n" });
    }
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "file-0" });
    defer allocator.free(target);
    var resident: TestSink = .{};
    defer resident.deinit();
    try runPattern(allocator, .pressure, 1, root, target, &resident);
    try std.testing.expectEqual(content.cache_file_limit + 1, resident.records.items.len);
    try std.testing.expectEqual(file_ready.Cache.hit, resident.records.items[resident.records.items.len - 1].sample.cache);

    try temp.dir.writeFile(.{ .sub_path = "extra", .data = "small\n" });
    var evicted: TestSink = .{};
    defer evicted.deinit();
    try runPattern(allocator, .pressure, 2, root, target, &evicted);
    const count = content.cache_file_limit + 2;
    try std.testing.expectEqual(2 * count, evicted.records.items.len);
    for (0..2) |iteration| {
        const records = evicted.records.items[iteration * count ..][0..count];
        try std.testing.expectEqual(Role.prime, records[0].role);
        for (records[1 .. count - 1]) |record| {
            try std.testing.expectEqual(Role.pressure, record.role);
            try std.testing.expectEqual(iteration, record.iteration);
        }
        const last = records[count - 1];
        try std.testing.expectEqual(Role.sample, last.role);
        try std.testing.expectEqual(iteration, last.iteration);
        try std.testing.expectEqual(file_ready.Cache.miss, last.sample.cache);
        try std.testing.expect(last.sample.outcome == .ready);
    }
}

test "remembered failures remain samples with no readiness metadata" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile("oversized", .{});
    defer file.close();
    try file.setEndPos(content.max_file_size + 1);
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "oversized" });
    defer allocator.free(target);
    var sink: TestSink = .{};
    defer sink.deinit();
    try runPattern(allocator, .repeat, 2, root, target, &sink);
    try std.testing.expectEqual(@as(usize, 3), sink.records.items.len);
    try std.testing.expectEqual(file_ready.Cache.miss, sink.records.items[0].sample.cache);
    for (sink.records.items) |record| {
        try std.testing.expect(record.sample.outcome == .failed);
        try std.testing.expectEqual(error.FileTooBig, record.sample.outcome.failed);
        try std.testing.expect(record.sample.byte_count == null);
        try std.testing.expect(record.line_count == null);
    }
    for (sink.records.items[1..]) |record| try std.testing.expectEqual(file_ready.Cache.cached_error, record.sample.cache);
}

test "readiness report validates missing files and both sides of the byte budget" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cases = [_]Scenario{
        .{ .name = "boundary/missing", .recipe = .{ .byte_count = 0 }, .missing = true },
        .{ .name = "cache/bytes-at", .recipe = .{ .byte_count = 4 * mib }, .pressure = .{ .file_count = 2, .cache = .hit } },
        .{ .name = "cache/bytes-above", .recipe = .{ .byte_count = 4 * mib + 1 }, .pressure = .{ .file_count = 2, .cache = .miss } },
    };
    for (cases) |scenario| try runScenario(allocator, scenario, 1, &output.writer, false);

    const summary_caches = [_][]const u8{ "miss", "hit", "hit", "miss" };
    var summary_count: usize = 0;
    var sample_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, output.written(), '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const record = parsed.value.object;
        const kind = record.get("type").?.string;
        if (std.mem.eql(u8, kind, "sample")) {
            try std.testing.expect(record.get("valid").?.bool);
            const missing = std.mem.eql(u8, record.get("scenario").?.string, "boundary/missing");
            try std.testing.expectEqual(missing, record.get("is_new").?.bool);
            sample_count += 1;
        } else if (std.mem.eql(u8, kind, "summary")) {
            try std.testing.expect(summary_count < summary_caches.len);
            try std.testing.expectEqualStrings(summary_caches[summary_count], record.get("cache").?.string);
            try std.testing.expectEqual(@as(i64, 1), record.get("sample_count").?.integer);
            summary_count += 1;
        } else if (std.mem.eql(u8, kind, "scenario")) {
            const fixture = record.get("fixtures").?.object.get(target_name).?.object;
            if (std.mem.eql(u8, record.get("scenario").?.string, "boundary/missing")) {
                try std.testing.expect(!fixture.get("exists").?.bool);
            } else {
                try std.testing.expectEqual(@as(usize, 64), fixture.get("sha256").?.string.len);
            }
        }
    }
    try std.testing.expectEqual(summary_caches.len, summary_count);
    try std.testing.expectEqual(@as(usize, 9), sample_count);
}

test "unexpected readiness results retain raw samples without a summary" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const scenario: Scenario = .{
        .name = "wrong-expectation",
        .recipe = .{ .byte_count = 20 },
        .expected_error = error.FileTooBig,
    };
    try std.testing.expectError(error.ReadinessValidationFailed, runScenario(std.testing.allocator, scenario, 1, &output.writer, false));
    const report_bytes = output.written();
    try std.testing.expect(std.mem.indexOf(u8, report_bytes, "\"valid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_bytes, "\"type\":\"summary\"") == null);
}
