const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Backend = if (builtin.os.tag == .windows) @import("terminal_windows.zig").Console else PosixTerminal;
const input = posix.STDIN_FILENO;
const output = posix.STDOUT_FILENO;
const sequence_timeout_ms = 50;
const idle_timeout_ms = 100;
const exit_signals = [_]u8{ posix.SIG.HUP, posix.SIG.INT, posix.SIG.QUIT, posix.SIG.TERM };
var interrupted = std.atomic.Value(bool).init(false);

fn handleSignal(_: i32) callconv(.c) void {
    // Cleanup belongs to the main loop, where normal Zig I/O is safe.
    interrupted.store(true, .monotonic);
}

pub const Size = struct {
    rows: usize,
    cols: usize,
};

pub const Text = struct {
    bytes: [4]u8,
    len: u3,
};

pub const Key = union(enum) {
    byte: u8,
    text: Text,
    escape,
    up,
    down,
    left,
    right,
    ctrl_left,
    ctrl_right,
    home,
    end,
    delete,
    page_up,
    page_down,
    paste_start,
    paste_end,
    tick,
    unknown,
    eof,
};

pub const Terminal = struct {
    backend: Backend,
    pending: [8]u8 = undefined,
    pending_start: usize = 0,
    pending_len: usize = 0,
    pasting: bool = false,
    at_eof: bool = false,

    pub fn init() !Terminal {
        return .{ .backend = try Backend.init() };
    }

    pub fn deinit(self: *const Terminal) void {
        self.backend.deinit();
    }

    pub fn size(self: *const Terminal) Size {
        return self.backend.size();
    }

    pub fn writeAll(self: *const Terminal, bytes: []const u8) !void {
        try self.backend.writeAll(bytes);
    }

    pub fn readKey(self: *Terminal) !Key {
        return self.readKeyTimeout(idle_timeout_ms);
    }

    pub fn readKeyTimeout(self: *Terminal, timeout_ms: i32) !Key {
        if (self.at_eof or Backend.isInterrupted()) return .eof;
        const byte = (try self.readByte(timeout_ms)) orelse {
            return if (self.at_eof or Backend.isInterrupted()) .eof else .tick;
        };
        if (self.pasting) return self.readPaste(byte);
        if (byte == 0x1b) return self.readEscape();
        if (byte < 0x80) return .{ .byte = byte };

        var text: Text = .{
            .bytes = .{ byte, 0, 0, 0 },
            .len = std.unicode.utf8ByteSequenceLength(byte) catch return .unknown,
        };
        for (text.bytes[1..text.len]) |*continuation| {
            const next = (try self.readByte(sequence_timeout_ms)) orelse return .unknown;
            if (next & 0xc0 != 0x80) {
                self.queue(&.{next});
                return .unknown;
            }
            continuation.* = next;
        }
        if (!std.unicode.utf8ValidateSlice(text.bytes[0..text.len])) return .unknown;
        return .{ .text = text };
    }

    fn readEscape(self: *Terminal) !Key {
        const prefix = (try self.readByte(sequence_timeout_ms)) orelse return .escape;
        if (prefix != '[' and prefix != 'O') {
            self.queue(&.{prefix});
            return .escape;
        }

        var sequence: [64]u8 = undefined;
        sequence[0] = prefix;
        var len: usize = 1;
        // CSI and SS3 keys end in a byte from 0x40 through 0x7e.
        while (len < sequence.len) {
            const byte = (try self.readByte(sequence_timeout_ms)) orelse return .unknown;
            sequence[len] = byte;
            len += 1;
            if (byte >= 0x40 and byte <= 0x7e) {
                const key = decodeSequence(sequence[0..len]);
                if (key == .paste_start) self.pasting = true;
                return key;
            }
            if (byte < 0x20 or byte > 0x3f) {
                self.queue(&.{byte});
                return .unknown;
            }
        }
        return .unknown;
    }

    fn readPaste(self: *Terminal, byte: u8) !Key {
        if (byte != 0x1b) return .{ .byte = byte };
        const suffix = "[201~";
        var consumed: [suffix.len]u8 = undefined;
        var len: usize = 0;
        for (suffix) |expected| {
            const next = (try self.readByte(sequence_timeout_ms)) orelse break;
            consumed[len] = next;
            len += 1;
            if (next != expected) break;
        }
        if (std.mem.eql(u8, consumed[0..len], suffix)) {
            self.pasting = false;
            return .paste_end;
        }
        // Escape sequences inside a paste are literal file content, never keys.
        self.queue(consumed[0..len]);
        return .{ .byte = byte };
    }

    fn queue(self: *Terminal, bytes: []const u8) void {
        const remaining = self.pending_len - self.pending_start;
        std.debug.assert(bytes.len + remaining <= self.pending.len);
        const destination = self.pending[bytes.len..][0..remaining];
        const source = self.pending[self.pending_start..self.pending_len];
        if (bytes.len >= self.pending_start) {
            std.mem.copyBackwards(u8, destination, source);
        } else {
            std.mem.copyForwards(u8, destination, source);
        }
        @memcpy(self.pending[0..bytes.len], bytes);
        self.pending_start = 0;
        self.pending_len = bytes.len + remaining;
    }

    fn readByte(self: *Terminal, timeout_ms: i32) !?u8 {
        if (Backend.isInterrupted()) return null;
        if (self.pending_start < self.pending_len) {
            const byte = self.pending[self.pending_start];
            self.pending_start += 1;
            return byte;
        }
        return self.backend.readByte(timeout_ms) catch |err| switch (err) {
            error.EndOfStream => {
                self.at_eof = true;
                return null;
            },
            else => return err,
        };
    }
};

