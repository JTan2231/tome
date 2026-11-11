const std = @import("std");
const builtin = @import("builtin");
const content = @import("content");
const Workspace = content.Workspace;
const file_ready = @import("measurement");

const Mode = enum { fresh, repeat, pressure };
const Role = enum { sample, prime, pressure };
const Record = struct {
    iteration: usize,
    role: Role,
    sample: file_ready.Sample,
    line_count: ?usize,
};

const usage =
    \\Usage: tome-bench <fresh|repeat|pressure> <repetitions> <workspace-root> <target-path>
    \\
    \\Measure generated inputs through Tome's file-readiness boundary.
    \\fresh: a new workspace for each target request.
    \\repeat: prime once, then request the resident target repeatedly.
    \\pressure: prime the target, request every other file, then revisit it;
    \\          start a new workspace for each repetition, with no active file.
    \\Write build metadata and every request as JSON lines to stdout.
    \\File failures remain samples; setup and clock errors exit unsuccessfully.
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("tome-bench: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var output: Output = .{ .allocator = allocator, .file = .{ .handle = if (builtin.os.tag == .windows)
        try std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE)
    else
        std.posix.STDOUT_FILENO } };
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try output.file.writeAll(usage);
        return;
    }
    if (args.len != 5) {
        std.debug.print("{s}", .{usage});
        return error.ExpectedModeRepetitionsWorkspaceAndTarget;
    }
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidMode;
    const repetitions = std.fmt.parseInt(usize, args[2], 10) catch return error.InvalidRepetitions;
    if (repetitions == 0) return error.InvalidRepetitions;
    try output.json(.{
        .type = "worker",
        .optimize = @tagName(builtin.mode),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .cpu_arch = @tagName(builtin.cpu.arch),
        .max_file_size = content.max_file_size,
        .cache_file_limit = content.cache_file_limit,
        .cache_byte_limit = content.cache_byte_limit,
    });
    try runPattern(allocator, mode, repetitions, args[3], args[4], &output);
}

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
    const sample = try file_ready.measure(workspace, index);
    return .{
        .iteration = iteration,
        .role = role,
        .sample = sample,
        .line_count = if (sample.outcome == .ready) workspace.entries.items[index].line_count else null,
    };
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

    fn write(self: *Output, workspace: *const Workspace, record: Record) !void {
        const sample = record.sample;
        const error_name: ?[]const u8 = switch (sample.outcome) {
            .ready => null,
            .failed => |err| @errorName(err),
        };
        try self.json(.{
            .type = "sample",
            .metric = "file_request_to_ready",
            .iteration = record.iteration,
            .role = @tagName(record.role),
            .file_name = workspace.entries.items[sample.index].name,
            .file_index = sample.index,
            .elapsed_ns = sample.elapsed_ns,
            .cache = @tagName(sample.cache),
            .byte_count = sample.byte_count,
            .line_count = record.line_count,
            .is_new = sample.is_new,
            .outcome = @tagName(sample.outcome),
            .error_name = error_name,
        });
    }
};

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
