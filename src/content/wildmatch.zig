const std = @import("std");

const Checkpoint = struct {
    pattern: usize,
    path: usize,
};

pub fn matches(pattern: []const u8, path: []const u8) bool {
    const prefix = std.mem.indexOfAny(u8, pattern, "*?[\\") orelse
        return std.mem.eql(u8, pattern, path);
    if (!std.mem.startsWith(u8, path, pattern[0..prefix])) return false;

    var pattern_index = prefix;
    var path_index = prefix;
    // A star retries within the current component. A recursive star retries
    // at the next slash. An encountered star replaces the previous one of
    // its kind because it can absorb any additional input that one could.
    var star: ?Checkpoint = null;
    var recursive_star: ?Checkpoint = null;

    while (true) {
        if (pattern_index == pattern.len) {
            if (path_index == path.len) return true;
        } else switch (pattern[pattern_index]) {
            '*' => {
                const start = pattern_index;
                while (pattern_index < pattern.len and pattern[pattern_index] == '*')
                    pattern_index += 1;
                const remaining = pattern[pattern_index..];
                const at_boundary = start == prefix or pattern[start - 1] == '/';
                if (pattern_index - start >= 2 and at_boundary) {
                    if (remaining.len == 0) return true;
                    if (remaining[0] == '/') {
                        pattern_index += 1;
                        recursive_star = .{ .pattern = pattern_index, .path = path_index };
                        star = null;
                        continue;
                    }
                    if (std.mem.startsWith(u8, remaining, "\\/")) {
                        const slash = std.mem.indexOfScalarPos(u8, path, path_index, '/') orelse
                            return false;
                        pattern_index += 2;
                        path_index = slash + 1;
                        recursive_star = .{ .pattern = pattern_index, .path = path_index };
                        star = null;
                        continue;
                    }
                }
                star = .{ .pattern = pattern_index, .path = path_index };
                continue;
            },
            '?' => if (path_index < path.len and path[path_index] != '/') {
                pattern_index += 1;
                path_index += 1;
                continue;
            },
            '[' => if (path_index < path.len and path[path_index] != '/') {
                const result = matchClass(pattern[pattern_index + 1 ..], path[path_index]) orelse
                    return false;
                if (result.matched) {
                    pattern_index += result.len + 1;
                    path_index += 1;
                    continue;
                }
            },
            else => {
                const escaped = pattern[pattern_index] == '\\';
                const literal = pattern_index + @intFromBool(escaped);
                if (literal == pattern.len) return false;
                if (path_index < path.len and pattern[literal] == path[path_index]) {
                    if (path[path_index] == '/') star = null;
                    pattern_index = literal + 1;
                    path_index += 1;
                    continue;
                }
            },
        }

        if (star) |*retry| {
            if (retry.path < path.len and path[retry.path] != '/') {
                retry.path += 1;
                pattern_index = retry.pattern;
                path_index = retry.path;
                continue;
            }
        }
        const retry = if (recursive_star) |*checkpoint| checkpoint else return false;
        const slash = std.mem.indexOfScalarPos(u8, path, retry.path, '/') orelse return false;
        retry.path = slash + 1;
        pattern_index = retry.pattern;
        path_index = retry.path;
        star = null;
    }
}

const ClassMatch = struct {
    len: usize,
    matched: bool,
};

