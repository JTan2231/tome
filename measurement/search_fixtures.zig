const std = @import("std");
const file_stats = @import("file_stats.zig");
const common = @import("common.zig");

const mib = 1024 * 1024;
pub const max_file_size = 64 * mib;
pub const query = "TOME_SEARCH_NEEDLE";
pub const rows = 40;
pub const cols = 120;

pub const Config = struct {
    repetitions: usize,
    rows: usize,
    cols: usize,
    origin_file: usize = 0,
    origin_offset: usize = 0,
    target_file: ?usize = null,
    target_offset: ?usize = null,
    preload_target: bool = false,
    query: []const u8,
    expected_message: []const u8,
};

const FileSpec = struct {
    byte_count: usize,
    needle_offset: ?usize = null,
    line_bytes: ?usize = 63,

    fn period(self: FileSpec) ?usize {
        return if (self.line_bytes) |length| @min(length, self.byte_count) + 1 else null;
    }

    fn validate(self: FileSpec) !void {
        if (self.byte_count == 0 or self.byte_count > max_file_size) return error.InvalidFixtureSize;
        if (self.needle_offset) |offset| {
            if (offset > self.byte_count or query.len > self.byte_count - offset) return error.NeedleOutsideFixture;
            if (self.period()) |line_period| {
                if (offset % line_period + query.len >= line_period) return error.NeedleOverwritesNewline;
            }
        }
    }
};

pub const Scenario = struct {
    name: []const u8,
    files: []const FileSpec,
    target_file: ?usize = 0,
    origin_offset: usize = 0,
    preload_target: bool = false,
    target_visible: bool = false,
};

const origin: FileSpec = .{ .byte_count = 8192 };
const target_offset = mib + 1 - origin.byte_count;
const pair = [_]FileSpec{ origin, .{ .byte_count = 8 * mib, .needle_offset = target_offset } };
const one_body = bodyFiles(1);
const many_bodies = bodyFiles(512);

pub const scenarios = [_]Scenario{
    distance("window-64B", 64),
    distance("4KiB", 4096),
    distance("64KiB", 65536),
    distance("1MiB", mib),
    distance("8MiB", 8 * mib),
    distance("32MiB", 32 * mib),
    .{ .name = "extent/near-end", .files = &.{.{ .byte_count = max_file_size, .needle_offset = max_file_size - query.len - 1 }} },
    .{ .name = "extent/wrapped-at-cursor", .files = &.{.{ .byte_count = max_file_size, .needle_offset = 0 }}, .target_visible = true },
    .{ .name = "extent/no-match", .files = &.{.{ .byte_count = max_file_size }}, .target_file = null },
    .{ .name = "readiness/resident", .files = &pair, .target_file = 1, .preload_target = true },
    .{ .name = "readiness/unloaded", .files = &pair, .target_file = 1 },
    .{ .name = "files/one-body", .files = &one_body, .target_file = one_body.len - 1 },
    .{ .name = "files/512-bodies", .files = &many_bodies, .target_file = many_bodies.len - 1 },
    .{ .name = "shape/long-line", .files = &.{ origin, .{ .byte_count = 8 * mib, .needle_offset = target_offset, .line_bytes = null } }, .target_file = 1 },
    .{ .name = "shape/large-target", .files = &.{ origin, .{ .byte_count = max_file_size, .needle_offset = target_offset } }, .target_file = 1 },
};

fn distance(comptime label: []const u8, comptime bytes: usize) Scenario {
    return .{
        .name = "distance/" ++ label,
        .files = &.{.{ .byte_count = max_file_size, .needle_offset = bytes + 1 }},
        .target_visible = bytes == 64,
    };
}

fn bodyFiles(comptime count: usize) [count + 2]FileSpec {
    const body_bytes = 8 * mib - origin.byte_count;
    var files: [count + 2]FileSpec = undefined;
    files[0] = origin;
    for (files[1 .. files.len - 1], 0..) |*body, index| {
        body.* = .{ .byte_count = body_bytes / count + @intFromBool(index < body_bytes % count) };
    }
    files[files.len - 1] = .{ .byte_count = 8192, .needle_offset = 1 };
    return files;
}

