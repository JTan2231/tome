const std = @import("std");
const types = @import("types.zig");
const Collector = types.Collector;

const keywords = std.StaticStringMap(void).initComptime(.{
    .{"_Alignas"},       .{"_Alignof"},      .{"_Atomic"},       .{"_BitInt"},
    .{"_Bool"},          .{"_Complex"},      .{"_Decimal32"},    .{"_Decimal64"},
    .{"_Decimal128"},    .{"_Generic"},      .{"_Imaginary"},    .{"_Noreturn"},
    .{"_Static_assert"}, .{"_Thread_local"}, .{"alignas"},       .{"alignof"},
    .{"auto"},           .{"bool"},          .{"break"},         .{"case"},
    .{"char"},           .{"const"},         .{"constexpr"},     .{"continue"},
    .{"default"},        .{"do"},            .{"double"},        .{"else"},
    .{"enum"},           .{"extern"},        .{"false"},         .{"float"},
    .{"for"},            .{"goto"},          .{"if"},            .{"inline"},
    .{"int"},            .{"long"},          .{"nullptr"},       .{"register"},
    .{"restrict"},       .{"return"},        .{"short"},         .{"signed"},
    .{"sizeof"},         .{"static"},        .{"static_assert"}, .{"struct"},
    .{"switch"},         .{"thread_local"},  .{"true"},          .{"typedef"},
    .{"typeof"},         .{"typeof_unqual"}, .{"union"},         .{"unsigned"},
    .{"void"},           .{"volatile"},      .{"while"},
});

pub fn scan(source: [:0]const u8, out: *Collector) !void {
    var i: usize = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) 3 else 0;
    var next_checkpoint: usize = 0;
    var line_prefix = true;
    var directive_name = false;

    while (i < source.len) {
        if (i >= next_checkpoint) {
            try out.checkpoint();
            next_checkpoint = i + checkpoint_interval;
        }
        const start = i;
        const byte = source[start];
        switch (byte) {
            ' ', '\t', '\x0b', '\x0c' => {
                i += 1;
                continue;
            },
            '\r', '\n' => {
                line_prefix = true;
                directive_name = false;
                i += 1;
                continue;
            },
            '\\' => {
                const splice = spliceLength(source[start..]);
                if (splice != 0) {
                    i += splice;
                    continue;
                }
            },
            '/' => switch (source[start + 1]) {
                '/' => {
                    i = try lineCommentEnd(source, start + 2, out);
                    try out.add(start, i, .comment);
                    continue;
                },
                '*' => {
                    i = try blockCommentEnd(source, start + 2, out);
                    try out.add(start, i, .comment);
                    continue;
                },
                else => {},
            },
            '#' => if (line_prefix) {
                i += 1;
                try out.add(start, i, .directive);
                line_prefix = false;
                directive_name = true;
                continue;
            },
            else => {},
        }

        if (quoteStart(source, start)) |quote| {
            i = try quotedEnd(source, quote, out);
            try out.add(start, i, .string);
        } else if (std.ascii.isDigit(byte) or (byte == '.' and std.ascii.isDigit(source[start + 1]))) {
            i = try numberEnd(source, start, out);
            try out.add(start, i, .number);
        } else if (identifierStart(byte)) {
            i += 1;
            while (i < source.len and identifierByte(source[i])) : (i += 1) {
                try checkpointAt(out, i);
            }
            if (directive_name) {
                try out.add(start, i, .directive);
            } else if (keywords.has(source[start..i])) {
                try out.add(start, i, .keyword);
            }
        } else {
            i += 1;
        }
        line_prefix = false;
        directive_name = false;
    }
}

fn identifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

fn identifierByte(byte: u8) bool {
    return identifierStart(byte) or std.ascii.isDigit(byte);
}

fn quoteStart(source: [:0]const u8, start: usize) ?usize {
    const quote = switch (source[start]) {
        '"', '\'' => return start,
        'L', 'U' => start + 1,
        'u' => if (source[start + 1] == '8') start + 2 else start + 1,
        else => return null,
    };
    return if (source[quote] == '"' or source[quote] == '\'') quote else null;
}

