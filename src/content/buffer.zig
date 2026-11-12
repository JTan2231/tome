const std = @import("std");
const indentation = @import("indentation.zig");

pub const Buffer = struct {
    pub const max_indent_width = indentation.max_width;

    bytes: std.ArrayList(u8),
    cursor: usize = 0,
    // Number of LF bytes before cursor; maintained together with cursor.
    cursor_row: usize = 0,
    // Maintained with edits so rendering never needs to recount a whole file.
    line_count: usize = 1,
    preferred_column: ?usize = null,
    newline: []const u8,
    indent_style: indentation.Style,
    // The copied prefix of a new blank line. History snapshots can hold it too.
    auto_indent: ?struct { start: usize, end: usize } = null,

    pub fn init(bytes: std.ArrayList(u8)) Buffer {
        const first_lf = std.mem.indexOfScalar(u8, bytes.items, '\n') orelse 0;
        const crlf = first_lf > 0 and bytes.items[first_lf - 1] == '\r';
        return .{
            .bytes = bytes,
            .newline = if (crlf) "\r\n" else "\n",
            .indent_style = indentation.detect(bytes.items),
            .line_count = 1 + std.mem.count(u8, bytes.items, "\n"),
        };
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    pub fn lineStart(self: *const Buffer, index: usize) usize {
        const lf = std.mem.lastIndexOfScalar(u8, self.bytes.items[0..index], '\n') orelse return 0;
        return lf + 1;
    }

    pub fn lineEnd(self: *const Buffer, index: usize) usize {
        const bytes = self.bytes.items;
        const lf = std.mem.indexOfScalarPos(u8, bytes, index, '\n') orelse return bytes.len;
        return if (lf > 0 and bytes[lf - 1] == '\r') lf - 1 else lf;
    }

    // Move over one UTF-8 scalar, invalid byte, or newline.
    pub fn nextIndex(self: *const Buffer, index: usize) usize {
        const bytes = self.bytes.items;
        if (index == bytes.len) return index;
        if (bytes[index] == '\r' and index + 1 < bytes.len and bytes[index + 1] == '\n') {
            return index + 2;
        }
        if (bytes[index] < 0x80) return index + 1;

        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return index + 1;
        if (length > bytes.len - index) return index + 1;
        const end = index + length;
        _ = std.unicode.utf8Decode(bytes[index..end]) catch return index + 1;
        return end;
    }

    fn unitStart(self: *const Buffer, index: usize) usize {
        const bytes = self.bytes.items;
        if (bytes[index] == '\n' and index > 0 and bytes[index - 1] == '\r') return index - 1;
        if (bytes[index] & 0xc0 != 0x80) return index;

        var start = index;
        while (start > 0 and index - start < 3) {
            start -= 1;
            if (bytes[start] & 0xc0 != 0x80) {
                return if (self.nextIndex(start) > index) start else index;
            }
        }
        return index;
    }

    pub fn previousIndex(self: *const Buffer, index: usize) usize {
        std.debug.assert(index <= self.bytes.items.len);
        return if (index == 0) 0 else self.unitStart(index - 1);
    }

    pub fn previousWordStart(bytes: []const u8, end: usize) usize {
        std.debug.assert(end <= bytes.len);
        var index = end;
        while (index > 0 and std.ascii.isWhitespace(bytes[index - 1])) : (index -= 1) {}
        if (index == 0) return 0;
        const class = wordClass(bytes[index - 1]);
        while (index > 0 and wordClass(bytes[index - 1]) == class) : (index -= 1) {}
        return index;
    }

    pub fn nextWordStart(bytes: []const u8, start: usize) usize {
        std.debug.assert(start <= bytes.len);
        if (start == bytes.len) return start;
        var index = start;
        const class = wordClass(bytes[index]);
        while (index < bytes.len and wordClass(bytes[index]) == class) : (index += 1) {}
        while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) : (index += 1) {}
        return index;
    }

    fn wordClass(byte: u8) enum { whitespace, word, punctuation } {
        if (std.ascii.isWhitespace(byte)) return .whitespace;
        // Treat every byte of a UTF-8 scalar as part of the same word.
        if (byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_') return .word;
        return .punctuation;
    }

    pub fn setCursor(self: *Buffer, index: usize) void {
        std.debug.assert(index <= self.bytes.items.len);
        self.cursor_row = self.rowAt(index);
        self.cursor = index;
        self.repairCursor();
        self.preferred_column = null;
    }

    pub fn moveLeft(self: *Buffer) void {
        self.setCursor(self.previousIndex(self.cursor));
    }

    pub fn moveRight(self: *Buffer) void {
        self.setCursor(self.nextIndex(self.cursor));
    }

    pub fn moveUp(self: *Buffer) void {
        const start = self.lineStart(self.cursor);
        if (start > 0) {
            self.moveToLine(self.lineStart(self.unitStart(start - 1)));
            self.cursor_row -= 1;
        }
    }

    pub fn moveDown(self: *Buffer) void {
        self.moveDownFromEnd(self.lineEnd(self.cursor));
    }

    /// Move down using the already known end of the cursor's current line.
    pub fn moveDownFromEnd(self: *Buffer, end: usize) void {
        if (end < self.bytes.items.len) {
            self.moveToLine(self.nextIndex(end));
            self.cursor_row += 1;
        }
    }

    fn moveToLine(self: *Buffer, start: usize) void {
        const column = self.preferred_column orelse self.cursorColumn();
        self.preferred_column = column;
        self.cursor = start;
        for (0..column) |_| {
            if (self.cursor == self.bytes.items.len) break;
            const byte = self.bytes.items[self.cursor];
            if (byte == '\n' or (byte == '\r' and self.cursor + 1 < self.bytes.items.len and
                self.bytes.items[self.cursor + 1] == '\n')) break;
            self.cursor = self.nextIndex(self.cursor);
        }
    }

    pub fn cursorColumn(self: *const Buffer) usize {
        var index = self.lineStart(self.cursor);
        var column: usize = 0;
        while (index < self.cursor) : (column += 1) index = self.nextIndex(index);
        return column;
    }

    pub fn insert(self: *Buffer, allocator: std.mem.Allocator, text: []const u8) !void {
        const added_rows = std.mem.count(u8, text, "\n");
        try self.bytes.insertSlice(allocator, self.cursor, text);
        self.cursor += text.len;
        self.cursor_row += added_rows;
        self.line_count += added_rows;
        self.repairCursor();
        self.preferred_column = null;
    }

    pub fn replaceRange(self: *Buffer, allocator: std.mem.Allocator, start: usize, end: usize, text: []const u8) !void {
        std.debug.assert(start <= end and end <= self.bytes.items.len);
        const added_rows = std.mem.count(u8, text, "\n");
        const removed_rows = std.mem.count(u8, self.bytes.items[start..end], "\n");
        const row = self.rowAt(start) + added_rows;
        const removed = end - start;
        if (text.len > removed) try self.bytes.ensureUnusedCapacity(allocator, text.len - removed);
        self.bytes.replaceRangeAssumeCapacity(start, removed, text);
        self.cursor = start + text.len;
        self.cursor_row = row;
        self.line_count = self.line_count - removed_rows + added_rows;
        self.repairCursor();
        self.preferred_column = null;
    }

    pub fn insertNewline(self: *Buffer, allocator: std.mem.Allocator) !void {
        try self.insert(allocator, self.newline);
    }

    pub fn discardAutoIndent(self: *Buffer) void {
        const indent = self.auto_indent orelse return;
        const len = indent.end - indent.start;
        self.bytes.replaceRangeAssumeCapacity(indent.start, len, "");
        self.cursor -= @min(self.cursor -| indent.start, len);
        self.auto_indent = null;
    }

    pub fn moveHome(self: *Buffer) void {
        self.cursor = self.lineStart(self.cursor);
        self.preferred_column = null;
    }

    pub fn moveEnd(self: *Buffer) void {
        self.cursor = self.lineEnd(self.cursor);
        self.preferred_column = null;
    }

    pub fn deleteForward(self: *Buffer) bool {
        if (self.cursor == self.bytes.items.len) return false;
        const end = self.nextIndex(self.cursor);
        self.line_count -= std.mem.count(u8, self.bytes.items[self.cursor..end], "\n");
        self.bytes.replaceRangeAssumeCapacity(self.cursor, end - self.cursor, "");
        self.repairCursor();
        self.preferred_column = null;
        return true;
    }

    pub fn backspace(self: *Buffer) bool {
        if (self.cursor == 0) return false;
        const start = self.unitStart(self.cursor - 1);
        const removed_rows = std.mem.count(u8, self.bytes.items[start..self.cursor], "\n");
        self.cursor_row -= removed_rows;
        self.line_count -= removed_rows;
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor - start, "");
        self.cursor = start;
        // Joining the neighboring bytes can form a CRLF or UTF-8 scalar.
        self.repairCursor();
        self.preferred_column = null;
        return true;
    }

    fn repairCursor(self: *Buffer) void {
        if (self.cursor < self.bytes.items.len) {
            const start = self.unitStart(self.cursor);
            if (start < self.cursor) {
                const end = self.nextIndex(start);
                self.cursor_row += std.mem.count(u8, self.bytes.items[self.cursor..end], "\n");
                self.cursor = end;
            }
        }
    }

    fn rowAt(self: *const Buffer, index: usize) usize {
        return if (index >= self.cursor)
            self.cursor_row + std.mem.count(u8, self.bytes.items[self.cursor..index], "\n")
        else
            self.cursor_row - std.mem.count(u8, self.bytes.items[index..self.cursor], "\n");
    }
};

