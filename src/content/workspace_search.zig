const std = @import("std");
const files = @import("files.zig");
const search = @import("search.zig");
const storage = @import("storage.zig");
const Entry = @import("workspace.zig").Entry;

const batch_size = 1024;

pub const Match = struct {
    file: usize,
    offset: usize,
    row: usize,
    column: usize,
    revision: ?u64 = null,
};

pub const Options = struct {
    // The catalog and its paths outlive the job. Only path fields are read by
    // the worker. Resident indices are copied before starting the worker.
    entries: []const Entry,
    resident: []const usize,
    cell: *const fn ([]const u8, usize) search.Cell,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    entries: []const Entry,
    resident: []usize,
    cell: *const fn ([]const u8, usize) search.Cell,
    query: []u8,
    thread: std.Thread = undefined,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    request: ?search.Request = null,
    destination: []u8 = undefined,
    response: search.Source = undefined,
    pending: [batch_size]Match = undefined,
    pending_len: usize = 0,

    pub fn start(allocator: std.mem.Allocator, query: []const u8, options: Options) !*Job {
        if (query.len == 0) return error.EmptyQuery;
        if (query.len > search.max_query_size) return error.QueryTooLong;
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        const owned_query = try allocator.dupe(u8, query);
        errdefer allocator.free(owned_query);
        const resident = try allocator.dupe(usize, options.resident);
        errdefer allocator.free(resident);
        std.mem.sort(usize, resident, {}, std.sort.asc(usize));
        self.* = .{
            .allocator = allocator,
            .entries = options.entries,
            .resident = resident,
            .cell = options.cell,
            .query = owned_query,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Append at most one batch and service at most one bounded resident read.
    /// The read callback runs on the editor thread and must not perform I/O.
    pub fn poll(
        self: *Job,
        context: anytype,
        comptime read: fn (@TypeOf(context), search.Request, []u8) search.Source,
        allocator: std.mem.Allocator,
        results: *std.ArrayList(Match),
    ) !bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock();
        if (self.cancelled.load(.acquire)) return false;
        const changed = self.pending_len != 0;
        if (changed) {
            try results.appendSlice(allocator, self.pending[0..self.pending_len]);
            self.pending_len = 0;
        }
        const request = self.request;
        if (request) |wanted| {
            self.response = read(context, wanted, self.destination);
            self.request = null;
        }
        if (changed or request != null) self.condition.signal();
        return changed;
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
        self.condition.signal();
    }

    /// When done, all published matches have been drained unless cancelled.
    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    pub fn deinit(self: *Job) void {
        self.cancel();
        self.thread.join();
        const allocator = self.allocator;
        allocator.free(self.resident);
        allocator.free(self.query);
        allocator.destroy(self);
    }

    fn checkCancelled(self: *const Job) error{Cancelled}!void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }

    fn wait(self: *Job) !void {
        try self.checkCancelled();
        // The timeout covers cancellation immediately before entering the wait.
        self.condition.timedWait(&self.mutex, 5 * std.time.ns_per_ms) catch {};
    }

    fn source(self: *Job, request: search.Request, destination: []u8) !search.Source {
        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.request = null;
        self.request = request;
        self.destination = destination;
        while (self.request != null) try self.wait();
        try self.checkCancelled();
        return self.response;
    }

    fn publish(self: *Job, matches: []const Match) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var remaining = matches;
        while (remaining.len != 0) {
            while (self.pending_len == self.pending.len) try self.wait();
            try self.checkCancelled();
            const count = @min(remaining.len, self.pending.len - self.pending_len);
            @memcpy(self.pending[self.pending_len..][0..count], remaining[0..count]);
            self.pending_len += count;
            remaining = remaining[count..];
        }
    }

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.scanAll() catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.pending_len != 0) self.wait() catch return;
    }

    fn scanAll(self: *Job) !void {
        var next_resident: usize = 0;
        for (0..self.entries.len) |index| {
            try self.checkCancelled();
            const resident = next_resident < self.resident.len and self.resident[next_resident] == index;
            if (resident) next_resident += 1;
            self.scanFile(index, resident) catch |err| switch (err) {
                error.Cancelled => return err,
                else => continue,
            };
        }
    }

    fn scanFile(self: *Job, index: usize, resident: bool) !void {
        var bytes: [search.chunk_size + search.max_query_size + 3]u8 = undefined;
        const first: search.Source = if (resident)
            try self.source(.{ .file = index, .offset = 0 }, bytes[0..search.chunk_size])
        else
            .{ .disk = .{ .path = self.entries[index].path, .revision = 0 } };
        switch (first) {
            .resident => |part| {
                if (part.len > search.chunk_size or part.len > part.total_size) return error.InvalidSource;
                try self.scan(index, &bytes, part.len, part.total_size, part.revision, null);
            },
            .disk => |disk| {
                // A cataloged regular file can be replaced while the editor is open.
                const file = try files.openReadNoFollow(std.fs.cwd(), disk.path);
                defer file.close();
                const stat = try file.stat();
                if (stat.kind != .file or stat.size > storage.max_file_size) return;
                try self.scan(index, &bytes, 0, @intCast(stat.size), null, file);
            },
            .unavailable => {},
        }
    }

    fn scan(
        self: *Job,
        index: usize,
        bytes: []u8,
        first_len: usize,
        total_size: usize,
        revision: ?u64,
        disk: ?std.fs.File,
    ) !void {
        var filled = first_len;
        var read_offset = first_len;
        var position: Position = .{};
        var batch: [batch_size]Match = undefined;
        var count: usize = 0;
        while (filled != 0 or read_offset < total_size) {
            try self.checkCancelled();
            const size = @min(search.chunk_size, @min(total_size - read_offset, bytes.len - filled));
            if (size != 0) {
                const tail = bytes[filled..][0..size];
                const len = if (disk) |file| try file.read(tail) else blk: {
                    const next = try self.source(.{ .file = index, .offset = read_offset, .revision = revision }, tail);
                    const part = switch (next) {
                        .resident => |part| part,
                        else => return error.SourceChanged,
                    };
                    if (part.revision != revision.? or part.total_size != total_size or part.len > size)
                        return error.SourceChanged;
                    break :blk part.len;
                };
                if (len == 0) return error.SourceChanged;
                filled += len;
                read_offset += len;
            }
            const window = bytes[0..filled];
            // Keep possible match prefixes and an incomplete UTF-8 scalar
            // for the next read. An occurrence starting before limit is final.
            const limit = if (read_offset == total_size)
                filled
            else
                textBoundary(window, filled -| @max(self.query.len - 1, 3));
            const window_offset = read_offset - filled;
            var next_match: usize = 0;
            while (std.mem.indexOfPos(u8, window, next_match, self.query)) |hit| {
                if (hit >= limit) break;
                try self.checkCancelled();
                position.advance(window, hit, self.cell);
                batch[count] = .{
                    .file = index,
                    .offset = window_offset + hit,
                    .row = position.row,
                    .column = position.column,
                    .revision = revision,
                };
                count += 1;
                if (count == batch.len) {
                    try self.publish(&batch);
                    count = 0;
                }
                next_match = hit + 1;
            }
            if (count != 0) {
                try self.publish(batch[0..count]);
                count = 0;
            }
            position.advance(window, limit, self.cell);
            position.index = 0;
            filled -= limit;
            std.mem.copyForwards(u8, bytes[0..filled], window[limit..]);
        }
    }
};