fn quotedEnd(source: []const u8, quote: usize, out: *Collector) !usize {
    var i = quote + 1;
    var escaped = false;
    while (i < source.len) {
        try checkpointAt(out, i);
        const byte = source[i];
        if (byte == '\n' or byte == '\r') break;
        if (byte == '\\') {
            const splice = spliceLength(source[i..]);
            if (splice != 0) {
                i += splice;
                continue;
            }
        }
        i += 1;
        if (!escaped and byte == source[quote]) return i;
        escaped = !escaped and byte == '\\';
    }
    return i;
}

fn lineCommentEnd(source: []const u8, start: usize, out: *Collector) !usize {
    var i = start;
    while (i < source.len) {
        try checkpointAt(out, i);
        const splice = spliceLength(source[i..]);
        if (splice != 0) {
            i += splice;
        } else if (source[i] == '\n' or source[i] == '\r') {
            break;
        } else {
            i += 1;
        }
    }
    return i;
}

fn blockCommentEnd(source: [:0]const u8, start: usize, out: *Collector) !usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        try checkpointAt(out, i);
        if (source[i] == '*' and source[i + 1] == '/') return i + 2;
    }
    return i;
}

fn numberEnd(source: [:0]const u8, start: usize, out: *Collector) !usize {
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        try checkpointAt(out, i);
        const byte = source[i];
        if (identifierByte(byte) or byte == '.') continue;
        if (byte == '\'' and identifierByte(source[i + 1])) continue;
        if (byte == '+' or byte == '-') {
            switch (source[i - 1]) {
                'e', 'E', 'p', 'P' => continue,
                else => {},
            }
        }
        break;
    }
    return i;
}

fn spliceLength(source: []const u8) usize {
    if (source.len < 2 or source[0] != '\\') return 0;
    return switch (source[1]) {
        '\n' => 2,
        '\r' => if (source.len >= 3 and source[2] == '\n') 3 else 2,
        else => 0,
    };
}

const checkpoint_interval = 4096;

fn checkpointAt(out: *const Collector, offset: usize) !void {
    // A CRLF splice can advance the scanner by three bytes.
    if (offset % checkpoint_interval < 3) try out.checkpoint();
}

test "C highlighting distinguishes continued comments, literals, and unfinished strings" {
    const source = "\xef\xbb\xbf  #define N 0x1.fp-2\r\n" ++
        "/* bool\nstill comment */ int x;\n" ++
        "// continued \\\r\n#define hidden\r\n" ++
        "const char *s = u8\"//\\\r\n\\\"\";\n" ++
        "'\\''; \"unfinished\nreturn";
    var out: Collector = .{ .allocator = std.testing.allocator };
    defer out.spans.deinit(out.allocator);
    try scan(source, &out);

    const expected = [_]struct { bytes: []const u8, kind: types.Kind }{
        .{ .bytes = "#", .kind = .directive },
        .{ .bytes = "define", .kind = .directive },
        .{ .bytes = "0x1.fp-2", .kind = .number },
        .{ .bytes = "/* bool\nstill comment */", .kind = .comment },
        .{ .bytes = "int", .kind = .keyword },
        .{ .bytes = "// continued \\\r\n#define hidden", .kind = .comment },
        .{ .bytes = "const", .kind = .keyword },
        .{ .bytes = "char", .kind = .keyword },
        .{ .bytes = "u8\"//\\\r\n\\\"\"", .kind = .string },
        .{ .bytes = "'\\''", .kind = .string },
        .{ .bytes = "\"unfinished", .kind = .string },
        .{ .bytes = "return", .kind = .keyword },
    };
    try std.testing.expectEqual(expected.len, out.spans.items.len);
    for (expected, out.spans.items) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqualStrings(want.bytes, source[got.start..got.end]);
    }
}