const PosixTerminal = struct {
    original: posix.termios,
    original_signals: [exit_signals.len]posix.Sigaction,

    fn init() !PosixTerminal {
        if (!posix.isatty(input) or !posix.isatty(output)) return error.NotATerminal;

        const original = try posix.tcgetattr(input);
        var raw = original;
        raw.iflag = .{};
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(input, .FLUSH, raw);

        interrupted.store(false, .monotonic);
        var terminal: PosixTerminal = .{ .original = original, .original_signals = undefined };
        const action: posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        for (exit_signals, &terminal.original_signals) |signal, *saved| {
            posix.sigaction(signal, &action, saved);
        }
        return terminal;
    }

    fn deinit(self: *const PosixTerminal) void {
        posix.tcsetattr(input, .FLUSH, self.original) catch {};
        for (exit_signals, &self.original_signals) |signal, *saved| {
            posix.sigaction(signal, saved, null);
        }
    }

    fn size(_: *const PosixTerminal) Size {
        var window: posix.winsize = undefined;
        const result = if (builtin.os.tag == .linux and !builtin.link_libc)
            posix.errno(std.os.linux.ioctl(output, posix.T.IOCGWINSZ, @intFromPtr(&window)))
        else
            posix.errno(posix.system.ioctl(output, @intCast(posix.T.IOCGWINSZ), &window));
        if (result != .SUCCESS) return .{ .rows = 24, .cols = 80 };

        return .{
            .rows = if (window.row == 0) 24 else window.row,
            .cols = if (window.col == 0) 80 else window.col,
        };
    }

    fn writeAll(_: *const PosixTerminal, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            const written = try posix.write(output, remaining);
            if (written == 0) return error.EndOfStream;
            remaining = remaining[written..];
        }
    }

    fn isInterrupted() bool {
        return interrupted.load(.monotonic);
    }

    fn readByte(_: *PosixTerminal, timeout_ms: i32) !?u8 {
        var fds = [_]posix.pollfd{.{ .fd = input, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, timeout_ms) == 0) return null;
        if (interrupted.load(.monotonic)) return null;

        var byte: [1]u8 = undefined;
        if (try posix.read(input, &byte) == 0) return error.EndOfStream;
        return byte[0];
    }
};