const Fixture = struct {
    stats: file_stats.FileStats,
    needle_offset: ?usize,
    ordinary_line_bytes: ?usize,

    pub fn jsonStringify(self: Fixture, json: *std.json.Stringify) !void {
        try json.beginObject();
        try self.stats.writeFields(json);
        try common.jsonFields(json, .{
            .needle_offset = self.needle_offset,
            .ordinary_line_bytes = self.ordinary_line_bytes,
        });
        try json.endObject();
    }
};

pub const Metadata = struct {
    type: []const u8 = "scenario",
    scenario: []const u8,
    config: Config,
    fixtures: std.json.ArrayHashMap(Fixture) = .{},
    file_count: usize,
    search_distance_bytes: ?usize = null,
    traversal_bytes: usize = 0,
    file_boundaries_before_match: ?usize = null,
    target_file_bytes: ?usize = null,
    target_line_offset_bytes: ?usize = null,
    target_line_bytes: ?usize = null,
    expected_target_resident: ?bool = null,
    expected_target_visible: ?bool = null,
};

fn generateFile(dir: std.fs.Dir, name: []const u8, spec: FileSpec) !Fixture {
    const period = spec.period();
    {
        const file = try dir.createFile(name, .{ .exclusive = true });
        defer file.close();
        var buffer: [64 * 1024]u8 = undefined;
        var offset: usize = 0;
        while (offset < spec.byte_count) {
            try common.checkInterrupted();
            const chunk = buffer[0..@min(buffer.len, spec.byte_count - offset)];
            @memset(chunk, 'x');
            if (period) |line_period| {
                var newline = line_period - 1 - offset % line_period;
                while (newline < chunk.len) : (newline += line_period) chunk[newline] = '\n';
            }
            try file.writeAll(chunk);
            offset += chunk.len;
        }
        if (spec.needle_offset) |offset_in_file| try file.pwriteAll(query, offset_in_file);
    }

    const stats = file_stats.read(dir, name, max_file_size);
    if (stats.stats_status != .ok or stats.byte_count != spec.byte_count) return error.InvalidFixture;
    return .{ .stats = stats, .needle_offset = spec.needle_offset, .ordinary_line_bytes = spec.line_bytes };
}

pub fn describe(case: Scenario, repetitions: usize) !Metadata {
    if (case.files.len == 0 or case.origin_offset >= case.files[0].byte_count) return error.InvalidFixtureOrigin;
    var result: Metadata = .{
        .scenario = case.name,
        .file_count = case.files.len,
        .config = .{
            .repetitions = repetitions,
            .rows = rows,
            .cols = cols,
            .origin_offset = case.origin_offset,
            .target_file = case.target_file,
            .preload_target = case.preload_target,
            .query = query,
            .expected_message = "Pattern not found",
        },
    };
    for (case.files) |file| {
        try file.validate();
        result.traversal_bytes += file.byte_count;
    }
    if (case.target_file) |index| {
        if (index >= case.files.len) return error.InvalidFixtureTarget;
        const target = case.files[index];
        const offset = target.needle_offset orelse return error.MissingFixtureNeedle;
        const wrapped = index == 0 and offset <= case.origin_offset;
        result.config.target_offset = offset;
        result.config.expected_message = if (wrapped) "Search wrapped" else "Match";
        result.expected_target_resident = index == 0 or case.preload_target;
        result.expected_target_visible = case.target_visible;
        result.target_file_bytes = target.byte_count;
        if (target.period()) |period| {
            const line_offset = offset % period;
            result.target_line_offset_bytes = line_offset;
            result.target_line_bytes = @min(period - 1, target.byte_count - (offset - line_offset));
        } else {
            result.target_line_offset_bytes = offset;
            result.target_line_bytes = target.byte_count;
        }

        var absolute_offset = offset;
        for (case.files[0..index]) |file| absolute_offset += file.byte_count;
        if (wrapped) absolute_offset += result.traversal_bytes;
        result.search_distance_bytes = absolute_offset - case.origin_offset - 1;
        result.file_boundaries_before_match = if (wrapped) case.files.len else index;
    }
    return result;
}

