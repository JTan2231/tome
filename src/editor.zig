const std = @import("std");
const terminal = @import("terminal.zig");
const content = @import("content");
const display = @import("display.zig");
const Workspace = content.Workspace;
const Stream = @import("stream.zig").Stream;
const Row = @import("stream.zig").Row;
const search = content.search;

const Mode = enum { normal, insert, visual, visual_line };
const Operator = enum { yank, delete, change };
const Range = struct { start: usize, end: usize, linewise: bool = false };

pub const Editor = struct {
    allocator: std.mem.Allocator,
    document: *content.Document,
    filename: []const u8,
    workspace: ?*Workspace = null,
    stream: ?Stream = null,
    current_file: ?usize = null,
    owns_document: bool = false,
    screen_row: usize = 0,
    height: usize = 22,
    wrap: bool = false,
    transitions: usize = 0,
    mode: Mode = .normal,
    anchor: usize = 0,
    pending_operator: ?Operator = null,
    pending_g: bool = false,
    register: std.ArrayList(u8) = .empty,
    register_linewise: bool = false,
    register_valid: bool = false,
    dirty: bool = false,
    command_active: bool = false,
    command: std.ArrayList(u8) = .empty,
    search_prompt: bool = false,
    search_text: std.ArrayList(u8) = .empty,
    last_search: std.ArrayList(u8) = .empty,
    search_job: ?*search.Job = null,
    search_next: ?search.Options = null,
    search_accept: bool = false,
    document_revision: u64 = 0,
    background_redraw: bool = false,
    search_projection: ?search.Projection = null,
    projection_document: ?*content.Document = null,
    projection_revision: u64 = 0,
    frame: std.ArrayList(u8) = .empty,
    message: [512]u8 = undefined,
    message_len: usize = 0,
    left_column: usize = 0,
    pasting: bool = false,
    accept_paste: bool = false,
    paste_cr: bool = false,
    paste_origin_row: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, document: *content.Document, filename: []const u8) Editor {
        return .{ .allocator = allocator, .document = document, .filename = filename };
    }

    pub fn initWorkspace(allocator: std.mem.Allocator, workspace: *Workspace) !Editor {
        const stream = Stream.init(workspace);
        for (0..workspace.entries.items.len) |offset| {
            const index = (workspace.initial_index + offset) % workspace.entries.items.len;
            const document = workspace.ensure(index) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            workspace.active_index = index;
            var editor = Editor.init(allocator, document, workspace.entries.items[index].name);
            editor.workspace = workspace;
            editor.stream = stream;
            editor.current_file = index;
            return editor;
        }
        // An empty directory can be browsed and quit without inventing a file.
        const document = try allocator.create(content.Document);
        errdefer allocator.destroy(document);
        document.* = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, ""),
            .buffer = content.Buffer.init(.empty),
            .is_new = false,
            .saved_stat = null,
        };
        var editor = Editor.init(allocator, document, "(empty workspace)");
        editor.workspace = workspace;
        editor.stream = stream;
        editor.owns_document = true;
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        if (self.search_job) |job| job.deinit();
        self.clearProjection();
        self.search_text.deinit(self.allocator);
        self.last_search.deinit(self.allocator);
        if (self.owns_document) {
            self.document.deinit();
            self.allocator.destroy(self.document);
        }
        self.register.deinit(self.allocator);
        self.command.deinit(self.allocator);
        self.frame.deinit(self.allocator);
    }

    pub fn run(self: *Editor, tty: *terminal.Terminal) !void {
        if (self.stream) |*stream| stream.async_load = true;
        var size = tty.size();
        try self.draw(tty, size);
        while (true) {
            const timeout_ms: i32 = if (self.search_job != null or self.search_next != null)
                1
            else if (self.workspace != null and self.workspace.?.hasPendingRequest())
                8
            else
                100;
            const key = try tty.readKeyTimeout(timeout_ms);
            if (key == .eof) return;
            if (try self.handle(key)) return;
            try self.pollBackground();
            const next_size = tty.size();
            const resized = next_size.rows != size.rows or next_size.cols != size.cols;
            size = next_size;
            if (!self.pasting and (key != .tick or resized or self.background_redraw)) {
                self.background_redraw = false;
                try self.draw(tty, size);
            }
        }
    }

    pub fn handle(self: *Editor, key: terminal.Key) !bool {
        if (key == .tick) {
            try self.pollBackground();
            return false;
        }
        // Repeated n coalesces while a request is running. Every other input
        // supersedes its automatic jump before completed work is delivered.
        const repeat_search = !self.command_active and !self.search_prompt and
            self.mode != .insert and self.pending_operator == null and !self.pending_g and
            key == .byte and key.byte == 'n';
        if (!repeat_search) self.cancelSearch();
        // A bracketed paste is one movement for viewport purposes. Avoid
        // rescanning the growing buffer for every byte of a large paste.
        if (self.pasting and key != .paste_end) return self.handleKey(key);
        const previous_row = if (key == .paste_end and self.paste_origin_row != null)
            self.paste_origin_row.?
        else
            self.document.buffer.cursor_row;
        if (key == .paste_start) self.paste_origin_row = previous_row;
        if (key == .paste_end) self.paste_origin_row = null;
        const previous_transition = self.transitions;
        const quit = try self.handleKey(key);
        if (self.transitions == previous_transition) {
            const row = self.document.buffer.cursor_row;
            if (row >= previous_row) self.screen_row += row - previous_row else self.screen_row -|= previous_row - row;
            self.screen_row = @min(self.screen_row, self.height - 1);
        }
        return quit;
    }

    fn handleKey(self: *Editor, key: terminal.Key) !bool {
        if (key == .paste_start) {
            self.pending_operator = null;
            self.pending_g = false;
            self.pasting = true;
            self.accept_paste = self.mode == .insert and !self.command_active;
            self.paste_cr = false;
            if (self.accept_paste) self.document.history.endChange();
            return false;
        }
        if (key == .paste_end) {
            if (self.accept_paste) self.document.history.endChange();
            self.pasting = false;
            self.accept_paste = false;
            return false;
        }
        if (self.pasting) {
            if (self.accept_paste) switch (key) {
                .byte => |byte| try self.pasteByte(byte),
                .text => |text| try self.insert(text.bytes[0..text.len]),
                else => {},
            };
            return false;
        }
        if (self.search_prompt) return self.searchKey(key);
        if (self.command_active) return self.commandKey(key);
        if (key == .tick) return false;
        if (self.workspace != null and self.current_file == null) {
            if (key == .byte and key.byte == ':') {
                self.command_active = true;
                self.command.clearRetainingCapacity();
            }
            return false;
        }
        // Insert text is one undo step until movement, Escape, or a paste.
        // Normal-mode edits each start a fresh step; change operators keep
        // their deletion and following inserted text in the same step.
        if (self.mode != .insert or switch (key) {
            .escape, .up, .down, .left, .right, .home, .end, .page_up, .page_down => true,
            else => false,
        }) self.document.history.endChange();
        const buffer = &self.document.buffer;
        if (self.pending_g) {
            self.pending_g = false;
            if (key != .byte or key.byte != 'g') {
                self.pending_operator = null;
                if (key == .escape) self.mode = .normal;
                return false;
            }
        } else if (self.mode != .insert and key == .byte and key.byte == 'g') {
            self.pending_g = true;
            return false;
        }
        if (self.pending_operator) |operator| {
            self.pending_operator = null;
            try self.operatorKey(operator, key);
            return false;
        }
        if (try self.move(key, !self.isVisual())) return false;
        switch (key) {
            .escape => self.mode = .normal,
            .delete => if (self.mode == .insert) {
                if (buffer.cursor < buffer.bytes.items.len) {
                    try self.beginChange();
                    _ = buffer.deleteForward();
                    self.changed();
                }
            } else if (self.selection()) |range| {
                try self.operate(.delete, range);
            },
            .byte => |byte| {
                if (self.mode == .insert) switch (byte) {
                    8, 127 => if (buffer.cursor > 0) {
                        try self.beginChange();
                        _ = buffer.backspace();
                        self.changed();
                    },
                    '\r', '\n' => try self.insert(buffer.newline),
                    '\t', 32...126 => try self.insert(&.{byte}),
                    else => {},
                } else switch (byte) {
                    'i' => if (!self.isVisual()) {
                        self.mode = .insert;
                    },
                    'a' => if (!self.isVisual()) {
                        if (buffer.cursor < buffer.lineEnd(buffer.cursor)) buffer.moveRight();
                        self.mode = .insert;
                    },
                    'v' => self.toggleVisual(.visual),
                    'V' => self.toggleVisual(.visual_line),
                    'o' => if (self.isVisual()) {
                        const cursor = buffer.cursor;
                        buffer.setCursor(self.anchor);
                        self.anchor = cursor;
                    },
                    'y', 'd', 'c' => {
                        const operator: Operator = switch (byte) {
                            'y' => .yank,
                            'd' => .delete,
                            else => .change,
                        };
                        if (self.selection()) |range| {
                            try self.operate(operator, range);
                        } else self.pending_operator = operator;
                    },
                    'Y' => {
                        try self.operate(.yank, self.lineRange(if (self.isVisual()) self.anchor else buffer.cursor, buffer.cursor));
                    },
                    'x' => if (self.selection()) |range| {
                        try self.operate(.delete, range);
                    } else if (buffer.cursor < buffer.lineEnd(buffer.cursor)) {
                        try self.operate(.delete, .{ .start = buffer.cursor, .end = buffer.nextIndex(buffer.cursor) });
                    },
                    'D', 'C' => {
                        const range = if (self.isVisual()) self.lineRange(self.anchor, buffer.cursor) else Range{
                            .start = buffer.cursor,
                            .end = buffer.lineEnd(buffer.cursor),
                        };
                        try self.operate(if (byte == 'D') .delete else .change, range);
                    },
                    'p', 'P' => try self.put(byte == 'P'),
                    'u', 'r' => if (!self.isVisual()) self.restoreChange(byte == 'r'),
                    '/' => {
                        self.search_prompt = true;
                        self.search_text.clearRetainingCapacity();
                        self.message_len = 0;
                    },
                    'n' => try self.requestSearch(),
                    ':' => {
                        self.mode = .normal;
                        self.command_active = true;
                        self.command.clearRetainingCapacity();
                        self.message_len = 0;
                    },
                    else => {},
                }
            },
            .text => |text| if (self.mode == .insert) {
                try self.insert(text.bytes[0..text.len]);
            },
            else => {},
        }
        return false;
    }

    fn isVisual(self: *const Editor) bool {
        return self.mode == .visual or self.mode == .visual_line;
    }

    fn toggleVisual(self: *Editor, mode: Mode) void {
        if (self.mode == mode) {
            self.mode = .normal;
        } else {
            if (!self.isVisual()) self.anchor = self.document.buffer.cursor;
            self.mode = mode;
        }
        self.message_len = 0;
    }

    fn lineRange(self: *const Editor, a: usize, b: usize) Range {
        const buffer = &self.document.buffer;
        return .{
            .start = buffer.lineStart(@min(a, b)),
            .end = buffer.nextIndex(buffer.lineEnd(@max(a, b))),
            .linewise = true,
        };
    }

    fn selection(self: *const Editor) ?Range {
        const buffer = &self.document.buffer;
        return switch (self.mode) {
            .visual => .{
                .start = @min(self.anchor, buffer.cursor),
                .end = buffer.nextIndex(@max(self.anchor, buffer.cursor)),
            },
            .visual_line => self.lineRange(self.anchor, buffer.cursor),
            else => null,
        };
    }

    fn move(self: *Editor, key: terminal.Key, cross_files: bool) !bool {
        const motion: enum { up, down, left, right, home, end, file_home, file_end, page_up, page_down } = switch (key) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .byte => |byte| blk: {
                if (self.mode == .insert) return false;
                break :blk switch (byte) {
                    'h' => .left,
                    'j' => .down,
                    'k' => .up,
                    'l' => .right,
                    '0' => .home,
                    '$' => .end,
                    'g' => .file_home,
                    'G' => .file_end,
                    else => return false,
                };
            },
            else => return false,
        };
        if (motion == .file_home or motion == .file_end) {
            try self.jumpFile(motion == .file_end, cross_files);
            return true;
        }
        if (motion == .page_up or motion == .page_down) {
            const screen_row = self.screen_row;
            var distance: usize = 0;
            while (distance < self.height) {
                const before = self.document.buffer.cursor_row;
                const transition = self.transitions;
                _ = try self.move(if (motion == .page_up) .up else .down, cross_files);
                if (transition != self.transitions) {
                    distance += 2; // Include the blank file separator.
                } else if (before != self.document.buffer.cursor_row) {
                    distance += 1;
                } else break;
            }
            self.screen_row = screen_row;
            // handle() must not apply the line delta a second time.
            self.transitions +%= 1;
            return true;
        }
        const buffer = &self.document.buffer;
        const down_end = if (motion == .down) buffer.lineEnd(buffer.cursor) else null;
        const boundary = switch (motion) {
            .up => buffer.cursor_row == 0,
            .down => down_end.? == buffer.bytes.items.len,
            .left => buffer.cursor == 0,
            .right => buffer.cursor == buffer.bytes.items.len,
            else => false,
        };
        if (boundary and cross_files and self.stream != null) {
            // Explicit foreground motion retains its established semantics.
            // Search navigation adopts a prepared destination separately.
            var stream = self.stream.?;
            stream.async_load = false;
            self.wrap = try stream.canWrap(self.height);
            const forward = motion == .down or motion == .right;
            if (try stream.adjacent(self.current_file.?, forward, self.wrap)) |index| {
                const vertical = motion == .up or motion == .down;
                const column = buffer.preferred_column orelse buffer.cursorColumn();
                const document = try self.workspace.?.ensure(index);
                self.workspace.?.active_index = index;
                self.document = document;
                self.current_file = index;
                self.filename = self.workspace.?.entries.items[index].name;
                self.dirty = self.workspace.?.entries.items[index].dirty;
                const next = &document.buffer;
                next.setCursor(if (forward) 0 else next.bytes.items.len);
                if (vertical) {
                    next.moveHome();
                    if (column > 0) {
                        const end = next.lineEnd(next.cursor);
                        for (0..column) |_| {
                            if (next.cursor == end) break;
                            next.moveRight();
                        }
                    }
                    next.preferred_column = column;
                }
                if (forward) self.screen_row = @min(self.screen_row + 2, self.height - 1) else self.screen_row -|= 2;
                self.transitions +%= 1;
                self.left_column = 0;
            }
            return true;
        }
        switch (motion) {
            .up => buffer.moveUp(),
            .down => buffer.moveDownFromEnd(down_end.?),
            .left => buffer.moveLeft(),
            .right => buffer.moveRight(),
            .home => buffer.moveHome(),
            .end => buffer.moveEnd(),
            .file_home, .file_end, .page_up, .page_down => unreachable,
        }
        return true;
    }

    fn jumpFile(self: *Editor, to_end: bool, cross_files: bool) anyerror!void {
        const current = &self.document.buffer;
        const boundary = if (to_end)
            current.lineEnd(current.cursor) == current.bytes.items.len
        else
            current.cursor_row == 0;
        const transition = self.transitions;
        if (boundary and cross_files) _ = try self.move(if (to_end) .down else .up, true);
        const buffer = &self.document.buffer;
        var target = if (to_end) buffer.lineStart(buffer.bytes.items.len) else 0;
        const end = buffer.lineEnd(target);
        while (target < end and (buffer.bytes.items[target] == ' ' or buffer.bytes.items[target] == '\t')) : (target += 1) {}
        buffer.setCursor(target);
        self.left_column = 0;
        if (self.transitions != transition) self.screen_row = if (to_end) self.height - 1 else 0;
    }

    fn operatorKey(self: *Editor, operator: Operator, key: terminal.Key) !void {
        const buffer = &self.document.buffer;
        const repeated = switch (key) {
            .byte => |byte| byte == switch (operator) {
                .yank => @as(u8, 'y'),
                .delete => @as(u8, 'd'),
                .change => @as(u8, 'c'),
            },
            else => false,
        };
        if (repeated) return self.operate(operator, self.lineRange(buffer.cursor, buffer.cursor));
        const origin = buffer.cursor;
        if (!try self.move(key, false)) return;
        const destination = buffer.cursor;
        buffer.setCursor(origin);
        const linewise = switch (key) {
            .up, .down => true,
            .byte => |byte| byte == 'j' or byte == 'k' or byte == 'g' or byte == 'G',
            else => false,
        };
        const file_motion = key == .byte and (key.byte == 'g' or key.byte == 'G');
        if (linewise and origin == destination and !file_motion) return;
        try self.operate(operator, if (linewise) self.lineRange(origin, destination) else .{
            .start = @min(origin, destination),
            .end = @max(origin, destination),
        });
    }

    fn yank(self: *Editor, range: Range) !void {
        try self.register.ensureTotalCapacity(self.allocator, range.end - range.start);
        self.register.clearRetainingCapacity();
        self.register.appendSliceAssumeCapacity(self.document.buffer.bytes.items[range.start..range.end]);
        self.register_linewise = range.linewise;
        self.register_valid = true;
    }

    fn operate(self: *Editor, operator: Operator, range: Range) !void {
        const buffer = &self.document.buffer;
        const was_visual = self.isVisual();
        if (range.start != range.end or range.linewise) try self.yank(range);
        self.mode = if (operator == .change) .insert else .normal;
        if (operator == .yank) {
            if (was_visual) buffer.setCursor(range.start);
            self.setMessage("Yanked {d} bytes", .{range.end - range.start});
            return;
        }

        var start = range.start;
        var replacement: []const u8 = "";
        const bytes = buffer.bytes.items;
        if (range.linewise) {
            if (operator == .change) {
                // Keep one editable line, including its separator from the next.
                if (range.end > start and bytes[range.end - 1] == '\n') {
                    replacement = if (range.end > 1 and bytes[range.end - 2] == '\r') "\r\n" else "\n";
                }
            } else if (start > 0 and range.end == bytes.len and
                (range.end == start or bytes[range.end - 1] != '\n'))
            {
                // Removing an unterminated last line also removes its separator.
                start = buffer.previousIndex(start);
            }
        }
        if (!std.mem.eql(u8, bytes[start..range.end], replacement)) {
            try self.beginChange();
            try buffer.replaceRange(self.document.allocator, start, range.end, replacement);
            self.changed();
        }
        buffer.setCursor(start);
    }

    fn put(self: *Editor, before: bool) !void {
        if (!self.register_valid) {
            self.setMessage("Nothing yanked", .{});
            return;
        }
        const buffer = &self.document.buffer;
        const bytes = buffer.bytes.items;
        const selected = self.selection();
        var start = buffer.cursor;
        var end = start;
        var prefix = false;
        var suffix = false;
        const text = self.register.items;
        const terminated = std.mem.endsWith(u8, text, "\n");
        if (selected) |range| {
            start = range.start;
            end = range.end;
            if (range.linewise) {
                suffix = !terminated and end > start and bytes[end - 1] == '\n';
            } else if (self.register_linewise) {
                prefix = start != buffer.lineStart(start);
                suffix = !terminated and end < bytes.len;
            }
        } else if (self.register_linewise) {
            const line_end = buffer.lineEnd(buffer.cursor);
            if (before) {
                start = buffer.lineStart(buffer.cursor);
                suffix = !terminated and bytes.len != 0;
            } else if (line_end < bytes.len) {
                start = buffer.nextIndex(line_end);
                suffix = !terminated;
            } else {
                start = bytes.len;
                prefix = bytes.len != 0;
            }
            end = start;
        } else {
            if (!before and start < buffer.lineEnd(start)) start = buffer.nextIndex(start);
            end = start;
        }

        var pasted: std.ArrayList(u8) = .empty;
        defer pasted.deinit(self.allocator);
        if (prefix) try pasted.appendSlice(self.allocator, buffer.newline);
        const content_offset = pasted.items.len;
        try pasted.appendSlice(self.allocator, text);
        if (suffix or (selected == null and self.register_linewise and pasted.items.len == 0)) {
            try pasted.appendSlice(self.allocator, buffer.newline);
        }
        if (!std.mem.eql(u8, bytes[start..end], pasted.items)) {
            try self.beginChange();
            try buffer.replaceRange(self.document.allocator, start, end, pasted.items);
            self.changed();
        }
        self.mode = .normal;
        if (self.register_linewise or (selected != null and selected.?.linewise)) {
            buffer.setCursor(start + content_offset);
        } else {
            const after = start + pasted.items.len;
            buffer.setCursor(if (after > start) buffer.previousIndex(after) else start);
        }
    }

    fn beginChange(self: *Editor) !void {
        try self.document.history.beginChange(self.document.allocator, &self.document.buffer);
    }

    fn restoreChange(self: *Editor, redo: bool) void {
        const history = &self.document.history;
        const restored = if (redo) history.redo(&self.document.buffer) else history.undo(&self.document.buffer);
        if (!restored) {
            self.setMessage("Nothing to {s}", .{if (redo) @as([]const u8, "redo") else "undo"});
            return;
        }
        self.changed();
        self.dirty = history.isDirty();
        if (self.current_file) |index| self.workspace.?.entries.items[index].dirty = self.dirty;
    }

    fn changed(self: *Editor) void {
        self.clearProjection();
        self.document_revision +%= 1;
        self.dirty = true;
        if (self.current_file) |index| {
            self.workspace.?.markDirty(index);
        }
        self.message_len = 0;
    }

    fn insert(self: *Editor, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.beginChange();
        try self.document.buffer.insert(self.document.allocator, bytes);
        self.changed();
    }

    fn pasteByte(self: *Editor, byte: u8) !void {
        if (byte == '\n' and self.paste_cr) {
            self.paste_cr = false;
            return;
        }
        self.paste_cr = byte == '\r';
        switch (byte) {
            '\r', '\n' => try self.insert(self.document.buffer.newline),
            '\t', 32...126, 128...255 => try self.insert(&.{byte}),
            else => {},
        }
    }

    fn cancelSearch(self: *Editor) void {
        if (self.search_accept or self.search_next != null) self.message_len = 0;
        self.search_accept = false;
        self.search_next = null;
        if (self.search_job) |job| job.cancel();
    }

    fn searchKey(self: *Editor, key: terminal.Key) !bool {
        switch (key) {
            .escape => self.search_prompt = false,
            .byte => |byte| switch (byte) {
                8, 127 => {
                    if (self.search_text.items.len == 0) {
                        self.search_prompt = false;
                    } else {
                        var end = self.search_text.items.len - 1;
                        while (end > 0 and self.search_text.items[end] & 0xc0 == 0x80) end -= 1;
                        self.search_text.shrinkRetainingCapacity(end);
                    }
                },
                '\r', '\n' => {
                    self.search_prompt = false;
                    if (self.search_text.items.len != 0) {
                        try self.last_search.ensureTotalCapacity(self.allocator, self.search_text.items.len);
                        self.last_search.clearRetainingCapacity();
                        self.last_search.appendSliceAssumeCapacity(self.search_text.items);
                    }
                    try self.requestSearch();
                },
                32...126 => try self.appendSearchText(&.{byte}),
                else => {},
            },
            .text => |text| try self.appendSearchText(text.bytes[0..text.len]),
            else => {},
        }
        return false;
    }

    fn appendSearchText(self: *Editor, text: []const u8) !void {
        if (self.search_text.items.len + text.len > search.max_query_size) {
            self.setMessage("Search is limited to {d} bytes", .{search.max_query_size});
            return;
        }
        try self.search_text.appendSlice(self.allocator, text);
    }

    fn requestSearch(self: *Editor) !void {
        if (self.search_accept or self.search_next != null) return;
        if (self.last_search.items.len == 0) {
            self.setMessage("No previous search", .{});
            return;
        }
        if (self.workspace != null and self.current_file == null) {
            self.setMessage("No file under cursor", .{});
            return;
        }
        if (self.stream) |*stream| stream.async_load = true;
        self.search_next = .{
            .file_count = if (self.workspace) |workspace| workspace.entries.items.len else 1,
            .origin_file = self.current_file orelse 0,
            .origin_offset = self.document.buffer.cursor,
            .origin_row = self.document.buffer.cursor_row,
            .current_file_only = self.isVisual(),
            .cell = searchCell,
            .projected_line = if (self.search_projection != null and self.projection_document == self.document and
                self.projection_revision == self.currentRevision()) .{
                .file = self.current_file orelse 0,
                .revision = self.projection_revision,
                .line_start = self.search_projection.?.line_start,
                .line_end = self.search_projection.?.line_end,
            } else null,
        };
        self.setMessage("Searching...", .{});
        try self.pollBackground();
    }

    fn searchSource(self: *Editor, request: search.Request, destination: []u8) search.Source {
        const revision = if (self.workspace) |workspace|
            workspace.entries.items[request.file].revision
        else
            self.document_revision;
        if (request.revision) |expected| if (expected != revision) return .{ .unavailable = error.ContentChanged };
        const document = if (self.workspace) |workspace|
            workspace.entries.items[request.file].document
        else
            self.document;
        if (document) |doc| {
            const bytes = doc.buffer.bytes.items;
            if (request.offset > bytes.len) return .{ .unavailable = error.ContentChanged };
            const count = @min(destination.len, bytes.len - request.offset);
            @memcpy(destination[0..count], bytes[request.offset..][0..count]);
            return .{ .resident = .{ .len = count, .total_size = bytes.len, .revision = revision } };
        }
        const entry = &self.workspace.?.entries.items[request.file];
        if (entry.load_error) |err| return .{ .unavailable = err };
        return .{ .disk = .{ .path = entry.path, .revision = revision } };
    }

    fn pollBackground(self: *Editor) !void {
        if (self.workspace) |workspace| {
            if (try workspace.pollRequested()) self.background_redraw = true;
        }
        if (self.search_job) |job| {
            _ = job.service(self, searchSource);
            if (job.isDone()) {
                var result = job.takeResult();
                defer result.deinit();
                const options = job.options;
                job.deinit();
                self.search_job = null;
                if (self.search_accept) {
                    self.search_accept = false;
                    self.background_redraw = true;
                    if (result.failure) |err| {
                        if (err == error.ContentChanged or err == error.SourceChanged) {
                            self.search_next = options;
                        } else self.setMessage("Search failed: {s}", .{@errorName(err)});
                    } else if (result.match) |*found| {
                        const revision = if (self.workspace) |workspace|
                            workspace.entries.items[found.file].revision
                        else
                            self.document_revision;
                        if (revision != found.revision) {
                            // Residency or edits changed while the worker read.
                            // Retry against current authoritative content.
                            self.search_next = options;
                        } else {
                            try self.acceptMatch(found);
                            if (result.skipped != 0) {
                                self.setMessage("{s} ({d} files skipped)", .{
                                    @as([]const u8, if (found.wrapped) "Search wrapped" else "Match"), result.skipped,
                                });
                            } else self.setMessage("{s}", .{@as([]const u8, if (found.wrapped) "Search wrapped" else "Match")});
                        }
                    } else if (result.skipped != 0) {
                        self.setMessage("Search incomplete: {d} files skipped", .{result.skipped});
                    } else self.setMessage("Pattern not found", .{});
                }
            }
        }
        if (self.search_job == null) {
            if (self.search_next) |options| {
                self.search_next = null;
                self.search_job = search.Job.start(self.allocator, self.last_search.items, options) catch |err| {
                    self.setMessage("Search failed: {s}", .{@errorName(err)});
                    self.background_redraw = true;
                    return;
                };
                self.search_accept = true;
            }
        }
    }

    fn acceptMatch(self: *Editor, found: *search.Match) !void {
        if (self.workspace) |workspace| {
            workspace.cancelRequested();
            const previous_active = workspace.active_index;
            workspace.active_index = found.file;
            errdefer workspace.active_index = previous_active;
            if (found.document) |document| {
                self.document = try workspace.adopt(found.file, document, found.line_count.?);
                found.document = null;
            } else self.document = workspace.entries.items[found.file].document.?;
            self.current_file = found.file;
            self.filename = workspace.entries.items[found.file].name;
            self.dirty = workspace.entries.items[found.file].dirty;
        }
        // The scanner already counted these rows. setCursor would scan the
        // entire prefix again on the input thread for a distant match.
        self.document.buffer.cursor = found.offset;
        self.document.buffer.cursor_row = found.row;
        self.document.buffer.preferred_column = null;
        const reuse = found.projection == null and self.search_projection != null and
            self.projection_document == self.document and self.projection_revision == self.currentRevision() and
            found.offset >= self.search_projection.?.line_start and found.offset <= self.search_projection.?.line_end;
        if (!reuse) {
            self.clearProjection();
            self.search_projection = found.projection;
            found.projection = null;
        }
        self.projection_document = self.document;
        self.projection_revision = self.currentRevision();
        self.screen_row = 0;
        self.left_column = 0;
        self.transitions +%= 1;
    }

    fn searchCell(bytes: []const u8, column: usize) search.Cell {
        const cell = display.cell(bytes, column);
        return .{ .len = cell.len, .width = cell.width };
    }

    fn currentRevision(self: *const Editor) u64 {
        return if (self.current_file) |index| self.workspace.?.entries.items[index].revision else self.document_revision;
    }

    fn clearProjection(self: *Editor) void {
        if (self.search_projection) |*projection| projection.deinit();
        self.search_projection = null;
        self.projection_document = null;
    }

    fn lineStart(self: *const Editor, position: usize) usize {
        if (self.search_projection) |projection| {
            if (position >= projection.line_start and position <= projection.line_end) return projection.line_start;
        }
        return self.document.buffer.lineStart(position);
    }

    fn cursorColumn(self: *const Editor) usize {
        const cursor = self.document.buffer.cursor;
        if (self.search_projection) |projection| {
            if (cursor >= projection.line_start and cursor <= projection.line_end) {
                var low: usize = 0;
                var high = projection.anchors.len;
                while (low + 1 < high) {
                    const middle = low + (high - low) / 2;
                    if (projection.anchors[middle].offset <= cursor) low = middle else high = middle;
                }
                const anchor = projection.anchors[low];
                return display.columnsFrom(self.document.buffer.bytes.items[anchor.offset..cursor], anchor.column);
            }
        }
        return display.columns(self.document.buffer.bytes.items[self.lineStart(cursor)..cursor]);
    }

    fn commandKey(self: *Editor, key: terminal.Key) !bool {
        switch (key) {
            .escape => self.command_active = false,
            .byte => |byte| switch (byte) {
                8, 127 => {
                    if (self.command.items.len == 0) {
                        self.command_active = false;
                    } else _ = self.command.pop();
                },
                '\r', '\n' => {
                    self.command_active = false;
                    return self.executeCommand();
                },
                32...126 => if (self.command.items.len < 128) {
                    try self.command.append(self.allocator, byte);
                },
                else => {},
            },
            else => {},
        }
        return false;
    }

    fn executeCommand(self: *Editor) bool {
        const cmd = std.mem.trim(u8, self.command.items, " ");
        if (std.mem.eql(u8, cmd, "w") or std.mem.eql(u8, cmd, "write") or std.mem.eql(u8, cmd, "wt")) {
            if (self.workspace) |workspace| {
                if (std.mem.eql(u8, cmd, "wt")) {
                    const index = self.current_file orelse {
                        self.setMessage("No file under cursor", .{});
                        return false;
                    };
                    workspace.save(index) catch |err| {
                        self.setMessage("Save failed: {s}: {s}", .{ @errorName(err), self.filename });
                        return false;
                    };
                    self.dirty = false;
                    self.setMessage("Written {s}", .{self.filename});
                } else {
                    const result = workspace.saveAll();
                    if (self.current_file) |index| self.dirty = workspace.entries.items[index].dirty;
                    if (result.first_error) |err| {
                        self.setMessage("Save failed: {s}: {s} ({d} written, {d} failed)", .{
                            @errorName(err), workspace.entries.items[result.first_failed.?].name, result.saved, result.failed,
                        });
                    } else self.setMessage("Written {d} files", .{result.saved});
                }
            } else {
                self.document.save() catch |err| {
                    self.setMessage("Save failed: {s}", .{@errorName(err)});
                    return false;
                };
                self.dirty = false;
                self.setMessage("Written {d} bytes", .{self.document.buffer.bytes.items.len});
            }
        } else if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
            const unsaved = if (self.workspace) |workspace| workspace.hasChanges() else self.dirty;
            if (!unsaved) return true;
            self.setMessage("Unsaved changes; use :w or :q!", .{});
        } else if (std.mem.eql(u8, cmd, "q!") or std.mem.eql(u8, cmd, "quit!")) {
            return true;
        } else if (cmd.len != 0) {
            self.setMessage("Unknown command: {s} (use :w, :wt or :q)", .{cmd});
        }
        return false;
    }

    fn setMessage(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.bufPrint(&self.message, fmt, args) catch "Message too long";
        if (message.ptr != &self.message) @memcpy(self.message[0..message.len], message);
        self.message_len = message.len;
    }

    fn append(self: *Editor, bytes: []const u8) !void {
        try self.frame.appendSlice(self.allocator, bytes);
    }

    fn print(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        var text: [128]u8 = undefined;
        try self.append(try std.fmt.bufPrint(&text, fmt, args));
    }

    fn spaces(self: *Editor, count: usize) !void {
        try self.frame.appendNTimes(self.allocator, ' ', count);
    }

    fn draw(self: *Editor, tty: *terminal.Terminal, size: terminal.Size) !void {
        try tty.writeAll(try self.renderFrame(size));
    }

    /// Prepare the same complete frame used by the terminal loop, without I/O.
    /// The returned bytes are borrowed until the next frame or deinit.
    pub fn renderFrame(self: *Editor, size: terminal.Size) ![]const u8 {
        if (self.search_projection != null and
            (self.projection_document != self.document or self.projection_revision != self.currentRevision())) self.clearProjection();
        const async_workspace = if (self.stream != null and self.stream.?.async_load) self.workspace else null;
        if (async_workspace) |workspace| workspace.beginFrame();
        defer if (async_workspace) |workspace| workspace.endFrame();
        self.frame.clearRetainingCapacity();
        try self.append("\x1b[?2026h\x1b[?25l\x1b[0m");
        if (size.rows < 3 or size.cols < 2) {
            try self.append("\x1b[H\x1b[2J\x1b[?2026l");
            return self.frame.items;
        }
        const buffer = &self.document.buffer;
        self.height = size.rows - 2;
        self.screen_row = @min(self.screen_row, self.height - 1);
        if (self.stream) |*stream| self.wrap = try stream.canWrap(self.height);
        const cursor_row = buffer.cursor_row;
        const cursor_column = self.cursorColumn();
        if (cursor_column < self.left_column) self.left_column = cursor_column;
        if (cursor_column >= self.left_column + size.cols) self.left_column = cursor_column - size.cols + 1;

        var first = Row{ .file = self.current_file orelse 0, .start = self.lineStart(buffer.cursor) };
        var back: usize = 0;
        while (back < self.screen_row) : (back += 1) {
            first = try self.stepRow(first, false) orelse break;
        }
        self.screen_row = back;
        var visible: ?Row = if (self.workspace != null and self.current_file == null) null else first;
        for (0..self.height) |row| {
            try self.print("\x1b[{d};1H\x1b[2K", .{row + 1});
            if (visible) |line| {
                var rendered = line;
                if (!line.gap) {
                    const document = if (self.workspace) |workspace|
                        if (async_workspace != null) (try workspace.request(line.file)).? else try workspace.ensure(line.file)
                    else
                        self.document;
                    const start = if (document == self.document) self.lineStart(@min(line.start, document.buffer.bytes.items.len)) else document.buffer.lineStart(@min(line.start, document.buffer.bytes.items.len));
                    const projection = if (document == self.document and self.search_projection != null and self.search_projection.?.line_start == start) self.search_projection else null;
                    const end = if (projection) |prepared| prepared.line_end else document.buffer.lineEnd(start);
                    rendered.end = end;
                    if (self.workspace == null or line.file == self.current_file) {
                        try self.drawLine(start, end, size.cols);
                    } else try self.drawText(document.buffer.bytes.items[start..end], self.left_column, size.cols);
                }
                // Do not prefetch a file below the last visible row.
                if (row + 1 < self.height) visible = try self.stepRow(rendered, true);
            } else if (self.current_file == null and self.workspace != null and row == 0) {
                try self.drawText("No readable files in this workspace", 0, size.cols);
            } else {
                try self.append("\x1b[90m~\x1b[0m");
            }
        }

        try self.print("\x1b[{d};1H\x1b[7m\x1b[2K", .{size.rows - 1});
        var status: [128]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&status, " {s}{s}  {d}:{d}  ", .{
            @as([]const u8, switch (self.mode) {
                .normal => "NORMAL",
                .insert => "INSERT",
                .visual => "VISUAL",
                .visual_line => "VISUAL LINE",
            }),
            if (self.dirty) @as([]const u8, " [+]") else "",
            cursor_row + 1,
            cursor_column + 1,
        });
        try self.drawText(prefix, 0, size.cols);
        if (prefix.len < size.cols) try self.drawText(self.filename, 0, size.cols - prefix.len);
        try self.append("\x1b[0m");
        try self.print("\x1b[{d};1H\x1b[2K", .{size.rows});
        if (self.search_prompt) {
            try self.append("/");
            const columns = display.columns(self.search_text.items);
            try self.drawText(self.search_text.items, columns -| (size.cols - 2), size.cols - 1);
        } else if (self.command_active) {
            try self.append(":");
            const offset = self.command.items.len -| (size.cols - 2);
            try self.append(self.command.items[offset..]);
        } else if (self.message_len != 0) {
            try self.drawText(self.message[0..self.message_len], 0, size.cols);
        } else {
            try self.drawText(if (self.mode == .insert)
                " Escape normal"
            else if (self.isVisual())
                " y yank   d delete   c change   p paste   Escape cancel"
            else if (self.pending_operator != null)
                " Motion or repeat operator; Escape cancels"
            else
                " i insert   / search   n next   v/V select   :w all   :wt file   :q quit", 0, size.cols);
        }
        if (self.search_prompt) {
            try self.print("\x1b[{d};{d}H\x1b[6 q", .{ size.rows, @min(display.columns(self.search_text.items) + 2, size.cols) });
        } else if (self.command_active) {
            try self.print("\x1b[{d};{d}H\x1b[6 q", .{ size.rows, @min(self.command.items.len + 2, size.cols) });
        } else {
            try self.print("\x1b[{d};{d}H", .{ self.screen_row + 1, cursor_column - self.left_column + 1 });
            try self.append(if (self.mode == .insert) "\x1b[6 q" else "\x1b[2 q");
        }
        try self.append("\x1b[?25h\x1b[?2026l");
        return self.frame.items;
    }

    fn stepRow(self: *Editor, row: Row, forward: bool) !?Row {
        if (self.stream) |*stream| return stream.step(row, forward, self.wrap) catch |err| switch (err) {
            error.LoadPending => null,
            else => return err,
        };
        const buffer = &self.document.buffer;
        if (forward) {
            const end = row.end orelse buffer.lineEnd(row.start);
            return if (end < buffer.bytes.items.len) Row{ .file = 0, .start = buffer.nextIndex(end) } else null;
        }
        return if (row.start > 0) Row{ .file = 0, .start = buffer.lineStart(buffer.previousIndex(row.start)) } else null;
    }

    fn drawLine(self: *Editor, start: usize, end: usize, width: usize) !void {
        const bytes = self.document.buffer.bytes.items[start..end];
        const selected = self.selection();
        const projection = if (self.search_projection != null and self.search_projection.?.line_start == start) self.search_projection else null;
        if (projection) |prepared| {
            var low: usize = 0;
            var high = prepared.anchors.len;
            while (low + 1 < high) {
                const middle = low + (high - low) / 2;
                if (prepared.anchors[middle].column <= self.left_column) low = middle else high = middle;
            }
            const anchor = prepared.anchors[low];
            try self.drawStyledTextFrom(self.document.buffer.bytes.items[anchor.offset..end], self.left_column, width, selected, anchor.offset, anchor.column);
        } else try self.drawStyledText(bytes, self.left_column, width, selected, start);
        if (selected) |range| {
            const column = if (projection) |prepared| prepared.total_columns else display.columns(bytes);
            const line_selected = range.linewise and start >= range.start and
                start <= self.lineStart(@max(self.anchor, self.document.buffer.cursor));
            const newline_selected = !range.linewise and end >= range.start and end < range.end;
            if (line_selected or (newline_selected and column >= self.left_column)) {
                const used = column -| self.left_column;
                if (used < width) {
                    try self.append("\x1b[7m");
                    try self.spaces(if (line_selected) width - used else 1);
                    try self.append("\x1b[27m");
                }
            }
        }
    }

    fn drawText(self: *Editor, bytes: []const u8, left: usize, width: usize) !void {
        try self.drawStyledText(bytes, left, width, null, 0);
    }

    fn drawStyledText(self: *Editor, bytes: []const u8, left: usize, width: usize, selected: ?Range, offset: usize) !void {
        return self.drawStyledTextFrom(bytes, left, width, selected, offset, 0);
    }

    fn drawStyledTextFrom(self: *Editor, bytes: []const u8, left: usize, width: usize, selected: ?Range, offset: usize, initial_column: usize) !void {
        var index: usize = 0;
        var column: usize = initial_column;
        var visible_base = false;
        var highlighted = false;
        while (index < bytes.len) {
            const unit = display.cell(bytes[index..], column);
            const end = column + unit.width;
            if (column >= left + width) break;
            if ((unit.width == 0 and visible_base) or (unit.width != 0 and end > left)) {
                const highlight = if (selected) |range| offset + index >= range.start and offset + index < range.end else false;
                if (highlight != highlighted) {
                    try self.append(if (highlight) "\x1b[7m" else "\x1b[27m");
                    highlighted = highlight;
                }
            }
            if (unit.width == 0) {
                if (visible_base and unit.kind == .text) try self.append(bytes[index..][0..unit.len]);
            } else if (end > left) {
                const visible_width = @min(end, left + width) - @max(column, left);
                if (column < left or end > left + width or unit.kind == .tab) {
                    try self.spaces(visible_width);
                    visible_base = false;
                } else {
                    switch (unit.kind) {
                        .text => try self.append(bytes[index..][0..unit.len]),
                        .control => try self.append(&.{ '^', if (bytes[index] == 127) '?' else bytes[index] + 64 }),
                        .replacement => try self.append("\xef\xbf\xbd"),
                        .tab => unreachable,
                    }
                    visible_base = true;
                }
            }
            column = end;
            index += unit.len;
        }
        if (highlighted) try self.append("\x1b[27m");
    }
};