fn decodeSequence(sequence: []const u8) Key {
    if (sequence.len < 2) return .unknown;
    const prefix = sequence[0];
    if (prefix != '[' and prefix != 'O') return .unknown;
    const params = sequence[1 .. sequence.len - 1];
    // Ignore mouse reports, terminal replies, and other non-key sequences.
    for (params) |byte| {
        if (!(byte >= '0' and byte <= '9') and byte != ';') return .unknown;
    }
    const shift = prefix == '[' and std.mem.eql(u8, params, "1;2");
    const ctrl = prefix == '[' and std.mem.eql(u8, params, "1;5");
    return switch (sequence[sequence.len - 1]) {
        'A' => if (shift) .page_up else .up,
        'B' => if (shift) .page_down else .down,
        'C' => if (ctrl) .ctrl_right else .right,
        'D' => if (ctrl) .ctrl_left else .left,
        'H' => .home,
        'F' => .end,
        '~' => blk: {
            if (prefix != '[') break :blk .unknown;
            if (std.mem.eql(u8, params, "200")) break :blk .paste_start;
            if (std.mem.eql(u8, params, "201")) break :blk .paste_end;
            if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) break :blk .home;
            if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) break :blk .end;
            if (std.mem.eql(u8, params, "3")) break :blk .delete;
            if (std.mem.eql(u8, params, "5")) break :blk .page_up;
            if (std.mem.eql(u8, params, "6")) break :blk .page_down;
            break :blk .unknown;
        },
        else => .unknown,
    };
}

test "Ghostty cursor, editing, and bracketed paste sequences" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(Key.up, decodeSequence("[A"));
    try expectEqual(Key.down, decodeSequence("OB"));
    try expectEqual(Key.right, decodeSequence("[1;2C"));
    try expectEqual(Key.left, decodeSequence("[D"));
    try expectEqual(Key.ctrl_left, decodeSequence("[1;5D"));
    try expectEqual(Key.ctrl_right, decodeSequence("[1;5C"));
    try expectEqual(Key.home, decodeSequence("[H"));
    try expectEqual(Key.end, decodeSequence("OF"));
    try expectEqual(Key.delete, decodeSequence("[3~"));
    try expectEqual(Key.page_up, decodeSequence("[5~"));
    try expectEqual(Key.page_down, decodeSequence("[6~"));
    try expectEqual(Key.page_up, decodeSequence("[1;2A"));
    try expectEqual(Key.page_down, decodeSequence("[1;2B"));
    try expectEqual(Key.paste_start, decodeSequence("[200~"));
    try expectEqual(Key.paste_end, decodeSequence("[201~"));
    try expectEqual(Key.unknown, decodeSequence("[<0;12;4M"));
    try expectEqual(Key.unknown, decodeSequence("[?1;2c"));
    try expectEqual(Key.unknown, decodeSequence("[15~"));
}

test "pending bytes preserve order when a paste escape is literal" {
    var terminal: Terminal = .{ .backend = undefined };
    terminal.queue("old");
    terminal.pending_start = 1;
    terminal.queue("new");
    try std.testing.expectEqualStrings("newld", terminal.pending[0..terminal.pending_len]);
}

test "paste escape sequences stay literal until the exact end marker" {
    var terminal: Terminal = .{ .backend = undefined, .pasting = true };
    terminal.queue("[A");
    try std.testing.expectEqual(Key{ .byte = 0x1b }, try terminal.readPaste(0x1b));
    try std.testing.expectEqual(Key{ .byte = '[' }, try terminal.readKey());
    try std.testing.expectEqual(Key{ .byte = 'A' }, try terminal.readKey());
    try std.testing.expect(terminal.pasting);

    terminal.queue("[201~");
    try std.testing.expectEqual(Key.paste_end, try terminal.readPaste(0x1b));
    try std.testing.expect(!terminal.pasting);
}
