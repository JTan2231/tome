const std = @import("std");
const common = @import("common.zig");

pub const generator_version = 1;
const chunk_bytes = 64 * 1024;
const scalar = "界";

pub const Recipe = struct {
    byte_count: usize,
    line_bytes: ?usize = 80,
    newline: enum { lf, crlf } = .lf,
    final_newline: bool = true,
    content: Content = .ascii,
    outlier_position: ?OutlierPosition = null,

    fn newlineBytes(recipe: Recipe) []const u8 {
        return switch (recipe.newline) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

const Content = enum { ascii, utf8 };
const OutlierPosition = enum { beginning, middle, end };

pub const Metadata = struct {
    generator_version: usize,
    recipe: Recipe,
    byte_count: usize,
    newline_count: usize,
    line_count: usize,
    max_line_bytes: usize,
    final_newline: bool,
    sha256: [64]u8,
};

const FixtureWriter = struct {
    file: std.fs.File,
    newline_bytes: []const u8,
    kind: Content,
    digest: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    buffer: [chunk_bytes]u8 = undefined,
    byte_count: usize = 0,
    newline_count: usize = 0,
    current_line_bytes: usize = 0,
    max_line_bytes: usize = 0,
    final_newline: bool = false,

    fn raw(writer: *FixtureWriter, bytes: []const u8) !void {
        try common.checkInterrupted();
        try writer.file.writeAll(bytes);
        writer.digest.update(bytes);
        writer.byte_count += bytes.len;
    }

    fn fillContent(kind: Content, bytes: []u8) void {
        @memset(bytes, 'x');
        if (kind == .utf8) {
            for (0..bytes.len / scalar.len) |index| {
                @memcpy(bytes[index * scalar.len ..][0..scalar.len], scalar);
            }
        }
    }

    fn writeContent(writer: *FixtureWriter, length: usize) !void {
        // Keep whole UTF-8 scalars in every full chunk.
        const chunk_size = chunk_bytes - chunk_bytes % scalar.len;
        var remaining = length;
        if (remaining >= chunk_size) {
            fillContent(writer.kind, writer.buffer[0..chunk_size]);
            while (remaining >= chunk_size) : (remaining -= chunk_size) {
                try writer.raw(writer.buffer[0..chunk_size]);
            }
        }
        if (remaining > 0) {
            fillContent(writer.kind, writer.buffer[0..remaining]);
            try writer.raw(writer.buffer[0..remaining]);
        }
        writer.current_line_bytes += length;
        writer.max_line_bytes = @max(writer.max_line_bytes, writer.current_line_bytes);
        if (length > 0) writer.final_newline = false;
    }

    fn newline(writer: *FixtureWriter) !void {
        try writer.raw(writer.newline_bytes);
        writer.newline_count += 1;
        writer.current_line_bytes = 0;
        writer.final_newline = true;
    }

    fn records(writer: *FixtureWriter, line_bytes: usize, count: usize) !void {
        if (count == 0) return;
        const record_size = line_bytes + writer.newline_bytes.len;
        if (record_size > chunk_bytes) {
            for (0..count) |_| {
                try writer.writeContent(line_bytes);
                try writer.newline();
            }
            return;
        }

        const batch_size = @min(count, chunk_bytes / record_size);
        fillContent(writer.kind, writer.buffer[0..line_bytes]);
        @memcpy(writer.buffer[line_bytes..record_size], writer.newline_bytes);
        for (1..batch_size) |index| {
            @memcpy(writer.buffer[index * record_size ..][0..record_size], writer.buffer[0..record_size]);
        }
        var remaining = count;
        while (remaining >= batch_size) : (remaining -= batch_size) {
            try writer.raw(writer.buffer[0 .. batch_size * record_size]);
        }
        if (remaining > 0) try writer.raw(writer.buffer[0 .. remaining * record_size]);
        writer.max_line_bytes = @max(writer.max_line_bytes, writer.current_line_bytes + line_bytes);
        writer.current_line_bytes = 0;
        writer.newline_count += count;
        writer.final_newline = true;
    }

    fn regular(writer: *FixtureWriter, size: usize, line_bytes: usize, final_newline: bool) !void {
        if (size == 0) return;
        // Reserve a terminal newline, or one content byte to prevent one.
        const suffix = if (final_newline) writer.newline_bytes.len else 1;
        const body = size - suffix;
        const record_size = line_bytes +| writer.newline_bytes.len;
        try writer.records(line_bytes, body / record_size);
        try writer.writeContent(body % record_size + if (final_newline) @as(usize, 0) else 1);
        if (final_newline) try writer.newline();
    }
};

/// Write exactly recipe.byte_count bytes. A null line width makes one line.
/// Ordinary and maximum line lengths exclude LF or CRLF.
pub fn generate(directory: std.fs.Dir, filename: []const u8, recipe: Recipe) !Metadata {
    const newline = recipe.newlineBytes();
    if (recipe.line_bytes != null and recipe.final_newline and
        recipe.byte_count > 0 and recipe.byte_count < newline.len)
    {
        return error.FixtureTooSmallForFinalNewline;
    }
    if (recipe.outlier_position != null and (recipe.byte_count < 1024 or recipe.line_bytes == null)) {
        return error.InvalidFixtureOutlier;
    }

    const file = try directory.createFile(filename, .{});
    defer file.close();
    var writer: FixtureWriter = .{ .file = file, .newline_bytes = newline, .kind = recipe.content };
    if (recipe.line_bytes) |line_bytes| {
        if (recipe.outlier_position) |position| {
            const outlier_bytes = recipe.byte_count / 2;
            const outlier_newline = position != .end or recipe.final_newline;
            const remaining = recipe.byte_count - outlier_bytes - if (outlier_newline) newline.len else 0;
            const before = switch (position) {
                .beginning => 0,
                .middle => remaining / 2,
                .end => remaining,
            };
            try writer.regular(before, line_bytes, true);
            try writer.writeContent(outlier_bytes);
            if (outlier_newline) try writer.newline();
            try writer.regular(remaining - before, line_bytes, recipe.final_newline);
        } else {
            try writer.regular(recipe.byte_count, line_bytes, recipe.final_newline);
        }
    } else {
        try writer.writeContent(recipe.byte_count);
    }

    return .{
        .generator_version = generator_version,
        .recipe = recipe,
        .byte_count = writer.byte_count,
        .newline_count = writer.newline_count,
        .line_count = writer.newline_count + 1,
        .max_line_bytes = writer.max_line_bytes,
        .final_newline = writer.final_newline,
        .sha256 = std.fmt.bytesToHex(writer.digest.finalResult(), .lower),
    };
}

fn checkRecipe(directory: std.fs.Dir, recipe: Recipe) !Metadata {
    const metadata = try generate(directory, "input", recipe);
    const data = try directory.readFileAlloc(std.testing.allocator, "input", recipe.byte_count + 1);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(recipe.byte_count, data.len);
    try std.testing.expectEqual(metadata.byte_count, data.len);
    try std.testing.expectEqual(metadata.newline_count, std.mem.count(u8, data, "\n"));
    try std.testing.expectEqual(metadata.line_count, metadata.newline_count + 1);
    try std.testing.expectEqual(metadata.final_newline, std.mem.endsWith(u8, data, recipe.newlineBytes()));
    try std.testing.expect(std.unicode.utf8ValidateSlice(data));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    try std.testing.expectEqual(std.fmt.bytesToHex(digest, .lower), metadata.sha256);
    var lines = std.mem.splitSequence(u8, data, recipe.newlineBytes());
    var max_line_bytes: usize = 0;
    while (lines.next()) |line| {
        try std.testing.expect(std.mem.indexOfAny(u8, line, "\r\n") == null);
        max_line_bytes = @max(max_line_bytes, line.len);
    }
    try std.testing.expectEqual(max_line_bytes, metadata.max_line_bytes);
    if (recipe.line_bytes == null) {
        try std.testing.expectEqual(@as(usize, 1), metadata.line_count);
    } else if (data.len > 0) {
        try std.testing.expectEqual(recipe.final_newline, metadata.final_newline);
    }
    return metadata;
}

test "readiness fixture recipes preserve exact sizes, line endings and UTF-8" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_]bool{ false, true }) |final_newline| {
        for ([_]Content{ .ascii, .utf8 }) |kind| {
            for ([_]?usize{ 0, 1, 80, 4096, null }) |width| {
                for ([_]usize{ 0, 2, 3, 79, 80, 81, 82, 163, chunk_bytes + 5 }) |size| {
                    const recipe: Recipe = .{
                        .byte_count = size,
                        .line_bytes = width,
                        .final_newline = final_newline,
                        .content = kind,
                    };
                    _ = try checkRecipe(temp.dir, recipe);
                    var crlf = recipe;
                    crlf.newline = .crlf;
                    _ = try checkRecipe(temp.dir, crlf);
                }
            }
        }
    }
    _ = try checkRecipe(temp.dir, .{
        .byte_count = chunk_bytes * 5 + 7,
        .line_bytes = chunk_bytes + 11,
        .newline = .crlf,
        .content = .utf8,
    });
}