test "undo groups insert sessions and change operators and restores redo" {
    const cases = [_]struct { text: []const u8, setup: []const u8 = "", edit: []const u8, result: []const u8 }{
        .{ .text = "ab", .edit = "iur\rX\x1b", .result = "ur\nXab" },
        .{ .text = "one\r\ntwo", .setup = "j", .edit = "ccnew\x1b", .result = "one\r\nnew" },
        .{ .text = "one\ntwo", .setup = "l", .edit = "Cnew\x1b", .result = "onew\ntwo" },
        .{ .text = "aé界\r\nz", .setup = "lv", .edit = "ld", .result = "a\r\nz" },
        .{ .text = "one\ntwo", .setup = "Yj", .edit = "p", .result = "one\ntwo\none\n" },
        .{ .text = "abc\nfoo", .setup = "vlyjV", .edit = "p", .result = "abc\nab" },
        .{ .text = "one\r\ntwo", .setup = "j", .edit = "dd", .result = "one" },
    };
    for (cases) |case| {
        var doc = try testingDocument(case.text);
        defer doc.deinit();
        var editor = Editor.init(std.testing.allocator, &doc, "unused");
        defer editor.deinit();
        try typeKeys(&editor, case.setup);
        try typeKeys(&editor, case.edit);
        const cursor = doc.buffer.cursor;
        try std.testing.expectEqualStrings(case.result, doc.buffer.bytes.items);
        try std.testing.expect(editor.dirty);
        try typeKeys(&editor, "u");
        try std.testing.expectEqualStrings(case.text, doc.buffer.bytes.items);
        try std.testing.expect(!editor.dirty);
        try std.testing.expectEqual(Mode.normal, editor.mode);
        try typeKeys(&editor, "r");
        try std.testing.expectEqualStrings(case.result, doc.buffer.bytes.items);
        try std.testing.expectEqual(cursor, doc.buffer.cursor);
        try std.testing.expect(editor.dirty);
    }
}