fn testingBuffer(text: []const u8) !Buffer {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(std.testing.allocator, text);
    return Buffer.init(bytes);
}

test "insert, split and join lines without inventing a final newline" {
    var buffer = try testingBuffer("hello");
    defer buffer.deinit(std.testing.allocator);
    buffer.setCursor(2);
    try buffer.insertNewline(std.testing.allocator);
    try std.testing.expectEqualStrings("he\nllo", buffer.bytes.items);
    try std.testing.expect(buffer.backspace());
    try std.testing.expectEqualStrings("hello", buffer.bytes.items);
    try std.testing.expect(buffer.deleteForward());
    try std.testing.expectEqualStrings("helo", buffer.bytes.items);
    buffer.setCursor(buffer.bytes.items.len);
    try std.testing.expect(!buffer.deleteForward());
    buffer.setCursor(0);
    try std.testing.expect(!buffer.backspace());
}

test "UTF-8 movement and deletion operate on whole scalars" {
    var buffer = try testingBuffer("aé🙂z");
    defer buffer.deinit(std.testing.allocator);
    buffer.moveRight();
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor);
    buffer.moveRight();
    try std.testing.expectEqual(@as(usize, 3), buffer.cursor);
    buffer.moveRight();
    try std.testing.expectEqual(@as(usize, 7), buffer.cursor);
    buffer.moveLeft();
    try std.testing.expectEqual(@as(usize, 3), buffer.cursor);
    try std.testing.expect(buffer.backspace());
    try std.testing.expectEqualStrings("a🙂z", buffer.bytes.items);
    try std.testing.expect(buffer.deleteForward());
    try std.testing.expectEqualStrings("az", buffer.bytes.items);
}

