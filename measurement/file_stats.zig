const std = @import("std");

pub const LineSizeCounts = struct {
    @"0": u64 = 0,
    @"1-80": u64 = 0,
    @"81-256": u64 = 0,
    @"257-1024": u64 = 0,
    @"1025-4096": u64 = 0,
    @"4097-65536": u64 = 0,
    @"65537+": u64 = 0,

    fn count(self: *LineSizeCounts, bytes: u64) void {
        switch (bytes) {
            0 => self.@"0" += 1,
            1...80 => self.@"1-80" += 1,
            81...256 => self.@"81-256" += 1,
            257...1024 => self.@"257-1024" += 1,
            1025...4096 => self.@"1025-4096" += 1,
            4097...65536 => self.@"4097-65536" += 1,
            else => self.@"65537+" += 1,
        }
    }

    pub fn add(self: *LineSizeCounts, other: LineSizeCounts) void {
        inline for (std.meta.fields(LineSizeCounts)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

pub const FileStats = struct {
    stats_status: enum { failed, oversized, ok } = .failed,
    byte_count: ?u64 = null,
    line_count: ?u64 = null,
    content_byte_count: ?u64 = null,
    max_line_bytes: ?u64 = null,
    mean_line_bytes: ?f64 = null,
    line_size_counts: ?LineSizeCounts = null,
    mtime_ns: ?i128 = null,
    sha256: ?[64]u8 = null,
    changed_during_inventory: ?bool = null,
    stats_error: ?[]const u8 = null,

    pub fn jsonStringify(self: FileStats, jws: anytype) !void {
        try jws.beginObject();
        try self.writeFields(jws);
        try jws.endObject();
    }

    pub fn writeFields(self: FileStats, jws: anytype) !void {
        inline for (std.meta.fields(FileStats)) |field| {
            const value = @field(self, field.name);
            if (comptime std.mem.eql(u8, field.name, "mtime_ns") or
                std.mem.eql(u8, field.name, "sha256") or
                std.mem.eql(u8, field.name, "changed_during_inventory") or
                std.mem.eql(u8, field.name, "stats_error"))
            {
                if (value != null) {
                    try jws.objectField(field.name);
                    try jws.write(value.?);
                }
            } else {
                try jws.objectField(field.name);
                try jws.write(value);
            }
        }
    }
};

const Lines = struct {
    line_count: u64 = 0,
    content_byte_count: u64 = 0,
    max_line_bytes: u64 = 0,
    counts: LineSizeCounts = .{},

    fn finish(self: *Lines, bytes: u64) void {
        self.line_count += 1;
        self.content_byte_count += bytes;
        self.max_line_bytes = @max(self.max_line_bytes, bytes);
        self.counts.count(bytes);
    }
};

pub fn read(dir: std.fs.Dir, path: []const u8, max_file_size: u64) FileStats {
    var result: FileStats = .{};
    scan(dir, path, max_file_size, &result) catch |err| {
        result.stats_error = @errorName(err);
    };
    return result;
}

fn scan(dir: std.fs.Dir, path: []const u8, max_file_size: u64, result: *FileStats) !void {
    const before = try dir.statFile(path);
    result.byte_count = before.size;
    result.mtime_ns = before.mtime;
    if (before.size > max_file_size) {
        result.stats_status = .oversized;
        return;
    }

    const file = try dir.openFile(path, .{});
    defer file.close();
    var buffer: [64 * 1024]u8 = undefined;
    var lines: Lines = .{};
    var total: u64 = 0;
    var pending: u64 = 0;
    var last_byte: ?u8 = null;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const size = try file.read(&buffer);
        if (size == 0) break;
        total += size;
        if (total > max_file_size) {
            result.stats_status = .oversized;
            result.stats_error = "file grew past the size limit";
            return;
        }
        const chunk = buffer[0..size];
        digest.update(chunk);
        var parts = std.mem.splitScalar(u8, chunk, '\n');
        while (parts.next()) |part| {
            pending += part.len;
            if (part.len > 0) last_byte = part[part.len - 1];
            if (parts.index != null) {
                lines.finish(pending - @intFromBool(last_byte == '\r'));
                pending = 0;
                last_byte = null;
            }
        }
    }
    lines.finish(pending);
    const after = try dir.statFile(path);
    result.stats_status = .ok;
    result.byte_count = total;
    result.line_count = lines.line_count;
    result.content_byte_count = lines.content_byte_count;
    result.max_line_bytes = lines.max_line_bytes;
    result.mean_line_bytes = @as(f64, @floatFromInt(lines.content_byte_count)) / @as(f64, @floatFromInt(lines.line_count));
    result.line_size_counts = lines.counts;
    result.sha256 = std.fmt.bytesToHex(digest.finalResult(), .lower);
    result.changed_during_inventory = before.size != after.size or before.mtime != after.mtime or before.inode != after.inode;
}

test "line inventory retains trailing CR except at an LF across read chunks" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = "long.txt";
    const mib = 1024 * 1024;
    {
        const file = try temp.dir.createFile(path, .{});
        defer file.close();
        const content = "x" ** (64 * 1024);
        for (0..15) |_| try file.writeAll(content);
        try file.writeAll(content[1..]);
        try file.writeAll("\r\ntiny\r");
    }
    const stats = read(temp.dir, path, 64 * mib);
    try std.testing.expectEqual(.ok, stats.stats_status);
    try std.testing.expectEqual(@as(?u64, mib + 6), stats.byte_count);
    try std.testing.expectEqual(@as(?u64, 2), stats.line_count);
    try std.testing.expectEqual(@as(?u64, mib - 1), stats.max_line_bytes);
    try std.testing.expectEqual(@as(?u64, mib + 4), stats.content_byte_count);
    try std.testing.expectEqual(@as(?f64, (mib + 4) / 2), stats.mean_line_bytes);
    try std.testing.expectEqual(LineSizeCounts{ .@"1-80" = 1, .@"65537+" = 1 }, stats.line_size_counts.?);
}