test "insert movement and bracketed paste separate undo steps" {
    var doc = try testingDocument("é\r\nz");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "iA");
    _ = try editor.handle(.right);
    _ = try editor.handle(.delete);
    try typeKeys(&editor, "B\x1b");
    try std.testing.expectEqualStrings("AéBz", doc.buffer.bytes.items);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("Aé\r\nz", doc.buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 3), doc.buffer.cursor);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("é\r\nz", doc.buffer.bytes.items);
    try typeKeys(&editor, "rr");
    try std.testing.expectEqualStrings("AéBz", doc.buffer.bytes.items);

    try typeKeys(&editor, "iQ");
    _ = try editor.handle(.paste_start);
    try typeKeys(&editor, "é\r\nP");
    _ = try editor.handle(.paste_end);
    try typeKeys(&editor, "R\x1bu");
    try std.testing.expectEqualStrings("AéBQé\r\nPz", doc.buffer.bytes.items);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("AéBQz", doc.buffer.bytes.items);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("AéBz", doc.buffer.bytes.items);
}

test "undo steps preserve scalars and CRLF through insert deletion" {
    var doc = try testingDocument("aé\r\nz");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "ji\x7f\x7f\x1b");
    try std.testing.expectEqualStrings("az", doc.buffer.bytes.items);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("aé\r\nz", doc.buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 5), doc.buffer.cursor);
    try typeKeys(&editor, "r");
    try std.testing.expectEqualStrings("az", doc.buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), doc.buffer.cursor);
}