const Position = struct {
    index: usize = 0,
    row: usize = 0,
    column: usize = 0,

    fn advance(self: *Position, bytes: []const u8, end: usize, cell: *const fn ([]const u8, usize) search.Cell) void {
        const between = bytes[self.index..end];
        if (std.mem.lastIndexOfScalar(u8, between, '\n')) |lf| {
            self.row += std.mem.count(u8, between[0 .. lf + 1], "\n");
            self.index += lf + 1;
            self.column = 0;
        }
        const line_end = if (end > self.index and end < bytes.len and bytes[end] == '\n' and bytes[end - 1] == '\r')
            end - 1
        else
            end;
        while (self.index < line_end) {
            const unit = cell(bytes[self.index..line_end], self.column);
            self.column += unit.width;
            self.index += unit.len;
        }
        self.index = end;
    }
};

fn textBoundary(bytes: []const u8, limit: usize) usize {
    if (limit == 0) return 0;
    if (bytes[limit] == '\n' and bytes[limit - 1] == '\r') return limit - 1;
    var start = limit;
    while (start > 0 and limit - start < 3 and bytes[start] & 0xc0 == 0x80) start -= 1;
    if (start == limit) return limit;
    const len = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return limit;
    if (start + len <= limit or start + len > bytes.len) return limit;
    _ = std.unicode.utf8Decode(bytes[start..][0..len]) catch return limit;
    return start;
}

test "workspace search appends resident and disk matches across a read boundary" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "saved text" });
    const disk = try temp.dir.createFile("b", .{});
    defer disk.close();
    var prefix: [search.chunk_size - 6]u8 = undefined;
    @memset(&prefix, 'x');
    prefix[0] = '\n';
    try disk.writeAll(&prefix);
    try disk.writeAll("\t界ababa");
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var workspace = try @import("workspace.zig").Workspace.open(allocator, root, null);
    defer workspace.deinit();
    const resident = try workspace.ensure(0);
    try resident.buffer.replaceRange(allocator, 0, resident.buffer.bytes.items.len, "unsaved\r\n\t界ababa");
    workspace.markDirty(0);

    const sources = struct {
        fn read(ws: *@import("workspace.zig").Workspace, request: search.Request, destination: []u8) search.Source {
            const entry = ws.entries.items[request.file];
            const bytes = entry.document.?.buffer.bytes.items;
            const len = @min(bytes.len - request.offset, destination.len);
            @memcpy(destination[0..len], bytes[request.offset..][0..len]);
            return .{ .resident = .{ .len = len, .total_size = bytes.len, .revision = entry.revision } };
        }

        fn cell(bytes: []const u8, column: usize) search.Cell {
            if (bytes[0] == '\t') return .{ .len = 1, .width = 4 - column % 4 };
            if (std.mem.startsWith(u8, bytes, "界")) return .{ .len = 3, .width = 2 };
            return .{ .len = 1, .width = 1 };
        }
    };
    const job = try Job.start(allocator, "aba", .{
        .entries = workspace.entries.items,
        .resident = workspace.resident.items,
        .cell = sources.cell,
    });
    defer job.deinit();
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);
    var timer = try std.time.Timer.start();
    while (!job.isDone()) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.SearchTestTimeout;
        if (!try job.poll(&workspace, sources.read, allocator, &matches))
            std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try std.testing.expect(workspace.entries.items[1].document == null);
    const revision = workspace.entries.items[0].revision;
    try std.testing.expectEqualSlices(Match, &.{
        .{ .file = 0, .offset = 13, .row = 1, .column = 6, .revision = revision },
        .{ .file = 0, .offset = 15, .row = 1, .column = 8, .revision = revision },
        .{ .file = 1, .offset = search.chunk_size - 2, .row = 1, .column = search.chunk_size - 2 },
        .{ .file = 1, .offset = search.chunk_size, .row = 1, .column = search.chunk_size },
    }, matches.items);
}
