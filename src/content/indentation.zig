const std = @import("std");

pub const max_width = 16;

pub const Style = struct {
    kind: enum { spaces, tabs } = .spaces,
    width: usize = 4,
};

pub fn detect(bytes: []const u8) Style {
    const sample = bytes[0..@min(bytes.len, 64 * 1024)];
    var lines = std.mem.splitScalar(u8, sample, '\n');
    var space_lines: usize = 0;
    var tab_lines: usize = 0;
    var widths = [_]usize{0} ** (max_width + 1);
    var previous: ?usize = 0;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const leading = std.mem.indexOfNone(u8, line, " \t") orelse continue;
        if (std.mem.indexOfScalar(u8, line[0..leading], '\t') != null) {
            tab_lines += 1;
            previous = null;
            continue;
        }
        if (leading != 0) space_lines += 1;
        if (previous) |last| {
            const change = @max(leading, last) - @min(leading, last);
            if (change <= max_width) widths[change] += 1;
        }
        previous = leading;
    }

    if (tab_lines > space_lines) return .{ .kind = .tabs };

    var style: Style = .{};
    for (widths[2..], 2..) |votes, width| {
        const best = widths[style.width];
        // A tie with a larger multiple can be a jump of several levels.
        if (votes > best or (votes > 0 and votes == best and style.width % width == 0)) {
            style.width = width;
        }
    }
    // Single spaces also occur in alignment, such as in block comments.
    if (widths[style.width] == 0 and widths[1] != 0) style.width = 1;
    return style;
}

test "indentation style uses nonblank leading whitespace" {
    try std.testing.expectEqual(Style{}, detect("root\n\t  \nvalue\tvalue\n"));
    try std.testing.expectEqual(Style{ .width = 2 }, detect("root\n  child\n    nested\n  child\nroot\n"));
    try std.testing.expectEqual(Style{ .width = 3 }, detect("root\n   child\n      nested\nroot\n"));
    try std.testing.expectEqual(Style{ .width = 8 }, detect("root\n        child\nroot\n"));
    try std.testing.expectEqual(Style{ .kind = .tabs }, detect("root\r\n\tchild\r\n\t\t  aligned\r\n    \r\n"));
}
