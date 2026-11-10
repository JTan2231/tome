const std = @import("std");

pub const Cell = struct {
    len: usize,
    width: usize,
    kind: enum { text, tab, control, replacement },
};

// A small scalar-width implementation, not a grapheme segmenter. Keep bytes in
// the buffer intact; replace malformed UTF-8 and never emit file escape codes.
pub fn cell(bytes: []const u8, column: usize) Cell {
    std.debug.assert(bytes.len != 0);
    const first = bytes[0];
    if (first == '\t') return .{ .len = 1, .width = 4 - column % 4, .kind = .tab };
    if (first < 0x20 or first == 0x7f) return .{ .len = 1, .width = 2, .kind = .control };
    const len = std.unicode.utf8ByteSequenceLength(first) catch return replacement();
    if (len > bytes.len) return replacement();
    const scalar = std.unicode.utf8Decode(bytes[0..len]) catch return replacement();
    // C1 controls and bidi formatting controls are not useful terminal content.
    if ((scalar >= 0x80 and scalar < 0xa0) or
        (scalar >= 0x202a and scalar <= 0x202e) or
        (scalar >= 0x2066 and scalar <= 0x2069))
        return .{ .len = len, .width = 1, .kind = .replacement };
    return .{ .len = len, .width = scalarWidth(scalar), .kind = .text };
}

fn replacement() Cell {
    return .{ .len = 1, .width = 1, .kind = .replacement };
}

fn in(c: u21, first: u21, last: u21) bool {
    return c >= first and c <= last;
}

fn scalarWidth(c: u21) usize {
    if (in(c, 0x0300, 0x036f) or in(c, 0x0483, 0x0489) or
        in(c, 0x0591, 0x05bd) or c == 0x05bf or in(c, 0x05c1, 0x05c2) or
        in(c, 0x0610, 0x061a) or in(c, 0x064b, 0x065f) or c == 0x0670 or
        in(c, 0x06d6, 0x06dc) or in(c, 0x06df, 0x06e4) or in(c, 0x06e7, 0x06e8) or
        in(c, 0x06ea, 0x06ed) or in(c, 0x1ab0, 0x1aff) or
        in(c, 0x1dc0, 0x1dff) or in(c, 0x200b, 0x200f) or
        in(c, 0x2028, 0x2029) or in(c, 0x2060, 0x2064) or
        in(c, 0x20d0, 0x20ff) or in(c, 0xfe00, 0xfe0f) or
        in(c, 0xfe20, 0xfe2f) or c == 0xfeff or in(c, 0xe0100, 0xe01ef)) return 0;
    if (in(c, 0x1100, 0x115f) or c == 0x2329 or c == 0x232a or
        in(c, 0x2e80, 0x303e) or in(c, 0x3040, 0xa4cf) or
        in(c, 0xac00, 0xd7a3) or in(c, 0xf900, 0xfaff) or
        in(c, 0xfe10, 0xfe19) or in(c, 0xfe30, 0xfe6f) or
        in(c, 0xff01, 0xff60) or in(c, 0xffe0, 0xffe6) or
        in(c, 0x1f300, 0x1faff) or in(c, 0x20000, 0x3fffd)) return 2;
    return 1;
}

pub fn columns(bytes: []const u8) usize {
    var index: usize = 0;
    var column: usize = 0;
    while (index < bytes.len) {
        const unit = cell(bytes[index..], column);
        column += unit.width;
        index += unit.len;
    }
    return column;
}

test "display widths and terminal controls" {
    try std.testing.expectEqual(@as(usize, 7), columns("a\t界x"));
    try std.testing.expectEqual(@as(usize, 1), columns("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), columns("\x1b"));
    try std.testing.expect(cell("\x1b", 0).kind == .control);
    try std.testing.expectEqual(@as(usize, 1), columns("\xff"));
}