test "no-op edits keep redo and normal deletions undo individually" {
    var doc = try testingDocument("abc");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "xxu");
    try std.testing.expectEqualStrings("bc", doc.buffer.bytes.items);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("abc", doc.buffer.bytes.items);
    try typeKeys(&editor, "i\x7f\x1b$D0r");
    try std.testing.expectEqualStrings("bc", doc.buffer.bytes.items);
    try typeKeys(&editor, "iX\x1br");
    try std.testing.expectEqualStrings("Xbc", doc.buffer.bytes.items);
    try std.testing.expectEqualStrings("Nothing to redo", editor.message[0..editor.message_len]);
}

test "workspace undo and redo update saved state revisions and line counts" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one\r\ntwo" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "other" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    try typeKeys(&editor, "iA\r\x1b:wt\r");
    try std.testing.expect(!workspace.hasChanges());
    const saved_revision = workspace.entries.items[0].revision;
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("one\r\ntwo", editor.document.buffer.bytes.items);
    try std.testing.expect(workspace.hasChanges());
    try std.testing.expect(editor.dirty);
    try std.testing.expect(workspace.entries.items[0].revision > saved_revision);
    _ = try workspace.ensure(0);
    try std.testing.expectEqual(@as(?usize, 2), workspace.entries.items[0].line_count);
    try typeKeys(&editor, "r");
    try std.testing.expect(!workspace.hasChanges());
    try std.testing.expect(!editor.dirty);
    _ = try workspace.ensure(0);
    try std.testing.expectEqual(@as(?usize, 3), workspace.entries.items[0].line_count);
    try typeKeys(&editor, "GGiB\x1b");
    try std.testing.expectEqual(@as(?usize, 1), editor.current_file);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("other", editor.document.buffer.bytes.items);
    try std.testing.expect(!workspace.hasChanges());
    try typeKeys(&editor, "ggr");
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try std.testing.expectEqualStrings("A\r\none\r\ntwo", editor.document.buffer.bytes.items);
    try typeKeys(&editor, "u");
    try std.testing.expectEqualStrings("one\r\ntwo", editor.document.buffer.bytes.items);
    try std.testing.expect(workspace.hasChanges());
}

