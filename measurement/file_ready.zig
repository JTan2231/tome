const std = @import("std");
const Workspace = @import("content").Workspace;

pub const Cache = enum { hit, miss, cached_error };
pub const Outcome = union(enum) { ready, failed: anyerror };

pub const Sample = struct {
    index: usize,
    elapsed_ns: u64,
    cache: Cache,
    byte_count: ?usize,
    is_new: ?bool,
    outcome: Outcome,
};

/// Measure one complete-file request using the editor's production boundary.
/// The caller owns the workspace and supplies a valid entry index. Discovery,
/// result formatting, and rendering are outside the interval; cache lookup,
/// loading, required metadata preparation, and eviction are inside it.
/// File errors are samples. A clock error prevents a request and is returned.
pub fn measure(workspace: *Workspace, index: usize) !Sample {
    var timer = try std.time.Timer.start();
    const entry = &workspace.entries.items[index];
    const cache: Cache = if (entry.load_error != null)
        .cached_error
    else if (entry.document != null)
        .hit
    else
        .miss;

    const document = workspace.ensure(index) catch |err| {
        const elapsed_ns = timer.read();
        return .{
            .index = index,
            .elapsed_ns = elapsed_ns,
            .cache = cache,
            .byte_count = null,
            .is_new = null,
            .outcome = .{ .failed = err },
        };
    };
    const elapsed_ns = timer.read();
    return .{
        .index = index,
        .elapsed_ns = elapsed_ns,
        .cache = cache,
        .byte_count = document.buffer.bytes.items.len,
        .is_new = document.is_new,
        .outcome = .ready,
    };
}

test "requests measure production preparation and distinguish resident hits" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const text = "first\r\n\t界\r\n";
    try temp.dir.writeFile(.{ .sub_path = "file", .data = text });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();

    const first = try measure(&workspace, 0);
    try std.testing.expectEqual(Cache.miss, first.cache);
    try std.testing.expect(first.outcome == .ready);
    try std.testing.expectEqual(@as(?usize, text.len), first.byte_count);
    try std.testing.expectEqual(@as(?bool, false), first.is_new);
    try std.testing.expectEqual(@as(?usize, 3), workspace.entries.items[0].line_count);
    try std.testing.expectEqualStrings("\r\n", workspace.entries.items[0].document.?.buffer.newline);
    const document = workspace.entries.items[0].document.?;

    const second = try measure(&workspace, 0);
    try std.testing.expectEqual(Cache.hit, second.cache);
    try std.testing.expect(second.outcome == .ready);
    try std.testing.expectEqual(first.byte_count, second.byte_count);
    try std.testing.expect(document == workspace.entries.items[0].document.?);
}

test "failed and remembered failed requests are samples with unknown size" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "removed", .data = "contents" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    try temp.dir.deleteFile("removed");

    const first = try measure(&workspace, 0);
    try std.testing.expectEqual(Cache.miss, first.cache);
    try std.testing.expectEqual(error.FileNotFound, first.outcome.failed);
    try std.testing.expect(first.byte_count == null);
    try std.testing.expect(first.is_new == null);
    const second = try measure(&workspace, 0);
    try std.testing.expectEqual(Cache.cached_error, second.cache);
    try std.testing.expectEqual(error.FileNotFound, second.outcome.failed);
    try std.testing.expect(second.byte_count == null);
}

test "empty existing and new files are ready zero-byte samples" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "empty", .data = "" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const new_path = try std.fs.path.join(std.testing.allocator, &.{ root, "new" });
    defer std.testing.allocator.free(new_path);
    var workspace = try Workspace.open(std.testing.allocator, root, new_path);
    defer workspace.deinit();

    const existing = try measure(&workspace, 0);
    const created = try measure(&workspace, workspace.initial_index);
    for ([_]Sample{ existing, created }) |sample| {
        try std.testing.expectEqual(Cache.miss, sample.cache);
        try std.testing.expect(sample.outcome == .ready);
        try std.testing.expectEqual(@as(?usize, 0), sample.byte_count);
        try std.testing.expectEqual(@as(?usize, 1), workspace.entries.items[sample.index].line_count);
    }
    try std.testing.expectEqual(@as(?bool, false), existing.is_new);
    try std.testing.expectEqual(@as(?bool, true), created.is_new);
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile("new"));
}
