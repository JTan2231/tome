const std = @import("std");
const files = @import("files.zig");
const wildmatch = @import("wildmatch.zig");

// Git's limit for ignore files.
const max_file_size = 100 * 1024 * 1024;

const Rule = struct {
    pattern: []const u8,
    negated: bool,
    directory_only: bool,
    anchored: bool,

    fn parse(line: []const u8) ?Rule {
        var pattern = trimTrailingSpaces(std.mem.sliceTo(line, 0));
        if (pattern.len == 0 or pattern[0] == '#') return null;
        const negated = pattern[0] == '!';
        if (negated) pattern = pattern[1..];
        if (pattern.len == 0) return null;
        const directory_only = pattern[pattern.len - 1] == '/';
        if (directory_only) pattern = pattern[0 .. pattern.len - 1];
        if (pattern.len == 0) return null;
        const anchored = std.mem.indexOfScalar(u8, pattern, '/') != null;
        if (pattern[0] == '/') pattern = pattern[1..];
        return .{
            .pattern = pattern,
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
        };
    }
};

pub const Rules = struct {
    contents: []u8,
    rules: std.ArrayList(Rule) = .empty,
    path_offset: usize,
    parent: ?*const Rules,

    pub fn load(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, parent: ?*const Rules) !?Rules {
        const file = files.openReadNoFollow(dir, ".gitignore") catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        if (stat.kind != .file or stat.size > max_file_size) return null;
        const contents = file.readToEndAlloc(allocator, max_file_size) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        var result: Rules = .{
            .contents = contents,
            .path_offset = if (prefix.len == 0) 0 else prefix.len + 1,
            .parent = parent,
        };
        errdefer result.deinit(allocator);

        const bom = "\xef\xbb\xbf";
        const start = if (std.mem.startsWith(u8, contents, bom)) bom.len else 0;
        var lines = std.mem.splitScalar(u8, contents[start..], '\n');
        while (lines.next()) |line| {
            const text = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
            if (Rule.parse(text)) |rule| try result.rules.append(allocator, rule);
        }
        if (result.rules.items.len == 0) {
            result.deinit(allocator);
            return null;
        }
        return result;
    }

    pub fn deinit(self: *Rules, allocator: std.mem.Allocator) void {
        self.rules.deinit(allocator);
        allocator.free(self.contents);
    }

    pub fn excludes(nearest: ?*const Rules, name: []const u8, path: []const u8, directory: bool) bool {
        // Rules from deeper directories and later lines have higher precedence.
        var current = nearest;
        while (current) |scope| : (current = scope.parent) {
            var index = scope.rules.items.len;
            while (index > 0) {
                index -= 1;
                const rule = scope.rules.items[index];
                if (rule.directory_only and !directory) continue;
                const candidate = if (rule.anchored) path[scope.path_offset..] else name;
                if (wildmatch.matches(rule.pattern, candidate)) return !rule.negated;
            }
        }
        return false;
    }
};

fn trimTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') {
        var start = end - 1;
        while (start > 0 and line[start - 1] == '\\') start -= 1;
        if ((end - 1 - start) % 2 == 1) break;
        end -= 1;
    }
    return line[0..end];
}