test "rendering never emits file control sequences" {
    var doc: content.Document = undefined;
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try editor.drawText("hello\x1b[2J\x00\xff", 0, 80);
    try std.testing.expectEqualStrings("hello^[[2J^@\xef\xbf\xbd", editor.frame.items);
}

test "horizontal clipping does not emit half a wide character" {
    var doc: content.Document = undefined;
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try editor.drawText("界x", 1, 2);
    try std.testing.expectEqualStrings(" x", editor.frame.items);
}

fn testingDocument(text: []const u8) !content.Document {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "unused");
    errdefer allocator.free(path);
    return .{
        .allocator = allocator,
        .path = path,
        .buffer = content.Buffer.init(.fromOwnedSlice(try allocator.dupe(u8, text))),
        .is_new = true,
        .saved_stat = null,
    };
}

fn typeKeys(editor: *Editor, keys: []const u8) !void {
    for (keys) |byte| {
        try std.testing.expect(!try editor.handle(if (byte == 0x1b) .escape else .{ .byte = byte }));
        const buffer = &editor.document.buffer;
        try std.testing.expectEqual(std.mem.count(u8, buffer.bytes.items[0..buffer.cursor], "\n"), buffer.cursor_row);
    }
}

fn expectStatusRow(editor: *Editor, row: usize) !void {
    const frame = try editor.renderFrame(.{ .rows = 6, .cols = 80 });
    var expected: [64]u8 = undefined;
    const status = try std.fmt.bufPrint(&expected, "  {d}:", .{row});
    try std.testing.expect(std.mem.indexOf(u8, frame, status) != null);
}

