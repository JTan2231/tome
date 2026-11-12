const std = @import("std");
const Kind = @import("content").highlight.Kind;

const Palette = struct {
    keyword: u8,
    comment: u8,
    string: u8,
    number: u8,
    @"function.builtin": u8,
    @"keyword.directive": u8,
};

// Compile in the ANSI color subset of Tree-sitter's theme JSON format.
const palette = blk: {
    @setEvalBranchQuota(100_000);
    var scratch: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const config = std.json.parseFromSliceLeaky(struct { theme: Palette }, fixed.allocator(), @embedFile("syntax_theme.json"), .{}) catch |err|
        @compileError("Invalid built-in syntax theme: " ++ @errorName(err));
    break :blk config.theme;
};

pub fn foreground(kind: ?Kind) []const u8 {
    return switch (kind orelse return "\x1b[39m") {
        .keyword => ansi(palette.keyword),
        .comment => ansi(palette.comment),
        .string => ansi(palette.string),
        .number => ansi(palette.number),
        .builtin => ansi(palette.@"function.builtin"),
        .directive => ansi(palette.@"keyword.directive"),
    };
}

fn ansi(comptime color: u8) []const u8 {
    if (color < 8) return std.fmt.comptimePrint("\x1b[{d}m", .{30 + color});
    if (color < 16) return std.fmt.comptimePrint("\x1b[{d}m", .{90 + color - 8});
    return std.fmt.comptimePrint("\x1b[38;5;{d}m", .{color});
}
