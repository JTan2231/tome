const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

var interrupted = std.atomic.Value(bool).init(false);
var restored = std.atomic.Value(bool).init(true);

pub fn isInterrupted() bool {
    return interrupted.load(.monotonic);
}

fn handleControl(event: windows.DWORD) callconv(.winapi) windows.BOOL {
    switch (event) {
        windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT => {
            interrupted.store(true, .monotonic);
            return windows.TRUE;
        },
        windows.CTRL_CLOSE_EVENT, windows.CTRL_LOGOFF_EVENT, windows.CTRL_SHUTDOWN_EVENT => {
            interrupted.store(true, .monotonic);
            // Returning from a close handler terminates the process. Give the
            // input loop time to unwind and restore the terminal first.
            for (0..300) |_| {
                if (restored.load(.acquire)) break;
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            return windows.TRUE;
        },
        else => return windows.FALSE,
    }
}

const KeyEvent = extern struct {
    down: windows.BOOL,
    repeat: windows.WORD,
    virtual_key: windows.WORD,
    scan_code: windows.WORD,
    unicode: windows.WCHAR,
    control: windows.DWORD,
};

const InputRecord = extern struct {
    event_type: windows.WORD,
    event: extern union {
        key: KeyEvent,
        // MOUSE_EVENT_RECORD is the largest member of the Windows union.
        storage: [16]u8,
    },
};

extern "kernel32" fn ReadConsoleInputW(windows.HANDLE, [*]InputRecord, windows.DWORD, *windows.DWORD) callconv(.winapi) windows.BOOL;

pub const Console = struct {
    input: windows.HANDLE,
    output: windows.HANDLE,
    input_mode: windows.DWORD,
    output_mode: windows.DWORD,
    output_code_page: windows.UINT,
    encoded: [8]u8 = undefined,
    encoded_len: usize = 0,
    encoded_pos: usize = 0,
    repeats: u16 = 0,
    high_surrogate: ?u16 = null,

    pub fn init() !Console {
        var self: Console = .{
            .input = try windows.GetStdHandle(windows.STD_INPUT_HANDLE),
            .output = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE),
            .input_mode = undefined,
            .output_mode = undefined,
            .output_code_page = kernel32.GetConsoleOutputCP(),
        };
        if (kernel32.GetConsoleMode(self.input, &self.input_mode) == 0 or
            kernel32.GetConsoleMode(self.output, &self.output_mode) == 0) return error.NotATerminal;

        // VT input retains escape sequences (including bracketed paste) in key
        // records. ReadConsoleInputW still reports resize events in this mode.
        // Disable line editing, echo, Ctrl-C processing and Quick Edit.
        if (kernel32.SetConsoleMode(self.input, 0x0200 | 0x0080 | 0x0008) == 0) return error.ConsoleModeFailed;
        errdefer _ = kernel32.SetConsoleMode(self.input, self.input_mode);
        const output_mode = self.output_mode | 0x0001 | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.DISABLE_NEWLINE_AUTO_RETURN;
        if (kernel32.SetConsoleMode(self.output, output_mode) == 0) return error.VirtualTerminalUnsupported;
        errdefer _ = kernel32.SetConsoleMode(self.output, self.output_mode);
        if (kernel32.SetConsoleOutputCP(65001) == 0) return error.ConsoleCodePageFailed;
        errdefer _ = kernel32.SetConsoleOutputCP(self.output_code_page);

        interrupted.store(false, .monotonic);
        restored.store(false, .release);
        errdefer restored.store(true, .release);
        try windows.SetConsoleCtrlHandler(handleControl, true);
        return self;
    }

    pub fn deinit(self: *const Console) void {
        _ = kernel32.SetConsoleMode(self.input, self.input_mode);
        _ = kernel32.SetConsoleMode(self.output, self.output_mode);
        _ = kernel32.SetConsoleOutputCP(self.output_code_page);
        restored.store(true, .release);
        windows.SetConsoleCtrlHandler(handleControl, false) catch {};
    }

    pub fn size(self: *const Console) struct { rows: usize, cols: usize } {
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(self.output, &info) == 0) return .{ .rows = 24, .cols = 80 };
        return .{
            .rows = @intCast(@max(1, @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1)),
            .cols = @intCast(@max(1, @as(i32, info.srWindow.Right) - info.srWindow.Left + 1)),
        };
    }

    pub fn writeAll(self: *const Console, bytes: []const u8) !void {
        try (std.fs.File{ .handle = self.output }).writeAll(bytes);
    }

    pub fn readByte(self: *Console, timeout_ms: i32) !?u8 {
        if (self.takeEncoded()) |byte| return byte;
        var timer = try std.time.Timer.start();
        while (!isInterrupted()) {
            const elapsed = timer.read() / std.time.ns_per_ms;
            const remaining: u32 = if (timeout_ms < 0) windows.INFINITE else @intCast(@as(u64, @intCast(timeout_ms)) -| elapsed);
            windows.WaitForSingleObject(self.input, remaining) catch |err| switch (err) {
                error.WaitTimeOut => return null,
                else => return err,
            };
            var record: InputRecord = undefined;
            var count: windows.DWORD = 0;
            if (ReadConsoleInputW(self.input, @ptrCast(&record), 1, &count) == 0) return error.ConsoleInputFailed;
            if (count == 0) return null;
            if (record.event_type == 0x0004) return null; // Resize: redraw now.
            if (record.event_type == 0x0001) self.encodeKey(record.event.key);
            if (self.takeEncoded()) |byte| return byte;
            if (timeout_ms >= 0 and elapsed >= @as(u32, @intCast(timeout_ms))) return null;
        }
        return null;
    }

    fn takeEncoded(self: *Console) ?u8 {
        if (self.repeats == 0) return null;
        const byte = self.encoded[self.encoded_pos];
        self.encoded_pos += 1;
        if (self.encoded_pos == self.encoded_len) {
            self.encoded_pos = 0;
            self.repeats -= 1;
        }
        return byte;
    }

    fn encodeKey(self: *Console, key: KeyEvent) void {
        // ConPTY and Alt+numpad composition can deliver Unicode (including
        // surrogate pairs) on VK_MENU release. Other releases repeat the
        // preceding press and must not insert the character a second time.
        if (key.down == 0 and (key.virtual_key != 0x12 or key.unicode == 0)) return;
        var scalar: u21 = key.unicode;
        if (scalar >= 0xd800 and scalar <= 0xdbff) {
            self.high_surrogate = key.unicode;
            return;
        }
        if (scalar >= 0xdc00 and scalar <= 0xdfff) {
            const high = self.high_surrogate orelse return;
            scalar = 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (scalar - 0xdc00);
        }
        self.high_surrogate = null;
        if (scalar != 0) {
            self.encoded_len = std.unicode.utf8Encode(scalar, &self.encoded) catch return;
        } else {
            const sequence: []const u8 = switch (key.virtual_key) {
                0x21 => "\x1b[5~", // Page Up
                0x22 => "\x1b[6~", // Page Down
                0x23 => "\x1b[F", // End
                0x24 => "\x1b[H", // Home
                0x25 => "\x1b[D", // Left
                0x26 => "\x1b[A", // Up
                0x27 => "\x1b[C", // Right
                0x28 => "\x1b[B", // Down
                0x2e => "\x1b[3~", // Delete
                else => return,
            };
            @memcpy(self.encoded[0..sequence.len], sequence);
            self.encoded_len = sequence.len;
        }
        self.encoded_pos = 0;
        self.repeats = @max(1, key.repeat);
    }
};