test "CRLF is one editable newline and new lines retain its style" {
    var buffer = try testingBuffer("ab\r\ncd\r\n");
    defer buffer.deinit(std.testing.allocator);
    buffer.moveEnd();
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    buffer.moveRight();
    try std.testing.expectEqual(@as(usize, 4), buffer.cursor);
    buffer.moveLeft();
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    try std.testing.expect(buffer.deleteForward());
    try std.testing.expectEqualStrings("abcd\r\n", buffer.bytes.items);
    try buffer.insertNewline(std.testing.allocator);
    try std.testing.expectEqualStrings("ab\r\ncd\r\n", buffer.bytes.items);
    try std.testing.expect(buffer.backspace());
    try std.testing.expectEqualStrings("abcd\r\n", buffer.bytes.items);
}

test "vertical movement remembers a column across shorter lines" {
    var buffer = try testingBuffer("abcd\nx\né🙂yz\n");
    defer buffer.deinit(std.testing.allocator);
    buffer.setCursor(3);
    buffer.moveDown();
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
    buffer.moveDown();
    try std.testing.expectEqual(@as(usize, 14), buffer.cursor);
    buffer.moveDown();
    try std.testing.expectEqual(buffer.bytes.items.len, buffer.cursor);
    buffer.moveUp();
    try std.testing.expectEqual(@as(usize, 14), buffer.cursor);
    buffer.moveUp();
    buffer.moveUp();
    try std.testing.expectEqual(@as(usize, 3), buffer.cursor);
}

test "invalid UTF-8 remains editable without losing unrelated bytes" {
    var buffer = try testingBuffer("\xff\x80a\xc3");
    defer buffer.deinit(std.testing.allocator);
    buffer.moveRight();
    buffer.moveRight();
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    try std.testing.expect(buffer.backspace());
    try std.testing.expectEqualSlices(u8, "\xffa\xc3", buffer.bytes.items);
    buffer.moveEnd();
    try std.testing.expect(buffer.backspace());
    try std.testing.expectEqualSlices(u8, "\xffa", buffer.bytes.items);
}

