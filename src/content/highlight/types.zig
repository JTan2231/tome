const std = @import("std");

pub const Kind = enum { keyword, comment, string, number, builtin, directive };

pub const Span = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayList(Span) = .empty,
    cancelled: ?*const std.atomic.Value(bool) = null,

    pub fn checkpoint(self: *const Collector) !void {
        if (self.cancelled) |cancelled| {
            if (cancelled.load(.monotonic)) return error.Cancelled;
        }
    }

    pub fn add(self: *Collector, start: usize, end: usize, kind: Kind) !void {
        try self.checkpoint();
        std.debug.assert(start < end);
        if (self.spans.getLastOrNull()) |last| std.debug.assert(last.end <= start);
        if (self.spans.items.len >= 64 * 1024) return error.SpanLimit;
        try self.spans.append(self.allocator, .{ .start = start, .end = end, .kind = kind });
    }
};
