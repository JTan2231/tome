const std = @import("std");
const storage = @import("storage.zig");

/// One independent document preparation. Only the worker touches its result
/// until done is published; its owner never waits except during destruction.
pub const Job = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    index: usize,
    revision: u64,
    allow_new: bool,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    document: ?storage.Document = null,
    line_count: usize = 0,
    failure: ?anyerror = null,

    pub fn start(allocator: std.mem.Allocator, path: []const u8, index: usize, revision: u64, allow_new: bool) !*Job {
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .path = path, .index = index, .revision = revision, .allow_new = allow_new };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    pub fn deinit(self: *Job) void {
        self.cancel();
        if (self.thread) |thread| thread.join();
        if (self.document) |*document| document.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.prepare() catch |err| {
            self.failure = err;
        };
    }

    fn prepare(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return;
        // The workspace allocator need not be thread safe. The prepared
        // Document retains its own allocator after adoption by the UI thread.
        var document = try storage.Document.open(std.heap.page_allocator, self.path);
        errdefer document.deinit();
        if (!self.allow_new and document.is_new) return error.FileNotFound;
        if (self.cancelled.load(.acquire)) {
            document.deinit();
            return;
        }
        self.line_count = document.buffer.line_count;
        self.document = document;
    }
};