test "edits that join a scalar or CRLF keep the cursor on a boundary" {
    var buffer = try testingBuffer("\xc3x\xa9");
    defer buffer.deinit(std.testing.allocator);
    buffer.setCursor(2);
    try std.testing.expect(buffer.backspace());
    try std.testing.expectEqualStrings("é", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    buffer.moveHome();
    try std.testing.expect(buffer.deleteForward());
    try buffer.insert(std.testing.allocator, "\rx\n");
    buffer.setCursor(1);
    try std.testing.expect(buffer.deleteForward());
    try std.testing.expectEqualStrings("\r\n", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
}

test "range replacements preserve surrounding text and repair joined scalars and CRLF" {
    const allocator = std.testing.allocator;
    var buffer = try testingBuffer("a\xc3remove\xa9z");
    defer buffer.deinit(allocator);
    buffer.preferred_column = 4;
    try buffer.replaceRange(allocator, 2, 8, "");
    try std.testing.expectEqualStrings("aéz", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 3), buffer.cursor);
    try std.testing.expectEqual(@as(?usize, null), buffer.preferred_column);

    try buffer.replaceRange(allocator, 1, 3, "\rx\n");
    try std.testing.expectEqualStrings("a\rx\nz", buffer.bytes.items);
    try buffer.replaceRange(allocator, 2, 3, "");
    try std.testing.expectEqualStrings("a\r\nz", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 3), buffer.cursor);

    try buffer.replaceRange(allocator, 3, 3, "🙂");
    try std.testing.expectEqualStrings("a\r\n🙂z", buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 7), buffer.cursor);
}

test "cursor helpers respect scalar and newline boundaries" {
    var buffer = try testingBuffer("é\r\n🙂");
    defer buffer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), buffer.previousIndex(0));
    try std.testing.expectEqual(@as(usize, 0), buffer.previousIndex(2));
    try std.testing.expectEqual(@as(usize, 2), buffer.previousIndex(4));
    try std.testing.expectEqual(@as(usize, 4), buffer.previousIndex(8));
    buffer.setCursor(1);
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    buffer.setCursor(3);
    try std.testing.expectEqual(@as(usize, 4), buffer.cursor);
    buffer.setCursor(6);
    try std.testing.expectEqual(@as(usize, 8), buffer.cursor);
}

fn expectCursorRow(buffer: *const Buffer) !void {
    try std.testing.expectEqual(std.mem.count(u8, buffer.bytes.items[0..buffer.cursor], "\n"), buffer.cursor_row);
    try std.testing.expectEqual(1 + std.mem.count(u8, buffer.bytes.items, "\n"), buffer.line_count);
}

test "cursor rows remain accurate across all movement and repaired byte positions" {
    var buffer = try testingBuffer("aé\r\nx\n🙂\xff\rzz\n");
    defer buffer.deinit(std.testing.allocator);
    const motions = [_]*const fn (*Buffer) void{
        Buffer.moveLeft, Buffer.moveRight, Buffer.moveUp,
        Buffer.moveDown, Buffer.moveHome,  Buffer.moveEnd,
    };
    for (0..buffer.bytes.items.len + 1) |position| {
        buffer.setCursor(position);
        try expectCursorRow(&buffer);
        for (motions) |motion| {
            buffer.setCursor(position);
            motion(&buffer);
            try expectCursorRow(&buffer);
        }
        buffer.setCursor(position);
        buffer.moveDownFromEnd(buffer.lineEnd(buffer.cursor));
        try expectCursorRow(&buffer);
    }
}

test "cursor rows survive edits before and after the cursor and joined newlines" {
    const allocator = std.testing.allocator;
    const original = "a\r\nb\xc3x\xa9\nc\rx\n";
    const replacements = [_][]const u8{ "", "\n", "\r", "é\r\n", "\x80" };
    for ([_]usize{ 0, 5, original.len }) |position| {
        for (0..original.len + 1) |start| {
            for (start..original.len + 1) |end| {
                for (replacements) |replacement| {
                    var buffer = try testingBuffer(original);
                    defer buffer.deinit(allocator);
                    buffer.setCursor(position);
                    try buffer.replaceRange(allocator, start, end, replacement);
                    try expectCursorRow(&buffer);
                    try buffer.insert(allocator, replacement);
                    try expectCursorRow(&buffer);
                    _ = buffer.backspace();
                    try expectCursorRow(&buffer);
                    _ = buffer.deleteForward();
                    try expectCursorRow(&buffer);
                }
            }
        }
    }
}

test "failed growing edits preserve cursor position and row" {
    const original = "a\nb\r\nc";
    var storage: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(allocator, original);
    var buffer = Buffer.init(bytes);
    defer buffer.deinit(allocator);
    buffer.setCursor(original.len);
    buffer.preferred_column = 6;
    const text = [_]u8{'\n'} ** 4096;
    try std.testing.expectError(error.OutOfMemory, buffer.insert(allocator, &text));
    try std.testing.expectError(error.OutOfMemory, buffer.replaceRange(allocator, 0, 2, &text));
    try std.testing.expectEqualStrings(original, buffer.bytes.items);
    try std.testing.expectEqual(original.len, buffer.cursor);
    try std.testing.expectEqual(@as(?usize, 6), buffer.preferred_column);
    try expectCursorRow(&buffer);
}
