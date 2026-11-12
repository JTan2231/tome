const std = @import("std");
const types = @import("types.zig");

pub fn scan(source: [:0]const u8, out: *types.Collector) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    var previous_end = tokenizer.index;
    while (true) {
        try out.checkpoint();
        const token = tokenizer.next();
        try scanComments(source[previous_end..token.loc.start], previous_end, out);
        if (token.tag == .eof) return;

        const spelling = source[token.loc.start..token.loc.end];
        if (classify(token.tag, spelling)) |kind| {
            const end = if (token.tag == .invalid and source[token.loc.end] == '\n' and
                std.mem.endsWith(u8, spelling, "\r")) token.loc.end - 1 else token.loc.end;
            try out.add(token.loc.start, end, kind);
        }
        previous_end = token.loc.end;
    }
}

// The Zig tokenizer skips ordinary line comments. Search only its gaps so
// slashes inside a token, such as a string literal, stay part of that token.
fn scanComments(gap: []const u8, offset: usize, out: *types.Collector) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, gap, cursor, "//")) |start| {
        const newline = std.mem.indexOfScalarPos(u8, gap, start, '\n');
        const end = newline orelse gap.len;
        const comment_end = if (newline != null and gap[end - 1] == '\r') end - 1 else end;
        try out.add(offset + start, offset + comment_end, .comment);
        cursor = end;
    }
}

fn classify(tag: std.zig.Token.Tag, spelling: []const u8) ?types.Kind {
    return switch (tag) {
        .string_literal, .char_literal, .multiline_string_literal_line => .string,
        .number_literal => .number,
        .builtin => .builtin,
        .doc_comment, .container_doc_comment => .comment,
        .identifier => if (std.zig.isPrimitive(spelling)) .builtin else null,
        .invalid => classifyInvalid(spelling),
        else => if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) .keyword else null,
    };
}

fn classifyInvalid(spelling: []const u8) ?types.Kind {
    // Preserve highlighting when an edit leaves a quoted literal unfinished
    // or introduces a byte the compiler rejects inside a comment.
    if (std.mem.startsWith(u8, spelling, "//")) return .comment;
    if (spelling.len > 0 and (spelling[0] == '"' or spelling[0] == '\'')) return .string;
    return null;
}

test "Zig highlights comments outside quoted text and through EOF" {
    const source: [:0]const u8 = "const path = \"https://ziglang.org\"; // url\r\n" ++
        "\"still // a string\r\n" ++
        "// eof";
    var out: types.Collector = .{ .allocator = std.testing.allocator };
    defer out.spans.deinit(out.allocator);
    try scan(source, &out);

    const expected = [_]struct { text: []const u8, kind: types.Kind }{
        .{ .text = "const", .kind = .keyword },
        .{ .text = "\"https://ziglang.org\"", .kind = .string },
        .{ .text = "// url", .kind = .comment },
        .{ .text = "\"still // a string", .kind = .string },
        .{ .text = "// eof", .kind = .comment },
    };
    try std.testing.expectEqual(expected.len, out.spans.items.len);
    for (out.spans.items, expected) |span, want| {
        try std.testing.expectEqual(want.kind, span.kind);
        try std.testing.expectEqualStrings(want.text, source[span.start..span.end]);
    }
}