test "append enters insert after one scalar without crossing a line ending" {
    const cases = [_]struct { text: []const u8, cursor: usize, result: []const u8 }{
        .{ .text = "abc", .cursor = 0, .result = "aXbc" },
        .{ .text = "é界", .cursor = 0, .result = "éX界" },
        .{ .text = "é界", .cursor = 2, .result = "é界X" },
        .{ .text = "abc", .cursor = 3, .result = "abcX" },
        .{ .text = "a\r\nb", .cursor = 1, .result = "aX\r\nb" },
        .{ .text = "\nb", .cursor = 0, .result = "X\nb" },
        .{ .text = "", .cursor = 0, .result = "X" },
    };
    for (cases) |case| {
        var doc = try testingDocument(case.text);
        defer doc.deinit();
        var editor = Editor.init(std.testing.allocator, &doc, "unused");
        defer editor.deinit();
        doc.buffer.setCursor(case.cursor);
        try typeKeys(&editor, "a");
        try std.testing.expectEqual(Mode.insert, editor.mode);
        try std.testing.expect(!editor.dirty);
        try typeKeys(&editor, "X\x1b");
        try std.testing.expectEqualStrings(case.result, doc.buffer.bytes.items);
    }
}

test "file motions use the first nonblank and g prefixes survive ticks and cancel" {
    var doc = try testingDocument("  first\r\nmiddle\r\n\tlast");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "jG");
    try std.testing.expectEqual(@as(usize, 18), doc.buffer.cursor);
    try typeKeys(&editor, "g");
    _ = try editor.handle(.tick);
    try std.testing.expect(editor.pending_g);
    try std.testing.expectEqual(@as(usize, 2), doc.buffer.cursor_row);
    try typeKeys(&editor, "g");
    try std.testing.expectEqual(@as(usize, 2), doc.buffer.cursor);
    try typeKeys(&editor, "gG");
    try std.testing.expect(!editor.pending_g);
    try std.testing.expectEqual(@as(usize, 2), doc.buffer.cursor);
    try typeKeys(&editor, "vg\x1b");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try typeKeys(&editor, "iagG\x1b");
    try std.testing.expectEqualStrings("  agGfirst\r\nmiddle\r\n\tlast", doc.buffer.bytes.items);
}

test "file border motions visit the same border of readable neighbors and honor wrapping" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = " a1\n a2" });
    const huge = try temp.dir.createFile("b", .{});
    try huge.setEndPos(content.max_file_size + 1);
    huge.close();
    try temp.dir.writeFile(.{ .sub_path = "c", .data = " c1\n c2" });
    try temp.dir.writeFile(.{ .sub_path = "d", .data = "" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    try typeKeys(&editor, "ggG");
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try std.testing.expectEqual(@as(usize, 5), editor.document.buffer.cursor);
    try typeKeys(&editor, "G");
    try std.testing.expectEqual(@as(?usize, 2), editor.current_file);
    try std.testing.expectEqual(@as(usize, 5), editor.document.buffer.cursor);
    try typeKeys(&editor, "GG");
    try std.testing.expectEqual(@as(?usize, 3), editor.current_file);
    try std.testing.expectEqual(@as(usize, 0), editor.document.buffer.cursor);
    try typeKeys(&editor, "gg");
    try std.testing.expectEqual(@as(?usize, 2), editor.current_file);
    try std.testing.expectEqual(@as(usize, 1), editor.document.buffer.cursor);
    try typeKeys(&editor, "gg");
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try std.testing.expectEqual(@as(usize, 1), editor.document.buffer.cursor);
    editor.height = 1;
    try typeKeys(&editor, "gg");
    try std.testing.expectEqual(@as(?usize, 3), editor.current_file);
    try typeKeys(&editor, "G");
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try std.testing.expectEqual(@as(usize, 5), editor.document.buffer.cursor);
    try std.testing.expect(!workspace.hasChanges());
}

test "file motions extend visual selections and operators stay in the current file" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one\ntwo\nthree" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "neighbor" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    try typeKeys(&editor, "VGGy");
    try std.testing.expectEqualStrings("one\ntwo\nthree", editor.register.items);
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try typeKeys(&editor, "Vggggy");
    try std.testing.expectEqualStrings("one\n", editor.register.items);
    try typeKeys(&editor, "ygg");
    try std.testing.expectEqualStrings("one\n", editor.register.items);
    try typeKeys(&editor, "jdgg");
    try std.testing.expectEqualStrings("three", editor.document.buffer.bytes.items);
    try std.testing.expectEqualStrings("one\ntwo\n", editor.register.items);
    try typeKeys(&editor, "dG");
    try std.testing.expectEqualStrings("", editor.document.buffer.bytes.items);
    try std.testing.expectEqualStrings("three", editor.register.items);
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try std.testing.expectEqualStrings("neighbor", (try workspace.ensure(1)).buffer.bytes.items);
}

test "status row follows edits, bracketed paste, and paging" {
    var doc = try testingDocument("one\r\ntwo\r\nthree");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "jj");
    try expectStatusRow(&editor, 3);
    try typeKeys(&editor, "dd");
    try std.testing.expectEqualStrings("one\r\ntwo", doc.buffer.bytes.items);
    try expectStatusRow(&editor, 2);
    try typeKeys(&editor, "i");
    _ = try editor.handle(.paste_start);
    try typeKeys(&editor, "a\r\nb\nc\nd\ne\nf");
    _ = try editor.handle(.paste_end);
    try expectStatusRow(&editor, 7);
    _ = try editor.handle(.escape);
    _ = try editor.handle(.page_up);
    try expectStatusRow(&editor, 3);
    _ = try editor.handle(.page_down);
    try expectStatusRow(&editor, 7);
}

