const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const Size = @import("terminal.zig").Size;

const enable_processed_input = 0x0001;
const enable_line_input = 0x0002;
const enable_echo_input = 0x0004;
const enable_window_input = 0x0008;
const enable_mouse_input = 0x0010;
const enable_quick_edit_mode = 0x0040;
const enable_extended_flags = 0x0080;
const enable_virtual_terminal_input = 0x0200;
const enable_processed_output = 0x0001;
const key_event = 0x0001;
const ctrl_break_event = 1;

const KeyEvent = extern struct {
    down: windows.BOOL,
    repeats: u16,
    virtual_key: u16,
    scan_code: u16,
    code_unit: u16,
    control_key_state: windows.DWORD,
};

// KEY_EVENT_RECORD has the same size and alignment as the INPUT_RECORD union.
const InputRecord = extern struct {
    kind: u16,
    key: KeyEvent,
};

extern "kernel32" fn ReadConsoleInputW(
    input: windows.HANDLE,
    records: *InputRecord,
    length: windows.DWORD,
    read: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

var interrupted = std.atomic.Value(bool).init(false);

fn handleControlEvent(event: windows.DWORD) callconv(.winapi) windows.BOOL {
    if (event != ctrl_break_event) return windows.FALSE;
    interrupted.store(true, .monotonic);
    return windows.TRUE;
}

pub const Console = struct {
    input: windows.HANDLE,
    output: windows.HANDLE,
    input_mode: windows.DWORD,
    output_mode: windows.DWORD,
    high_surrogate: ?u16 = null,
    bytes: [8]u8 = undefined,
    byte_count: usize = 0,
    byte_index: usize = 0,
    repeats: u16 = 0,

    pub fn init() !Console {
        const input = kernel32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return error.NotATerminal;
        const output = kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return error.NotATerminal;
        var input_mode: windows.DWORD = undefined;
        var output_mode: windows.DWORD = undefined;
        if (kernel32.GetConsoleMode(input, &input_mode) == 0 or kernel32.GetConsoleMode(output, &output_mode) == 0)
            return error.NotATerminal;

        const disabled_input = enable_processed_input | enable_line_input | enable_echo_input |
            enable_window_input | enable_mouse_input | enable_quick_edit_mode;
        const raw_input = (input_mode & ~@as(windows.DWORD, disabled_input)) |
            enable_extended_flags | enable_virtual_terminal_input;
        const raw_output = output_mode | enable_processed_output |
            windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.DISABLE_NEWLINE_AUTO_RETURN;
        if (kernel32.SetConsoleMode(input, raw_input) == 0)
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = kernel32.SetConsoleMode(input, input_mode);
        if (kernel32.SetConsoleMode(output, raw_output) == 0)
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = kernel32.SetConsoleMode(output, output_mode);

        interrupted.store(false, .monotonic);
        if (kernel32.SetConsoleCtrlHandler(handleControlEvent, windows.TRUE) == 0)
            return windows.unexpectedError(windows.GetLastError());

        return .{ .input = input, .output = output, .input_mode = input_mode, .output_mode = output_mode };
    }

    pub fn deinit(self: *const Console) void {
        _ = kernel32.SetConsoleMode(self.output, self.output_mode);
        _ = kernel32.SetConsoleMode(self.input, self.input_mode);
        _ = kernel32.SetConsoleCtrlHandler(handleControlEvent, windows.FALSE);
    }

    pub fn size(self: *const Console) Size {
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(self.output, &info) == 0)
            return .{ .rows = 24, .cols = 80 };
        const window = info.srWindow;
        const rows = @as(i32, window.Bottom) - window.Top + 1;
        const cols = @as(i32, window.Right) - window.Left + 1;
        return .{
            .rows = if (rows > 0) @intCast(rows) else 24,
            .cols = if (cols > 0) @intCast(cols) else 80,
        };
    }

    pub fn writeAll(self: *const Console, bytes: []const u8) !void {
        var remaining = bytes;
        var wide: [4096]u16 = undefined;
        while (remaining.len != 0) {
            var end = @min(wide.len, remaining.len);
            // Keep UTF-8 scalars together across writes.
            while (end > 0 and end < remaining.len and remaining[end] & 0xc0 == 0x80) end -= 1;
            if (end == 0) return error.InvalidUtf8;
            const len = try std.unicode.utf8ToUtf16Le(&wide, remaining[0..end]);
            var offset: usize = 0;
            while (offset < len) {
                var written: windows.DWORD = undefined;
                if (kernel32.WriteConsoleW(self.output, wide[offset..len].ptr, @intCast(len - offset), &written, null) == 0)
                    return windows.unexpectedError(windows.GetLastError());
                if (written == 0) return error.EndOfStream;
                offset += written;
            }
            remaining = remaining[end..];
        }
    }

    pub fn isInterrupted() bool {
        return interrupted.load(.monotonic);
    }

    pub fn readByte(self: *Console, timeout_ms: i32) !?u8 {
        if (self.repeats != 0) return self.popByte();

        const start = try std.time.Instant.now();
        var remaining: windows.DWORD = if (timeout_ms < 0) windows.INFINITE else @intCast(timeout_ms);
        while (!isInterrupted()) {
            windows.WaitForSingleObject(self.input, remaining) catch |err| switch (err) {
                error.WaitTimeOut => return null,
                else => return err,
            };
            if (isInterrupted()) return null;

            // The handle is also signaled for key-up and other records. A
            // stream read can block waiting for a character in that case.
            var record: InputRecord = undefined;
            var read: windows.DWORD = undefined;
            if (ReadConsoleInputW(self.input, &record, 1, &read) == 0) {
                const err = windows.GetLastError();
                if (err == .INVALID_HANDLE or err == .BROKEN_PIPE) return error.EndOfStream;
                return windows.unexpectedError(err);
            }
            if (read != 0 and record.kind == key_event and record.key.down != 0 and record.key.code_unit != 0) {
                self.encodeInput(record.key.code_unit);
                if (self.byte_count != 0) {
                    self.repeats = @max(record.key.repeats, 1);
                    return self.popByte();
                }
            }

            if (timeout_ms > 0) {
                const elapsed_ms = (try std.time.Instant.now()).since(start) / std.time.ns_per_ms;
                remaining = @intCast(@as(u32, @intCast(timeout_ms)) -| elapsed_ms);
                if (remaining == 0) return null;
            }
        }
        return null;
    }

    fn encodeInput(self: *Console, unit: u16) void {
        self.byte_count = 0;
        if (self.high_surrogate) |high| {
            self.high_surrogate = null;
            if (std.unicode.utf16IsLowSurrogate(unit)) {
                const scalar = std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch unreachable;
                self.byte_count = std.unicode.utf8Encode(scalar, &self.bytes) catch unreachable;
                return;
            }
            const replacement = std.unicode.replacement_character_utf8;
            self.bytes[0..replacement.len].* = replacement;
            self.byte_count = replacement.len;
        }
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return;
        }
        const scalar: u21 = if (std.unicode.utf16IsLowSurrogate(unit)) std.unicode.replacement_character else unit;
        self.byte_count += std.unicode.utf8Encode(scalar, self.bytes[self.byte_count..]) catch unreachable;
    }

    fn popByte(self: *Console) u8 {
        const byte = self.bytes[self.byte_index];
        self.byte_index += 1;
        if (self.byte_index == self.byte_count) {
            self.byte_index = 0;
            self.repeats -= 1;
        }
        return byte;
    }
};

test "Windows console input combines UTF-16 surrogate pairs into UTF-8" {
    var console: Console = .{
        .input = undefined,
        .output = undefined,
        .input_mode = 0,
        .output_mode = 0,
    };
    console.encodeInput(0xd83d);
    try std.testing.expectEqual(@as(usize, 0), console.byte_count);
    console.encodeInput(0xde42);
    try std.testing.expectEqualStrings("\u{1f642}", console.bytes[0..console.byte_count]);
    console.encodeInput(0xd83d);
    console.encodeInput('a');
    try std.testing.expectEqualStrings("\u{fffd}a", console.bytes[0..console.byte_count]);
}
