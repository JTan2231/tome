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

pub const Edit = struct {
    start: usize,
    old_end: usize,
    new_end: usize,

    pub fn between(old: []const u8, new: []const u8) Edit {
        if (old.len > max_source_bytes or new.len > max_source_bytes) {
            return .{ .start = 0, .old_end = old.len, .new_end = new.len };
        }
        const start = std.mem.indexOfDiff(u8, old, new) orelse old.len;
        var old_end = old.len;
        var new_end = new.len;
        while (old_end > start and new_end > start and old[old_end - 1] == new[new_end - 1]) {
            old_end -= 1;
            new_end -= 1;
        }
        return .{ .start = start, .old_end = old_end, .new_end = new_end };
    }
};

pub const Cache = struct {
    revision: ?u64 = null,
    spans: std.ArrayList(Span) = .empty,
    needs_scan: bool = false,

    pub fn clear(self: *Cache) void {
        self.spans.deinit(allocator);
        self.* = .{};
    }

    pub fn get(self: *const Cache, revision: u64) []const Span {
        return if (self.revision == revision) self.spans.items else &.{};
    }

    // Keep surviving colors at their new offsets until the scanner confirms
    // which ranges the edit changed. Edits within a span keep its color.
    pub fn rebase(self: *Cache, previous: u64, revision: u64, edit: Edit, source_len: usize) void {
        if (self.revision != previous or source_len == 0 or source_len > max_source_bytes) {
            self.clear();
            return;
        }
        self.revision = revision;
        if (edit.start == edit.old_end and edit.start == edit.new_end) return;
        self.needs_scan = true;
        const spans = self.spans.items;
        const first = std.sort.partitionPoint(Span, spans, edit.start, spanBefore);
        var count = first;
        for (spans[first..]) |old| {
            var span = old;
            if (old.start >= edit.old_end) {
                span.start = old.start - edit.old_end + edit.new_end;
                span.end = old.end - edit.old_end + edit.new_end;
            } else if (old.start < edit.start) {
                span.end = if (old.end >= edit.old_end) old.end - edit.old_end + edit.new_end else edit.start;
            } else if (old.end > edit.old_end) {
                span.start = edit.new_end;
                span.end = old.end - edit.old_end + edit.new_end;
            } else continue;
            spans[count] = span;
            count += 1;
        }
        self.spans.shrinkRetainingCapacity(count);
    }

    fn spanBefore(offset: usize, span: Span) bool {
        return span.end <= offset;
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
        const changed = !sameSpans(cache.get(self.revision), self.spans.items);
        if (changed or cache.revision != self.revision) std.mem.swap(std.ArrayList(Span), &cache.spans, &self.spans);
        cache.revision = self.revision;
        cache.needs_scan = false;
        return changed;
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

fn sameSpans(a: []const Span, b: []const Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.meta.eql(left, right)) return false;
    }
    return true;
}

test {
    _ = @import("zig.zig");
    _ = @import("c.zig");
}