test "rendered long lines cross CRLF, empty lines, and file boundaries" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const long = try allocator.alloc(u8, 65536);
    defer allocator.free(long);
    @memset(long, 'x');
    @memcpy(long[long.len - 10 ..], "\r\ntail\r\n\r\n");
    try temp.dir.writeFile(.{ .sub_path = "a", .data = long });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "second\nlast" });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var workspace = try Workspace.open(allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(allocator, &workspace);
    defer editor.deinit();
    const frame = try editor.renderFrame(.{ .rows = 10, .cols = 80 });
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[2;1H\x1b[2Ktail") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[6;1H\x1b[2Ksecond") != null);
    try typeKeys(&editor, "jjjjj");
    try std.testing.expectEqual(@as(?usize, 1), editor.current_file);
    try expectStatusRow(&editor, 2);
    try typeKeys(&editor, "kk");
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try expectStatusRow(&editor, 4);
}

test "visual selection includes whole scalars and CRLF in either direction" {
    var doc = try testingDocument("aé界\r\nz");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "llvh");
    try std.testing.expectEqualDeep(Range{ .start = 1, .end = 6 }, editor.selection().?);
    try typeKeys(&editor, "o");
    try std.testing.expectEqual(@as(usize, 3), doc.buffer.cursor);
    try typeKeys(&editor, "y");
    try std.testing.expectEqualStrings("é界", editor.register.items);
    try std.testing.expectEqual(@as(usize, 1), doc.buffer.cursor);
    try std.testing.expect(!editor.dirty);
    try typeKeys(&editor, "$vy");
    try std.testing.expectEqualStrings("\r\n", editor.register.items);
    try typeKeys(&editor, "vVv\x1b");
    try std.testing.expect(editor.selection() == null);
    try std.testing.expectEqualStrings("aé界\r\nz", doc.buffer.bytes.items);
}

test "pending operators survive idle ticks and cancel on unrelated input" {
    var doc = try testingDocument("one\ntwo");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "y");
    _ = try editor.handle(.tick);
    try typeKeys(&editor, "y");
    try std.testing.expectEqualStrings("one\n", editor.register.items);
    try std.testing.expect(!editor.dirty);
    try typeKeys(&editor, "d\x1bd?y");
    _ = try editor.handle(.paste_start);
    try typeKeys(&editor, "dd:p");
    _ = try editor.handle(.paste_end);
    try std.testing.expect(editor.pending_operator == null);
    try std.testing.expectEqualStrings("one\ntwo", doc.buffer.bytes.items);
    try typeKeys(&editor, "dj");
    try std.testing.expectEqualStrings("", doc.buffer.bytes.items);
    try std.testing.expectEqualStrings("one\ntwo", editor.register.items);
}

test "line yanks paste above and below including empty and unterminated lines" {
    const cases = [_]struct { text: []const u8, keys: []const u8, result: []const u8 }{
        .{ .text = "one", .keys = "yyp", .result = "one\none" },
        .{ .text = "one", .keys = "YP", .result = "one\none" },
        .{ .text = "one\ntwo", .keys = "jYkP", .result = "two\none\ntwo" },
        .{ .text = "one\r\ntwo\r\n", .keys = "yyp", .result = "one\r\none\r\ntwo\r\n" },
        .{ .text = "one\r\ntwo", .keys = "jYp", .result = "one\r\ntwo\r\ntwo" },
        .{ .text = "one\n", .keys = "jYp", .result = "one\n\n" },
        .{ .text = "", .keys = "yyp", .result = "\n" },
        .{ .text = "", .keys = "YP", .result = "\n" },
        .{ .text = "one\n", .keys = "ddp", .result = "one\n" },
        .{ .text = "one", .keys = "ddp", .result = "one" },
    };
    for (cases) |case| {
        var doc = try testingDocument(case.text);
        defer doc.deinit();
        var editor = Editor.init(std.testing.allocator, &doc, "unused");
        defer editor.deinit();
        try typeKeys(&editor, case.keys);
        try std.testing.expectEqualStrings(case.result, doc.buffer.bytes.items);
        try std.testing.expect(editor.register_linewise);
        try std.testing.expectEqual(Mode.normal, editor.mode);
    }
}

test "character paste respects EOL and UTF-8 and keeps its source register" {
    var doc = try testingDocument("aéz\r\nnext");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "lvy$p");
    try std.testing.expectEqualStrings("aézé\r\nnext", doc.buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 4), doc.buffer.cursor);
    try typeKeys(&editor, "0P");
    try std.testing.expectEqualStrings("éaézé\r\nnext", doc.buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), doc.buffer.cursor);
    try std.testing.expectEqualStrings("é", editor.register.items);
}

test "delete and change lines preserve the appropriate neighboring separator" {
    const cases = [_]struct { text: []const u8, keys: []const u8, result: []const u8, register: []const u8 }{
        .{ .text = "one\ntwo", .keys = "jdd", .result = "one", .register = "two" },
        .{ .text = "one\ntwo\n", .keys = "jdd", .result = "one\n", .register = "two\n" },
        .{ .text = "one\r\ntwo", .keys = "jVd", .result = "one", .register = "two" },
        .{ .text = "one\r\n", .keys = "jdd", .result = "one", .register = "" },
        .{ .text = "one\ntwo\nthree", .keys = "jccX\x1b", .result = "one\nX\nthree", .register = "two\n" },
        .{ .text = "one\ntwo", .keys = "jVcX\x1b", .result = "one\nX", .register = "two" },
        .{ .text = "one\r\ntwo\r\nthree", .keys = "jccX\x1b", .result = "one\r\nX\r\nthree", .register = "two\r\n" },
        .{ .text = "one\ntwo\nthree", .keys = "VjcX\x1b", .result = "X\nthree", .register = "one\ntwo\n" },
        .{ .text = "one\ntwo", .keys = "lD", .result = "o\ntwo", .register = "ne" },
        .{ .text = "one\ntwo", .keys = "lCX\x1b", .result = "oX\ntwo", .register = "ne" },
    };
    for (cases) |case| {
        var doc = try testingDocument(case.text);
        defer doc.deinit();
        var editor = Editor.init(std.testing.allocator, &doc, "unused");
        defer editor.deinit();
        try typeKeys(&editor, case.keys);
        try std.testing.expectEqualStrings(case.result, doc.buffer.bytes.items);
        try std.testing.expectEqualStrings(case.register, editor.register.items);
        try std.testing.expect(editor.dirty);
        try std.testing.expectEqual(Mode.normal, editor.mode);
    }
}

test "empty changes enter insert without marking unchanged bytes dirty" {
    const cases = [_]struct { text: []const u8, keys: []const u8 }{
        .{ .text = "", .keys = "cc" },
        .{ .text = "one\n", .keys = "jcc" },
        .{ .text = "\r\n", .keys = "Vc" },
        .{ .text = "one", .keys = "$C" },
    };
    for (cases) |case| {
        var doc = try testingDocument(case.text);
        defer doc.deinit();
        var editor = Editor.init(std.testing.allocator, &doc, "unused");
        defer editor.deinit();
        try typeKeys(&editor, case.keys);
        try std.testing.expect(!editor.dirty);
        try std.testing.expectEqual(Mode.insert, editor.mode);
        try std.testing.expectEqualStrings(case.text, doc.buffer.bytes.items);
    }
}

test "visual replacement handles mixed register kinds and retains source" {
    const cases = [_]struct { text: []const u8, keys: []const u8, result: []const u8, register: []const u8 }{
        .{ .text = "ab xx yy", .keys = "vly0lllvlp0llllllvlP", .result = "ab ab ab", .register = "ab" },
        .{ .text = "foo\nabc", .keys = "YjlvP", .result = "foo\na\nfoo\nc", .register = "foo\n" },
        .{ .text = "abc\nfoo", .keys = "jYklvp", .result = "a\nfoo\nc\nfoo", .register = "foo" },
        .{ .text = "abc\nfoo\nkeep", .keys = "vlyjVP", .result = "abc\nab\nkeep", .register = "ab" },
        .{ .text = "abc\nfoo", .keys = "vlyjVp", .result = "abc\nab", .register = "ab" },
        .{ .text = "abc\nfoo", .keys = "jYkVP", .result = "foo\nfoo", .register = "foo" },
    };
    for (cases) |case| {
        var doc = try testingDocument(case.text);
        defer doc.deinit();
        var editor = Editor.init(std.testing.allocator, &doc, "unused");
        defer editor.deinit();
        try typeKeys(&editor, case.keys);
        try std.testing.expectEqualStrings(case.result, doc.buffer.bytes.items);
        try std.testing.expectEqualStrings(case.register, editor.register.items);
    }
}

test "visual highlights clip wide text and tabs and show selected empty lines" {
    var doc = try testingDocument("界\t\x1b\n\n");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "vll");
    editor.left_column = 1;
    try editor.drawLine(0, 5, 5);
    try std.testing.expectEqualStrings("\x1b[7m   ^[\x1b[27m", editor.frame.items);
    editor.frame.clearRetainingCapacity();
    try typeKeys(&editor, "\x1bj0v");
    editor.left_column = 0;
    try editor.drawLine(6, 6, 5);
    try std.testing.expectEqualStrings("\x1b[7m \x1b[27m", editor.frame.items);
    editor.frame.clearRetainingCapacity();
    try typeKeys(&editor, "\x1bjV");
    try editor.drawLine(7, 7, 5);
    try std.testing.expectEqualStrings("\x1b[7m     \x1b[27m", editor.frame.items);
}

