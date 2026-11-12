const std = @import("std");
const content = @import("content");
const display = @import("display.zig");
const terminal = @import("terminal.zig");

const Match = content.workspace_search.Match;

pub const Picker = struct {
    kind: Kind,
    query: std.ArrayList(u8) = .empty,
    files: std.ArrayList(usize) = .empty,
    items: std.ArrayList(Match) = .empty,
    selection: usize = 0,
    top: usize = 0,
    height: usize = 1,
    paste_start: ?usize = null,
    searching: bool = false,
    search_failed: bool = false,

    pub const Kind = enum { files, search };
    pub const Action = enum { none, query_changed, close, select };

    pub fn deinit(self: *Picker, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.files.deinit(allocator);
        self.query.deinit(allocator);
    }

    pub fn selected(self: *const Picker) ?Match {
        return if (self.items.items.len == 0) null else self.items.items[self.selection];
    }

    pub fn resetResults(self: *Picker) void {
        self.items.clearRetainingCapacity();
        self.selection = 0;
        self.top = 0;
    }

    pub fn filterFiles(self: *Picker, allocator: std.mem.Allocator, entries: []const content.WorkspaceEntry) !void {
        self.resetResults();
        for (self.files.items) |file| {
            if (std.ascii.indexOfIgnoreCase(entries[file].name, self.query.items) != null) {
                try self.items.append(allocator, .{ .file = file, .offset = 0, .row = 0, .column = 0, .revision = null });
            }
        }
    }

    pub fn handle(self: *Picker, allocator: std.mem.Allocator, key: terminal.Key) !Action {
        const query_limit: usize = if (self.kind == .search) content.search.max_query_size else std.fs.max_path_bytes;
        if (self.paste_start) |start| {
            switch (key) {
                .paste_end => {
                    self.paste_start = null;
                    // Pasting emits raw bytes. Keep complete scalars when
                    // the input limit cuts a multibyte character short.
                    const pasted = self.query.items[start..];
                    var valid: usize = 0;
                    while (valid < pasted.len) {
                        const len = std.unicode.utf8ByteSequenceLength(pasted[valid]) catch break;
                        if (len > pasted.len - valid) break;
                        _ = std.unicode.utf8Decode(pasted[valid..][0..len]) catch break;
                        valid += len;
                    }
                    self.query.shrinkRetainingCapacity(start + valid);
                    if (self.query.items.len != start) return .query_changed;
                },
                .byte => |byte| if (byte >= ' ' and byte != 127 and self.query.items.len < query_limit) {
                    try self.query.append(allocator, byte);
                },
                else => {},
            }
            return .none;
        }
        const last = self.items.items.len -| 1;
        switch (key) {
            .escape => return .close,
            .up => self.selection -|= 1,
            .down => self.selection = @min(self.selection + 1, last),
            .page_up => self.selection -|= self.height,
            .page_down => self.selection = @min(self.selection + self.height, last),
            .home => self.selection = 0,
            .end => self.selection = last,
            .paste_start => self.paste_start = self.query.items.len,
            .byte => |byte| switch (byte) {
                '\r', '\n' => return .select,
                0x10 => self.selection -|= 1, // Ctrl+P
                0x0e => self.selection = @min(self.selection + 1, last), // Ctrl+N
                0x15 => self.selection -|= @max(self.height / 2, 1), // Ctrl+U
                0x04 => self.selection = @min(self.selection + @max(self.height / 2, 1), last), // Ctrl+D
                8, 127 => {
                    if (self.query.items.len == 0) return .none;
                    var end = self.query.items.len - 1;
                    while (end > 0 and self.query.items[end] & 0xc0 == 0x80) end -= 1;
                    self.query.shrinkRetainingCapacity(end);
                    return .query_changed;
                },
                0x17 => {
                    if (self.query.items.len == 0) return .none;
                    self.query.shrinkRetainingCapacity(content.Buffer.previousWordStart(self.query.items, self.query.items.len));
                    return .query_changed;
                },
                32...126 => {
                    if (self.query.items.len == query_limit) return .none;
                    try self.query.append(allocator, byte);
                    return .query_changed;
                },
                else => {},
            },
            .text => |text| {
                if (self.query.items.len + text.len > query_limit) return .none;
                try self.query.appendSlice(allocator, text.bytes[0..text.len]);
                return .query_changed;
            },
            else => {},
        }
        self.revealSelection();
        return .none;
    }

    fn revealSelection(self: *Picker) void {
        self.top = @min(self.top, self.items.items.len -| self.height);
        if (self.selection < self.top) self.top = self.selection;
        if (self.selection - self.top >= self.height) self.top = self.selection - self.height + 1;
    }

    pub fn render(self: *Picker, allocator: std.mem.Allocator, frame: *std.ArrayList(u8), size: terminal.Size, entries: []const content.WorkspaceEntry) !void {
        const writer = frame.writer(allocator);
        frame.clearRetainingCapacity();
        try writer.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m\x1b[H\x1b[2J");
        if (size.rows < 3 or size.cols < 2) {
            self.height = 1;
            try writer.writeAll("\x1b[?2026l");
            return;
        }

        self.height = size.rows - 2;
        self.revealSelection();
        const prompt = if (self.kind == .files) "Files> " else "Search> ";
        const prompt_width = @min(prompt.len, size.cols - 1);
        try writer.writeAll(prompt[0..prompt_width]);
        const query_width = size.cols - prompt_width - 1;
        const columns = display.columns(self.query.items);
        try writeText(writer, self.query.items, columns -| query_width, query_width);

        const visible = self.items.items[self.top..][0..@min(self.height, self.items.items.len - self.top)];
        for (visible, self.top..) |item, index| {
            try writer.print("\x1b[{d};1H", .{index - self.top + 2});
            if (index == self.selection) try writer.writeAll("\x1b[7m");
            var location: [48]u8 = undefined;
            const suffix = if (self.kind == .search)
                try std.fmt.bufPrint(&location, ":{d}:{d}", .{ item.row + 1, item.column + 1 })
            else
                "";
            try writeText(writer, entries[item.file].name, 0, size.cols -| suffix.len);
            try writeText(writer, suffix, 0, size.cols);
            if (index == self.selection) try writer.writeAll("\x1b[27m");
        }

        try writer.print("\x1b[{d};1H\x1b[90m", .{size.rows});
        const help = "↑/↓ move   PgUp/PgDn page   Enter open   Esc back";
        const status = if (self.search_failed)
            " Search failed   "
        else if (self.searching)
            " Searching…   "
        else if (self.items.items.len == 0 and (self.kind == .files or self.query.items.len != 0))
            " No matches   "
        else
            " ";
        try writeText(writer, status, 0, size.cols);
        try writeText(writer, help, 0, size.cols -| display.columns(status));
        try writer.print("\x1b[0m\x1b[1;{d}H\x1b[6 q\x1b[?25h\x1b[?2026l", .{prompt_width + @min(columns, query_width) + 1});
    }
};

fn writeText(writer: anytype, bytes: []const u8, left: usize, width: usize) !void {
    if (width == 0) return;
    const right = left + width;
    var column: usize = 0;
    var index: usize = 0;
    var visible_base = false;
    while (index < bytes.len) {
        const unit = display.cell(bytes[index..], column);
        const end = column + unit.width;
        if (unit.width == 0) {
            if (visible_base) try writer.writeAll(bytes[index..][0..unit.len]);
        } else {
            if (column >= right) break;
            visible_base = false;
            if (end > left) {
                if (column < left or end > right or unit.kind == .tab) {
                    try writer.writeByteNTimes(' ', @min(end, right) - @max(column, left));
                } else {
                    switch (unit.kind) {
                        .text => try writer.writeAll(bytes[index..][0..unit.len]),
                        .control => try writer.writeAll(&.{ '^', if (bytes[index] == 127) '?' else bytes[index] + 64 }),
                        .replacement => try writer.writeAll("\xef\xbf\xbd"),
                        .tab => unreachable,
                    }
                    visible_base = unit.kind == .text;
                }
            }
        }
        index += unit.len;
        column = end;
    }
}

test "paging keeps the chosen search hit visible as results append" {
    const allocator = std.testing.allocator;
    var picker: Picker = .{ .kind = .search };
    defer picker.deinit(allocator);
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);
    var name = "src/bad\x1b[2J.zig".*;
    const entries = [_]content.WorkspaceEntry{.{ .name = &name, .path = &name }};
    const size: terminal.Size = .{ .rows = 4, .cols = 60 };

    for (0..4) |row| {
        try picker.items.append(allocator, .{ .file = 0, .offset = row * 10 + 5, .row = row, .column = 5, .revision = null });
    }
    try picker.render(allocator, &frame, size, &entries);
    _ = try picker.handle(allocator, .down);
    _ = try picker.handle(allocator, .page_down);
    const chosen = picker.selected().?;
    try std.testing.expectEqual(@as(usize, 3), chosen.row);

    try picker.items.append(allocator, .{ .file = 0, .offset = 45, .row = 4, .column = 5, .revision = null });
    try picker.render(allocator, &frame, size, &entries);
    try std.testing.expectEqual(chosen, picker.selected().?);
    try std.testing.expect(std.mem.indexOf(u8, frame.items, "\x1b[3;1H\x1b[7msrc/bad^[[2J.zig:4:6") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame.items, "\x1b[2J"));
}