fn matchClass(pattern: []const u8, byte: u8) ?ClassMatch {
    if (pattern.len == 0) return null;
    const negated = pattern[0] == '!' or pattern[0] == '^';
    var index: usize = @intFromBool(negated);
    const first = index;
    var matched = false;
    while (index < pattern.len) {
        if (pattern[index] == ']' and index != first)
            return .{ .len = index + 1, .matched = matched != negated };

        if (std.mem.startsWith(u8, pattern[index..], "[:")) {
            const start = index + 2;
            if (std.mem.indexOfScalarPos(u8, pattern, start, ']')) |end| {
                if (end > start and pattern[end - 1] == ':') {
                    const in_class = namedClassMatches(pattern[start .. end - 1], byte) orelse
                        return null;
                    matched = matched or in_class;
                    index = end + 1;
                    continue;
                }
            }
        }

        if (pattern[index] == '\\') index += 1;
        if (index == pattern.len) return null;
        const lower = pattern[index];
        matched = matched or byte == lower;
        index += 1;
        if (index + 1 < pattern.len and pattern[index] == '-' and pattern[index + 1] != ']') {
            index += 1;
            if (pattern[index] == '\\') index += 1;
            if (index == pattern.len) return null;
            matched = matched or (lower <= byte and byte <= pattern[index]);
            index += 1;
        }
    }
    return null;
}

fn namedClassMatches(name: []const u8, byte: u8) ?bool {
    const Class = enum { alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit };
    return switch (std.meta.stringToEnum(Class, name) orelse return null) {
        .alnum => std.ascii.isAlphanumeric(byte),
        .alpha => std.ascii.isAlphabetic(byte),
        .blank => byte == ' ' or byte == '\t',
        .cntrl => std.ascii.isControl(byte),
        .digit => std.ascii.isDigit(byte),
        .graph => std.ascii.isPrint(byte) and byte != ' ',
        .lower => std.ascii.isLower(byte),
        .print => std.ascii.isPrint(byte),
        .punct => std.ascii.isPrint(byte) and byte != ' ' and !std.ascii.isAlphanumeric(byte),
        .space => std.ascii.isWhitespace(byte),
        .upper => std.ascii.isUpper(byte),
        .xdigit => std.ascii.isHex(byte),
    };
}

test "ordinary wildcards and escaping" {
    const expect = std.testing.expect;
    try expect(matches("build", "build"));
    try expect(!matches("build", "Build"));
    try expect(matches("build/*.o", "build/.hidden.o"));
    try expect(!matches("build/*.o", "build/nested/file.o"));
    try expect(!matches("a?b", "a/b"));
    try expect(matches("a?b", "axb"));
    try expect(matches("a*bc*d", "aabbcddd"));
    try expect(matches("\\!literal\\*", "!literal*"));
    try expect(!matches("file\\", "file\\"));
}

test "recursive wildcards and retry across path components" {
    const expect = std.testing.expect;
    try expect(matches("a/**/b", "a/b"));
    try expect(matches("a/**/b", "a/x/y/b"));
    try expect(!matches("a/**/b", "a/x/y/b/c"));
    try expect(matches("a/**", "a/x/y"));
    try expect(!matches("a/**", "a"));
    try expect(matches("**/b*/**/d*", "a/b/c/b/z/doc"));
    try expect(matches("**/b*/d*", "a/b/c/b/doc"));
    try expect(matches("a/***/b", "a/x/y/b"));
    try expect(matches("a**/b", "a/x/y/b"));
    try expect(!matches("a?**/b", "ax/y/b"));
    try expect(matches("a/**\\/b", "a/x/y/b"));
    try expect(!matches("a/**\\/b", "a/b"));
    try expect(!matches("a/b**c", "a/b/x/c"));
}

test "bracket expressions" {
    const expect = std.testing.expect;
    try expect(matches("[a-c][[:digit:]]", "b2"));
    try expect(!matches("[a-c][[:digit:]]", "bZ"));
    try expect(matches("[!a-c][^a-c]", "zd"));
    try expect(!matches("[!a-c]", "/"));
    try expect(matches("[]]", "]"));
    try expect(matches("[\\]]", "]"));
    try expect(matches("[a-]", "-"));
    try expect(matches("[a-b-c]", "-"));
    try expect(!matches("[a-b-c]", "z"));
    try expect(!matches("[[:unknown:]]", "a"));
    try expect(!matches("file[abc", "filea"));
    try expect(!matches("[]", "]"));
}
