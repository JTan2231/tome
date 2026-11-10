const std = @import("std");
const Workspace = @import("content").Workspace;
const Document = @import("content").Document;

/// A separator belongs to the file above it, but is never an editing position.
pub const Row = struct {
    file: usize,
    start: usize = 0,
    gap: bool = false,
    // A line end found while rendering, reused for the next forward step.
    // Rows are local to one traversal; never retain this across buffer edits.
    end: ?usize = null,
};

pub const Stream = struct {
    workspace: *Workspace,

    pub fn init(workspace: *Workspace) Stream {
        return .{ .workspace = workspace };
    }

    fn load(self: *Stream, file: usize) !?*Document {
        return self.workspace.ensure(file) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
    }

    /// Probe only enough files to decide whether content exceeds the viewport.
    /// Cached counts allow redraws without reloading distant clean buffers.
    pub fn canWrap(self: *Stream, height: usize) !bool {
        var lines: usize = 0;
        const first = self.workspace.active_index orelse 0;
        const entries = self.workspace.entries.items;
        for (0..entries.len) |offset| {
            const file = (first + offset) % entries.len;
            if (entries[file].load_error != null) continue;
            if (entries[file].line_count == null) _ = try self.load(file);
            lines +|= entries[file].line_count orelse 0;
            if (lines > height) return true;
        }
        return false;
    }

    /// Return the next readable file, skipping failed opens in either direction.
    pub fn adjacent(self: *Stream, file: usize, forward: bool, wrap: bool) !?usize {
        const count = self.workspace.entries.items.len;
        if (count == 0) return null;
        var candidate = file;
        for (0..count) |_| {
            if (forward) {
                if (candidate + 1 == count) {
                    if (!wrap) return null;
                    candidate = 0;
                } else candidate += 1;
            } else {
                if (candidate == 0) {
                    if (!wrap) return null;
                    candidate = count - 1;
                } else candidate -= 1;
            }
            if (try self.load(candidate) != null) return candidate;
        }
        return null;
    }

    pub fn step(self: *Stream, row: Row, forward: bool, wrap: bool) !?Row {
        if (self.workspace.entries.items.len == 0) return null;
        if (row.gap) {
            if (forward) {
                const next = try self.adjacent(row.file, true, wrap) orelse return null;
                return .{ .file = next };
            }
            const document = try self.load(row.file) orelse return null;
            return .{ .file = row.file, .start = document.buffer.lineStart(document.buffer.bytes.items.len) };
        }
        const document = try self.load(row.file) orelse return null;
        const buffer = &document.buffer;
        const start = buffer.lineStart(@min(row.start, buffer.bytes.items.len));
        if (forward) {
            const end = row.end orelse buffer.lineEnd(start);
            if (end < buffer.bytes.items.len) return .{ .file = row.file, .start = buffer.nextIndex(end) };
            if (try self.adjacent(row.file, true, wrap) == null) return null;
            return .{ .file = row.file, .gap = true };
        }
        if (start != 0) return .{ .file = row.file, .start = buffer.lineStart(buffer.previousIndex(start)) };
        const previous = try self.adjacent(row.file, false, wrap) orelse return null;
        return .{ .file = previous, .gap = true };
    }
};

test "file traversal preserves CRLF lines and separates files in both directions" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one\r\ntwo" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "three" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var stream = Stream.init(&workspace);
    const rows = [_]Row{
        .{ .file = 0 },
        .{ .file = 0, .start = 5 },
        .{ .file = 0, .gap = true },
        .{ .file = 1 },
    };
    for (rows[0 .. rows.len - 1], rows[1..]) |a, b| {
        try std.testing.expectEqualDeep(b, (try stream.step(a, true, false)).?);
        try std.testing.expectEqualDeep(a, (try stream.step(b, false, false)).?);
    }
    try std.testing.expect(try stream.step(rows[0], false, false) == null);
    try std.testing.expect(try stream.step(rows[rows.len - 1], true, false) == null);
}

test "short workspaces stay finite and long content wraps after a separator" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var stream = Stream.init(&workspace);
    try std.testing.expect(!try stream.canWrap(2));
    try std.testing.expect(try stream.step(.{ .file = 0 }, true, false) == null);
    const doc = try workspace.ensure(0);
    try doc.buffer.insert(std.testing.allocator, "a\nb\n");
    workspace.markDirty(0);
    try std.testing.expect(try stream.canWrap(2));
    try std.testing.expect(!try stream.canWrap(3));
    const last = Row{ .file = 0, .start = 4 };
    const gap = Row{ .file = 0, .gap = true };
    try std.testing.expectEqualDeep(gap, (try stream.step(last, true, true)).?);
    try std.testing.expectEqualDeep(Row{ .file = 0 }, (try stream.step(gap, true, true)).?);
    try std.testing.expectEqualDeep(gap, (try stream.step(.{ .file = 0 }, false, true)).?);
    try std.testing.expectEqualDeep(last, (try stream.step(gap, false, true)).?);
}

test "large files are skipped without loading their contents" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "a" });
    const huge = try temp.dir.createFile("b", .{});
    try huge.setEndPos(@import("content").max_file_size + 1);
    huge.close();
    try temp.dir.writeFile(.{ .sub_path = "c", .data = "c" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var stream = Stream.init(&workspace);
    try std.testing.expectEqual(@as(?usize, 2), try stream.adjacent(0, true, false));
    try std.testing.expectEqual(@as(?usize, 0), try stream.adjacent(2, false, false));
    try std.testing.expect(workspace.entries.items[1].document == null);
    try std.testing.expectEqual(error.FileTooBig, workspace.entries.items[1].load_error.?);
    try std.testing.expect(!try stream.canWrap(2));
    try std.testing.expect(try stream.canWrap(1));
}

test "wrap probing starts near the cursor and leaves distant files unloaded" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "distant" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "one\ntwo\nthree" });
    try temp.dir.writeFile(.{ .sub_path = "c", .data = "distant" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    workspace.active_index = 1;
    var stream = Stream.init(&workspace);
    try std.testing.expect(try stream.canWrap(2));
    try std.testing.expect(workspace.entries.items[0].document == null);
    try std.testing.expect(workspace.entries.items[1].document != null);
    try std.testing.expect(workspace.entries.items[2].document == null);
}

test "empty directories have no rows and cannot wrap" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var stream = Stream.init(&workspace);
    try std.testing.expect(!try stream.canWrap(22));
    try std.testing.expect(try stream.adjacent(0, true, true) == null);
    try std.testing.expect(try stream.step(.{ .file = 0 }, true, true) == null);
}