test "Windows Unicode key records preserve characters, surrogate pairs and repeats" {
    var console: Console = .{
        .input = undefined,
        .output = undefined,
        .input_mode = 0,
        .output_mode = 0,
        .output_code_page = 0,
    };
    var key: KeyEvent = .{ .down = 1, .repeat = 2, .virtual_key = 0, .scan_code = 0, .unicode = 0x00e9, .control = 0 };
    console.encodeKey(key);
    for ("éé") |byte| try std.testing.expectEqual(byte, console.takeEncoded().?);
    try std.testing.expectEqual(null, console.takeEncoded());
    key.repeat = 1;
    key.unicode = 0xd83d;
    console.encodeKey(key);
    try std.testing.expectEqual(null, console.takeEncoded());
    key.unicode = 0xde00;
    console.encodeKey(key);
    for ("😀") |byte| try std.testing.expectEqual(byte, console.takeEncoded().?);
    key.unicode = 0;
    key.virtual_key = 0x25;
    console.encodeKey(key);
    for ("\x1b[D") |byte| try std.testing.expectEqual(byte, console.takeEncoded().?);
    key.down = 0;
    console.encodeKey(key);
    try std.testing.expectEqual(null, console.takeEncoded());
}

test "ConPTY Unicode Alt release records are text but ordinary releases are ignored" {
    var console: Console = .{
        .input = undefined,
        .output = undefined,
        .input_mode = 0,
        .output_mode = 0,
        .output_code_page = 0,
    };
    var key: KeyEvent = .{ .down = 0, .repeat = 1, .virtual_key = 0x12, .scan_code = 0, .unicode = 0x00e9, .control = 0 };
    console.encodeKey(key);
    for ("é") |byte| try std.testing.expectEqual(byte, console.takeEncoded().?);
    key.unicode = 0xd83d;
    console.encodeKey(key);
    try std.testing.expectEqual(null, console.takeEncoded());
    key.unicode = 0xde00;
    console.encodeKey(key);
    for ("😀") |byte| try std.testing.expectEqual(byte, console.takeEncoded().?);
    key.virtual_key = 'A';
    key.unicode = 'a';
    key.down = 1;
    console.encodeKey(key);
    try std.testing.expectEqual(@as(u8, 'a'), console.takeEncoded().?);
    key.down = 0;
    console.encodeKey(key);
    try std.testing.expectEqual(null, console.takeEncoded());
    key.virtual_key = 0x12;
    key.unicode = 0;
    console.encodeKey(key);
    try std.testing.expectEqual(null, console.takeEncoded());
}
