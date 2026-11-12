const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

/// Each entry holds the other side of one edit. Undo and redo swap buffers,
/// including cursor and newline metadata, without allocating.
pub const History = struct {
    items: std.ArrayList(Buffer) = .empty,
    position: usize = 0,
    saved_position: ?usize = 0,
    grouping: bool = false,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.items.items) |*buffer| buffer.deinit(allocator);
        self.items.deinit(allocator);
    }

    /// Call immediately before an edit that changes bytes. Consecutive edits
    /// belong to this undo step until endChange is called.
    pub fn beginChange(self: *History, allocator: std.mem.Allocator, buffer: *const Buffer) !void {
        if (self.grouping) return;
        var snapshot = buffer.*;
        snapshot.bytes = .fromOwnedSlice(try allocator.dupe(u8, buffer.bytes.items));
        errdefer snapshot.deinit(allocator);
        try self.items.ensureTotalCapacity(allocator, self.position + 1);

        for (self.items.items[self.position..]) |*discarded| discarded.deinit(allocator);
        self.items.shrinkRetainingCapacity(self.position);
        if (self.saved_position) |saved| {
            if (saved > self.position) self.saved_position = null;
        }
        self.items.appendAssumeCapacity(snapshot);
        self.position += 1;
        self.grouping = true;
    }

    pub fn endChange(self: *History) void {
        self.grouping = false;
    }

    pub fn undo(self: *History, buffer: *Buffer) bool {
        self.endChange();
        if (self.position == 0) return false;
        self.position -= 1;
        std.mem.swap(Buffer, buffer, &self.items.items[self.position]);
        return true;
    }

    pub fn redo(self: *History, buffer: *Buffer) bool {
        self.endChange();
        if (self.position == self.items.items.len) return false;
        std.mem.swap(Buffer, buffer, &self.items.items[self.position]);
        self.position += 1;
        return true;
    }

    pub fn isDirty(self: *const History) bool {
        return self.saved_position == null or self.position != self.saved_position.?;
    }

    pub fn markSaved(self: *History) void {
        self.endChange();
        self.saved_position = self.position;
    }
};

fn testingBuffer(text: []const u8) !Buffer {
    return Buffer.init(.fromOwnedSlice(try std.testing.allocator.dupe(u8, text)));
}

test "grouped undo and redo restore bytes cursor line metadata and newline style" {
    const allocator = std.testing.allocator;
    var buffer = try testingBuffer("a\r\né");
    defer buffer.deinit(allocator);
    var history: History = .{};
    defer history.deinit(allocator);
    buffer.setCursor(3);
    buffer.preferred_column = 2;

    try history.beginChange(allocator, &buffer);
    try buffer.insert(allocator, "🙂");
    try history.beginChange(allocator, &buffer);
    try buffer.insertNewline(allocator);
    try std.testing.expectEqual(@as(usize, 1), history.items.items.len);
    try std.testing.expect(history.isDirty());
    try std.testing.expect(history.undo(&buffer));
    try std.testing.expectEqualStrings("a\r\né", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 3), buffer.cursor);
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), buffer.line_count);
    try std.testing.expectEqual(@as(?usize, 2), buffer.preferred_column);
    try std.testing.expectEqualStrings("\r\n", buffer.newline);
    try std.testing.expect(!history.isDirty());
    try std.testing.expect(!history.undo(&buffer));

    try std.testing.expect(history.redo(&buffer));
    try std.testing.expectEqualStrings("a\r\n🙂\r\né", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 9), buffer.cursor);
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), buffer.line_count);
    try std.testing.expect(!history.redo(&buffer));
}

test "separate edits retain saved states across undo redo and branches" {
    const allocator = std.testing.allocator;
    var buffer = try testingBuffer("");
    defer buffer.deinit(allocator);
    var history: History = .{};
    defer history.deinit(allocator);

    try history.beginChange(allocator, &buffer);
    try buffer.insert(allocator, "a");
    history.markSaved();
    try std.testing.expect(!history.isDirty());
    try history.beginChange(allocator, &buffer);
    try buffer.insert(allocator, "b");
    history.endChange();
    try std.testing.expect(history.isDirty());
    try std.testing.expect(history.undo(&buffer));
    try std.testing.expect(!history.isDirty());
    try std.testing.expectEqualStrings("a", buffer.bytes.items);
    try std.testing.expect(history.undo(&buffer));
    try std.testing.expect(history.isDirty());

    // Replacing the branch containing the saved version must not accidentally
    // mark the new edit clean merely because it has the same history index.
    try history.beginChange(allocator, &buffer);
    try buffer.insert(allocator, "c");
    history.endChange();
    try std.testing.expect(history.isDirty());
    try std.testing.expectEqual(@as(?usize, null), history.saved_position);
    try std.testing.expect(!history.redo(&buffer));
    history.markSaved();
    try std.testing.expect(!history.isDirty());
    try std.testing.expect(history.undo(&buffer));
    try std.testing.expect(history.isDirty());
    try std.testing.expect(history.redo(&buffer));
    try std.testing.expect(!history.isDirty());
    try std.testing.expectEqualStrings("c", buffer.bytes.items);
}

test "failed snapshot leaves the buffer redo branch and saved marker intact" {
    const allocator = std.testing.allocator;
    var buffer = try testingBuffer("original");
    defer buffer.deinit(allocator);
    var history: History = .{};
    defer history.deinit(allocator);
    try history.beginChange(allocator, &buffer);
    try buffer.insert(allocator, "edited ");
    history.markSaved();
    try std.testing.expect(history.undo(&buffer));

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, history.beginChange(failing.allocator(), &buffer));
    try std.testing.expectEqualStrings("original", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), history.position);
    try std.testing.expectEqual(@as(?usize, 1), history.saved_position);
    try std.testing.expect(history.redo(&buffer));
    try std.testing.expectEqualStrings("edited original", buffer.bytes.items);
    try std.testing.expect(!history.isDirty());
}