pub fn generate(allocator: std.mem.Allocator, dir: std.fs.Dir, case: Scenario, repetitions: usize) !Metadata {
    var result = try describe(case, repetitions);
    for (case.files, 0..) |spec, index| {
        const name = try std.fmt.allocPrint(allocator, "file-{d:0>4}.txt", .{index});
        try result.fixtures.map.put(allocator, name, try generateFile(dir, name, spec));
    }
    return result;
}

test "search fixtures report generated bytes and forward and wrapped positions" {
    const cases = [_]Scenario{
        .{ .name = "forward", .files = &.{ origin, .{ .byte_count = 4096, .needle_offset = 65 } }, .target_file = 1 },
        .{ .name = "wrapped", .files = &.{.{ .byte_count = 8192, .needle_offset = 65 }}, .origin_offset = 65 },
        .{ .name = "miss", .files = &.{origin}, .target_file = null },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const result = try generate(allocator, tmp.dir, case, 1);
        var traversal: std.ArrayList(u8) = .empty;
        var target_bytes: []const u8 = &.{};
        for (result.fixtures.map.keys(), result.fixtures.map.values(), 0..) |name, fixture, index| {
            const bytes = try tmp.dir.readFileAlloc(allocator, name, max_file_size);
            try std.testing.expectEqual(bytes.len, fixture.stats.byte_count.?);
            try std.testing.expectEqual(1 + std.mem.count(u8, bytes, "\n"), fixture.stats.line_count.?);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualSlices(u8, &std.fmt.bytesToHex(digest, .lower), &fixture.stats.sha256.?);
            try traversal.appendSlice(allocator, bytes);
            if (case.target_file == index) target_bytes = bytes;
        }
        try std.testing.expectEqual(traversal.items.len, result.traversal_bytes);
        try std.testing.expectEqual(case.files.len, result.file_count);
        if (case.target_file == null) {
            try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, traversal.items, query));
            try std.testing.expectEqual(@as(?usize, null), result.search_distance_bytes);
            try std.testing.expectEqual(@as(?usize, null), result.file_boundaries_before_match);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, traversal.items, query));
        const match = std.mem.indexOf(u8, traversal.items, query).?;
        const forward = (match + traversal.items.len - case.origin_offset - 1) % traversal.items.len;
        try std.testing.expectEqual(forward, result.search_distance_bytes.?);
        const offset = std.mem.indexOf(u8, target_bytes, query).?;
        const start = if (std.mem.lastIndexOfScalar(u8, target_bytes[0..offset], '\n')) |newline| newline + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, target_bytes, offset, '\n') orelse target_bytes.len;
        try std.testing.expectEqual(offset, result.config.target_offset.?);
        try std.testing.expectEqual(offset - start, result.target_line_offset_bytes.?);
        try std.testing.expectEqual(end - start, result.target_line_bytes.?);
    }
}

test "search file count cases hold distance and destination constant" {
    const first = try describe(.{ .name = "one", .files = &one_body, .target_file = 2 }, 1);
    const second = try describe(.{ .name = "many", .files = &many_bodies, .target_file = 513 }, 1);
    try std.testing.expectEqual(first.traversal_bytes, second.traversal_bytes);
    try std.testing.expectEqual(@as(?usize, 8 * mib), first.search_distance_bytes);
    try std.testing.expectEqual(first.search_distance_bytes, second.search_distance_bytes);
    try std.testing.expectEqual(first.target_file_bytes, second.target_file_bytes);
    try std.testing.expectEqual(first.target_line_offset_bytes, second.target_line_offset_bytes);
    try std.testing.expectEqual(first.expected_target_resident, second.expected_target_resident);
    try std.testing.expectEqual(@as(?usize, 2), first.file_boundaries_before_match);
    try std.testing.expectEqual(@as(?usize, 513), second.file_boundaries_before_match);
}
