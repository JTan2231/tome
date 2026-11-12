const std = @import("std");
const types = @import("types.zig");
const allocator = std.heap.page_allocator;

pub const Kind = types.Kind;
pub const Span = types.Span;

// Bound the snapshot copied on the editor thread and the work per revision.
pub const max_source_bytes = 1024 * 1024;

pub const Language = enum {
    zig,
    c,

    pub fn detect(filename: []const u8) ?Language {
        const extension = std.fs.path.extension(filename);
        if (std.mem.eql(u8, extension, ".zig") or std.mem.eql(u8, extension, ".zon")) return .zig;
        if (std.mem.eql(u8, extension, ".c") or std.mem.eql(u8, extension, ".h")) return .c;
        return null;
    }
};

pub const Cache = struct {
    revision: ?u64 = null,
    spans: std.ArrayList(Span) = .empty,

    pub fn clear(self: *Cache) void {
        self.spans.deinit(allocator);
        self.* = .{};
    }

    pub fn get(self: *const Cache, revision: u64) []const Span {
        return if (self.revision == revision) self.spans.items else &.{};
    }

    pub fn byteSize(self: *const Cache) usize {
        return self.spans.capacity * @sizeOf(Span);
    }
};

/// The worker owns its snapshot and writes only its own result. The editor
/// validates file residency and revision before transferring the result.
pub const Job = struct {
    file: usize,
    revision: u64,
    language: Language,
    source: [:0]const u8,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    spans: std.ArrayList(Span) = .empty,

    pub fn start(file: usize, revision: u64, language: Language, bytes: []const u8) !*Job {
        std.debug.assert(bytes.len <= max_source_bytes);
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        const source = try allocator.dupeZ(u8, bytes);
        errdefer allocator.free(source);
        self.* = .{ .file = file, .revision = revision, .language = language, .source = source };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .monotonic);
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    pub fn publish(self: *Job, cache: *Cache) bool {
        std.debug.assert(self.isDone());
        cache.clear();
        cache.* = .{ .revision = self.revision, .spans = self.spans };
        self.spans = .empty;
        return cache.spans.items.len != 0;
    }

    pub fn deinit(self: *Job) void {
        self.cancel();
        self.thread.join();
        self.spans.deinit(allocator);
        allocator.free(self.source);
        allocator.destroy(self);
    }

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        var out: types.Collector = .{ .allocator = allocator, .cancelled = &self.cancelled };
        const result = switch (self.language) {
            .zig => @import("zig.zig").scan(self.source, &out),
            .c => @import("c.zig").scan(self.source, &out),
        };
        result catch {
            out.spans.deinit(allocator);
            return;
        };
        self.spans = out.spans;
    }
};

test {
    _ = @import("zig.zig");
    _ = @import("c.zig");
}