test "bracketed paste advances the viewport once and clamps it to the screen" {
    var doc = try testingDocument("head\nend");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    editor.height = 4;
    try typeKeys(&editor, "ji");
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    _ = try editor.handle(.paste_start);
    try typeKeys(&editor, "a\r\nb\r\nc\r\nd");
    try std.testing.expectEqualStrings("head\na\nb\nc\ndend", doc.buffer.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    try std.testing.expectEqual(@as(?usize, 1), editor.paste_origin_row);
    _ = try editor.handle(.tick);
    try std.testing.expect(editor.pasting);
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    _ = try editor.handle(.paste_end);
    try std.testing.expectEqual(@as(usize, 3), editor.screen_row);
    try std.testing.expect(editor.paste_origin_row == null);
    try std.testing.expect(!editor.pasting);
}

test "idle ticks preserve the cursor viewport and selection" {
    var doc = try testingDocument("one\ntwo\nthree");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "jvl");
    const cursor = doc.buffer.cursor;
    const row = editor.screen_row;
    const selected = editor.selection();
    for (0..5) |_| try std.testing.expect(!try editor.handle(.tick));
    try std.testing.expectEqual(cursor, doc.buffer.cursor);
    try std.testing.expectEqual(row, editor.screen_row);
    try std.testing.expectEqualDeep(selected, editor.selection());
    try std.testing.expectEqualStrings("one\ntwo\nthree", doc.buffer.bytes.items);
}

test "page movement scrolls a viewport while retaining the cursor screen row" {
    var doc = try testingDocument("0\n1\n2\n3\n4\n5\n6\n7\n8\n9");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    editor.height = 3;
    try typeKeys(&editor, "j");
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    _ = try editor.handle(.page_down);
    try std.testing.expectEqual(@as(usize, 8), doc.buffer.cursor);
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    _ = try editor.handle(.page_down);
    try std.testing.expectEqual(@as(usize, 14), doc.buffer.cursor);
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    _ = try editor.handle(.page_up);
    try std.testing.expectEqual(@as(usize, 8), doc.buffer.cursor);
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
    _ = try editor.handle(.page_up);
    try std.testing.expectEqual(@as(usize, 2), doc.buffer.cursor);
    try std.testing.expectEqual(@as(usize, 1), editor.screen_row);
}

test "page movement includes separators between short files" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for ("abcdefgh") |name| try temp.dir.writeFile(.{ .sub_path = &.{name}, .data = &.{name} });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    editor.height = 4;
    _ = try editor.handle(.page_down);
    try std.testing.expectEqual(@as(?usize, 2), editor.current_file);
    try std.testing.expectEqual(@as(usize, 0), editor.screen_row);
    _ = try editor.handle(.page_up);
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    try std.testing.expectEqual(@as(usize, 0), editor.screen_row);
}

fn finishSearch(editor: *Editor) !void {
    var timer = try std.time.Timer.start();
    while (editor.search_job != null or editor.search_next != null) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.SearchDidNotFinish;
        _ = try editor.handle(.tick);
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
}

test "workspace scanning neither admits buffers nor changes cache recency" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..20) |index| {
        var name: [32]u8 = undefined;
        try temp.dir.writeFile(.{ .sub_path = try std.fmt.bufPrint(&name, "file{d:0>2}", .{index}), .data = "ordinary text\n" });
    }
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    _ = try workspace.ensure(1);
    _ = try workspace.ensure(2);
    const clock_before = workspace.clock;
    const entries_before = try std.testing.allocator.dupe(@TypeOf(workspace.entries.items[0]), workspace.entries.items);
    defer std.testing.allocator.free(entries_before);
    try typeKeys(&editor, "/absent\r");
    try finishSearch(&editor);
    try std.testing.expectEqualStrings("Pattern not found", editor.message[0..editor.message_len]);
    try std.testing.expectEqual(clock_before, workspace.clock);
    try std.testing.expectEqual(@as(usize, 3), workspace.resident.items.len);
    for (entries_before, workspace.entries.items) |before, after| {
        try std.testing.expectEqual(before.document, after.document);
        try std.testing.expectEqual(before.last_used, after.last_used);
        try std.testing.expectEqual(before.line_count, after.line_count);
        try std.testing.expectEqual(before.revision, after.revision);
        try std.testing.expectEqual(before.load_error, after.load_error);
    }
}

test "a completed search cannot jump after the user starts editing" {
    var doc = try testingDocument("first second");
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "unused");
    defer editor.deinit();
    try typeKeys(&editor, "/second\r");
    const job = editor.search_job.?;
    var timer = try std.time.Timer.start();
    while (!job.isDone()) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.SearchDidNotFinish;
        _ = job.service(&editor, Editor.searchSource);
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try typeKeys(&editor, "iX");
    try finishSearch(&editor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try std.testing.expectEqual(@as(usize, 1), doc.buffer.cursor);
    try std.testing.expectEqualStrings("Xfirst second", doc.buffer.bytes.items);
}

test "search prepares only the matching document and preserves editable ownership" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "origin" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "no occurrence" });
    try temp.dir.writeFile(.{ .sub_path = "c", .data = "one\r\ntwo\r\nneedle" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    try typeKeys(&editor, "/needle\r");
    try finishSearch(&editor);
    try std.testing.expect(workspace.entries.items[1].document == null);
    try std.testing.expectEqual(@as(?usize, 2), editor.current_file);
    try std.testing.expectEqual(@as(usize, 10), editor.document.buffer.cursor);
    try std.testing.expectEqual(@as(usize, 2), editor.document.buffer.cursor_row);
    try std.testing.expectEqual(@as(?usize, 3), workspace.entries.items[2].line_count);
    try typeKeys(&editor, "iX\x1b");
    try std.testing.expectEqualStrings("one\r\ntwo\r\nXneedle", editor.document.buffer.bytes.items);
    try std.testing.expect(workspace.entries.items[2].dirty);
}

test "asynchronous rendering leaves pending documents to the loader" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "origin" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "neighbor" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    var editor = try Editor.initWorkspace(std.testing.allocator, &workspace);
    defer editor.deinit();
    editor.stream.?.async_load = true;
    _ = try editor.renderFrame(.{ .rows = 5, .cols = 40 });
    try std.testing.expect(workspace.hasPendingRequest());
    try std.testing.expect(workspace.entries.items[1].document == null);
    try std.testing.expectEqual(@as(?usize, 0), editor.current_file);
    // Even after the worker finishes, rendering itself cannot admit its result.
    while (!workspace.requested.?.isDone()) std.Thread.sleep(100 * std.time.ns_per_us);
    _ = try editor.renderFrame(.{ .rows = 5, .cols = 40 });
    try std.testing.expect(workspace.entries.items[1].document == null);
    _ = try editor.handle(.tick);
    const frame = try editor.renderFrame(.{ .rows = 5, .cols = 40 });
    try std.testing.expect(std.mem.indexOf(u8, frame, "neighbor") != null);
}

test "long-line search retains correct display anchors across redraw and resize" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendNTimes(std.testing.allocator, 'a', search.chunk_size * 8 + 1);
    try bytes.appendSlice(std.testing.allocator, "\t界 needle tail\r\nnext");
    var doc = try testingDocument(bytes.items);
    defer doc.deinit();
    var editor = Editor.init(std.testing.allocator, &doc, "long-line");
    defer editor.deinit();
    try typeKeys(&editor, "/needle\r");
    try finishSearch(&editor);
    const offset = std.mem.indexOf(u8, bytes.items, "needle").?;
    const column = display.columns(bytes.items[0..offset]);
    try std.testing.expectEqual(offset, doc.buffer.cursor);
    try std.testing.expectEqual(column, editor.cursorColumn());
    try std.testing.expect(editor.search_projection.?.anchors.len > 1);
    const anchors = editor.search_projection.?.anchors.ptr;
    for ([_]u16{ 80, 30, 120 }) |width| {
        const frame = try editor.renderFrame(.{ .rows = 5, .cols = width });
        var expected: [64]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, frame, try std.fmt.bufPrint(&expected, "1:{d}", .{column + 1})) != null);
        try std.testing.expectEqual(anchors, editor.search_projection.?.anchors.ptr);
    }
    try typeKeys(&editor, ":");
    _ = try editor.renderFrame(.{ .rows = 5, .cols = 80 });
    try std.testing.expectEqual(anchors, editor.search_projection.?.anchors.ptr);
    try typeKeys(&editor, "\x1bn");
    try finishSearch(&editor);
    try std.testing.expectEqualStrings("Search wrapped", editor.message[0..editor.message_len]);
    try std.testing.expectEqual(anchors, editor.search_projection.?.anchors.ptr);
    try typeKeys(&editor, "h");
    _ = try editor.renderFrame(.{ .rows = 5, .cols = 80 });
    try std.testing.expectEqual(column - 1, editor.cursorColumn());
    try typeKeys(&editor, "iX");
    try std.testing.expect(editor.search_projection == null);
}