test "readiness fixtures write one deterministic outlier in the requested region" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var recipe: Recipe = .{ .byte_count = 100_003, .newline = .crlf, .content = .utf8 };
    for ([_]OutlierPosition{ .beginning, .middle, .end }) |position| {
        for ([_]bool{ false, true }) |final_newline| {
            recipe.outlier_position = position;
            recipe.final_newline = final_newline;
            const metadata = try checkRecipe(temp.dir, recipe);
            const data = try temp.dir.readFileAlloc(std.testing.allocator, "input", recipe.byte_count + 1);
            defer std.testing.allocator.free(data);
            var lines = std.mem.splitSequence(u8, data, recipe.newlineBytes());
            var index: usize = 0;
            var outlier: ?usize = null;
            while (lines.next()) |line| : (index += 1) {
                if (line.len <= 100) continue;
                try std.testing.expect(outlier == null);
                try std.testing.expectEqual(recipe.byte_count / 2, line.len);
                outlier = index;
            }
            const last = metadata.line_count - if (final_newline) @as(usize, 2) else 1;
            switch (position) {
                .beginning => try std.testing.expectEqual(@as(usize, 0), outlier.?),
                .middle => try std.testing.expect(outlier.? > 0 and outlier.? < last),
                .end => try std.testing.expectEqual(last, outlier.?),
            }
            try std.testing.expectEqual(metadata, try generate(temp.dir, "input", recipe));
        }
    }
}

test "invalid readiness fixture recipes do not create a file" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try std.testing.expectError(error.FixtureTooSmallForFinalNewline, generate(temp.dir, "input", .{
        .byte_count = 1,
        .newline = .crlf,
    }));
    try std.testing.expectError(error.InvalidFixtureOutlier, generate(temp.dir, "input", .{
        .byte_count = 10,
        .outlier_position = .beginning,
    }));
    try std.testing.expectError(error.InvalidFixtureOutlier, generate(temp.dir, "input", .{
        .byte_count = 1024,
        .line_bytes = null,
        .outlier_position = .middle,
    }));
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile("input"));
}
