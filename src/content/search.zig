//! A bounded search reader. The worker owns I/O and matching, while the editor
//! supplies small copies of resident text through a nonblocking mailbox.
//! Neither scanning nor destination preparation touches the workspace cache.
const std = @import("std");
const openReadNoFollow = @import("files.zig").openReadNoFollow;
const storage = @import("storage.zig");

pub const chunk_size = 64 * 1024;
pub const max_query_size = 1024;
pub const anchor_stride = 16 * 1024;

/// The editor supplies its display-width rules without introducing a terminal
/// dependency into the content module. A cell consumes one to four bytes.
pub const Cell = struct { len: usize, width: usize };
pub const Anchor = struct { offset: usize, column: usize };
pub const Projection = struct {
    line_start: usize,
    line_end: usize,
    total_columns: usize,
    anchors: []Anchor,

    pub fn deinit(self: *Projection) void {
        std.heap.page_allocator.free(self.anchors);
        self.* = undefined;
    }
};

pub const ProjectedLine = struct {
    file: usize,
    revision: u64,
    line_start: usize,
    line_end: usize,
};

pub const Options = struct {
    file_count: usize,
    origin_file: usize,
    /// Search strictly after this byte position, then wrap through it once.
    /// A sole occurrence at the cursor is returned with wrapped = true.
    origin_offset: usize,
    /// Known number of LF bytes before the origin. Supplying it allows repeat
    /// searches to start at the cursor without rereading the file's prefix.
    origin_row: ?usize = null,
    current_file_only: bool = false,
    cell: ?*const fn ([]const u8, usize) Cell = null,
    /// The editor may retain a projection for an unchanged resident line. This
    /// is only identity/bounds metadata; the worker never borrows its anchors.
    projected_line: ?ProjectedLine = null,
};

pub const Request = struct {
    file: usize,
    offset: usize,
    revision: ?u64 = null,
};

pub const Source = union(enum) {
    resident: struct { len: usize, total_size: usize, revision: u64 },
    // The path must remain alive until completion. The worker never writes it.
    disk: struct { path: []const u8, revision: u64 },
    unavailable: anyerror,
};

pub const Match = struct {
    file: usize,
    offset: usize,
    row: usize,
    revision: u64,
    wrapped: bool,
    // An unloaded destination is prepared on the worker. Ownership transfers
    // with takeResult(); its allocator is independent of the editor allocator.
    document: ?storage.Document = null,
    line_count: ?usize = null,
    projection: ?Projection = null,

    fn deinit(self: *Match) void {
        if (self.document) |*document| document.deinit();
        if (self.projection) |*projection| projection.deinit();
        self.document = null;
        self.projection = null;
    }
};

pub const Result = struct {
    match: ?Match = null,
    skipped: usize = 0,
    failure: ?anyerror = null,

    pub fn deinit(self: *Result) void {
        if (self.match) |*found| found.deinit();
        self.* = .{};
    }
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    options: Options,
    query: [max_query_size]u8 = undefined,
    query_len: usize,
    query_newlines: usize,
    prefix: [max_query_size]usize = undefined,
    thread: ?std.Thread = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    state: enum { idle, requested, answered } = .idle,
    request: Request = undefined,
    response: Source = undefined,
    bytes: [chunk_size]u8 = undefined,
    result: Result = .{},

    pub fn start(allocator: std.mem.Allocator, query: []const u8, options: Options) !*Job {
        if (query.len == 0) return error.EmptyQuery;
        if (query.len > max_query_size) return error.QueryTooLong;
        if (options.file_count == 0 or options.origin_file >= options.file_count) return error.NoFiles;
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .options = options,
            .query_len = query.len,
            .query_newlines = std.mem.count(u8, query, "\n"),
        };
        @memcpy(self.query[0..query.len], query);
        self.prefix[0] = 0;
        var matched: usize = 0;
        for (1..query.len) |i| {
            while (matched > 0 and query[i] != query[matched]) matched = self.prefix[matched - 1];
            if (query[i] == query[matched]) matched += 1;
            self.prefix[i] = matched;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// At most one 64 KiB resident copy. This never waits for the worker.
    /// read runs on the caller's thread and must not perform I/O or load buffers.
    pub fn service(self: *Job, context: anytype, comptime read: fn (@TypeOf(context), Request, []u8) Source) bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock();
        if (self.state != .requested or self.cancelled.load(.acquire)) return false;
        self.response = read(context, self.request, &self.bytes);
        self.state = .answered;
        self.condition.signal();
        return true;
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
        // No lock/join on the input thread. A short timed wait also covers the
        // signal arriving immediately before the worker enters its wait.
        self.condition.signal();
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    /// Only call after isDone(). A result can be taken exactly once.
    pub fn takeResult(self: *Job) Result {
        std.debug.assert(self.isDone());
        self.join();
        const result = self.result;
        self.result = .{};
        return result;
    }

    pub fn deinit(self: *Job) void {
        self.cancel();
        self.join();
        self.result.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn join(self: *Job) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn checkCancelled(self: *const Job) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }

    fn source(self: *Job, request: Request) !Source {
        try self.checkCancelled();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.request = request;
        self.state = .requested;
        while (self.state != .answered) {
            try self.checkCancelled();
            self.condition.timedWait(&self.mutex, 5 * std.time.ns_per_ms) catch {};
        }
        try self.checkCancelled();
        self.state = .idle;
        return self.response;
    }

    fn run(self: *Job) void {
        self.search() catch |err| {
            self.result.failure = err;
        };
        self.done.store(true, .release);
    }

    fn search(self: *Job) !void {
        const origin = self.options.origin_file;
        const after = self.options.origin_offset +| 1;
        var origin_failed = false;
        const begin = if (self.options.origin_row != null) self.options.origin_offset else 0;
        self.result.match = self.scan(origin, after, std.math.maxInt(usize), false, begin, self.options.origin_row orelse 0) catch |err| blk: {
            if (abortSearch(err)) return err;
            self.result.skipped += 1;
            origin_failed = true;
            break :blk null;
        };
        if (self.result.match != null) return;
        if (!self.options.current_file_only) {
            for (1..self.options.file_count) |distance| {
                try self.checkCancelled();
                const file = (origin + distance) % self.options.file_count;
                self.result.match = self.scan(file, 0, std.math.maxInt(usize), file < origin, 0, 0) catch |err| blk: {
                    if (abortSearch(err)) return err;
                    self.result.skipped += 1;
                    break :blk null;
                };
                if (self.result.match != null) return;
            }
        }
        if (!origin_failed) {
            self.result.match = self.scan(origin, 0, after, true, 0, 0) catch |err| blk: {
                if (abortSearch(err)) return err;
                self.result.skipped += 1;
                break :blk null;
            };
        }
    }

    fn scan(self: *Job, file: usize, lower: usize, upper: usize, wrapped: bool, begin: usize, row: usize) !?Match {
        const first = try self.source(.{ .file = file, .offset = begin });
        var result = try switch (first) {
            .resident => |resident| self.scanResident(file, lower, upper, wrapped, begin, row, resident),
            .disk => |disk| self.scanDisk(file, lower, upper, wrapped, begin, row, disk.path, disk.revision),
            .unavailable => |err| err,
        };
        if (result) |*found| {
            errdefer found.deinit();
            const already_projected = if (self.options.projected_line) |hint|
                hint.file == found.file and hint.revision == found.revision and
                    found.offset >= hint.line_start and found.offset <= hint.line_end
            else
                false;
            if (self.options.cell != null and !already_projected) {
                found.projection = if (found.document) |*document|
                    try self.projectDocument(found.offset, document.buffer.bytes.items)
                else
                    try self.projectResident(found.file, found.offset, found.revision);
            }
        }
        return result;
    }

    fn scanResident(self: *Job, file: usize, lower: usize, upper: usize, wrapped: bool, begin: usize, row: usize, first: std.meta.TagPayload(Source, .resident)) !?Match {
        var matcher: Matcher = .{ .job = self, .lower = lower, .upper = upper, .offset = begin, .row = row };
        var part = first;
        while (true) {
            try self.checkCancelled();
            if (part.revision != first.revision or part.total_size != first.total_size) return error.SourceChanged;
            if (part.len > self.bytes.len or matcher.offset > part.total_size or
                part.len > part.total_size - matcher.offset) return error.InvalidSource;
            if (matcher.feed(self.bytes[0..part.len])) |found| {
                return .{ .file = file, .offset = found.offset, .row = found.row, .revision = first.revision, .wrapped = wrapped };
            }
            if (matcher.offset == part.total_size or matcher.finished()) return null;
            if (part.len == 0) return error.InvalidSource;
            const next = try self.source(.{ .file = file, .offset = matcher.offset, .revision = first.revision });
            part = switch (next) {
                .resident => |resident| resident,
                else => return error.SourceChanged,
            };
        }
    }

    fn scanDisk(self: *Job, index: usize, lower: usize, upper: usize, wrapped: bool, begin: usize, row: usize, path: []const u8, revision: u64) !?Match {
        try self.checkCancelled();
        // Nonblocking/no-follow open prevents a replaced catalog entry (FIFO or
        // symlink) from turning a regular-file search into an unbounded wait.
        const file = try openReadNoFollow(std.fs.cwd(), path);
        defer file.close();
        const before = try file.stat();
        if (before.kind != .file) return error.NotRegularFile;
        if (before.size > storage.max_file_size) return error.FileTooBig;
        if (begin > before.size) return error.SourceChanged;
        try file.seekTo(begin);
        var matcher: Matcher = .{ .job = self, .lower = lower, .upper = upper, .offset = begin, .row = row };
        var found: ?Found = null;
        while (matcher.offset < before.size and !matcher.finished()) {
            try self.checkCancelled();
            const remaining: usize = @intCast(before.size - matcher.offset);
            const len = try file.read(self.bytes[0..@min(remaining, self.bytes.len)]);
            if (len == 0) break;
            found = matcher.feed(self.bytes[0..len]);
            if (found != null) break;
        }
        if (!sameVersion(before, try file.stat())) return error.FileChangedOnDisk;
        const location = found orelse return null;
        try self.checkCancelled();
        var document = try storage.Document.open(std.heap.page_allocator, path);
        errdefer document.deinit();
        const loaded = document.saved_stat orelse return error.FileChangedOnDisk;
        if (!sameVersion(before, loaded)) return error.FileChangedOnDisk;
        try self.checkCancelled();
        return .{
            .file = index,
            .offset = location.offset,
            .row = location.row,
            .revision = revision,
            .wrapped = wrapped,
            .document = document,
            .line_count = document.buffer.line_count,
        };
    }

    fn projectDocument(self: *Job, offset: usize, bytes: []const u8) !Projection {
        try self.checkCancelled();
        const line_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..offset], '\n')) |lf| lf + 1 else 0;
        const lf = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n');
        const line_end = if (lf) |end| if (end > line_start and bytes[end - 1] == '\r') end - 1 else end else bytes.len;
        var builder = try ProjectionBuilder.init(self, line_start);
        defer builder.deinit();
        while (builder.offset < line_end) {
            try self.checkCancelled();
            const chunk_end = @min(line_end, builder.offset + chunk_size);
            // The whole document is available, so cells at chunk boundaries
            // can inspect their following bytes without a carry buffer.
            while (builder.offset < chunk_end) try builder.cell(bytes[builder.offset..line_end]);
        }
        return builder.finish(line_end);
    }

    fn residentPart(self: *Job, file: usize, offset: usize, revision: u64) !std.meta.TagPayload(Source, .resident) {
        const part = switch (try self.source(.{ .file = file, .offset = offset, .revision = revision })) {
            .resident => |resident| resident,
            else => return error.SourceChanged,
        };
        if (part.revision != revision or offset > part.total_size) return error.SourceChanged;
        if (part.len > self.bytes.len or part.len > part.total_size - offset or
            (part.len == 0 and offset != part.total_size)) return error.InvalidSource;
        return part;
    }

    fn projectResident(self: *Job, file: usize, offset: usize, revision: u64) !Projection {
        // Find the matched line without copying the document or rereading all
        // its previous lines. Each mailbox turn remains at most one chunk.
        var line_start: usize = 0;
        var probe_end = offset;
        while (probe_end > 0) {
            var probe = probe_end -| chunk_size;
            const block_start = probe;
            var last_lf: ?usize = null;
            while (probe < probe_end) {
                const part = try self.residentPart(file, probe, revision);
                if (part.total_size < probe_end) return error.SourceChanged;
                const count = @min(part.len, probe_end - probe);
                if (std.mem.lastIndexOfScalar(u8, self.bytes[0..count], '\n')) |lf| last_lf = probe + lf;
                probe += count;
            }
            if (last_lf) |lf| {
                line_start = lf + 1;
                break;
            }
            probe_end = block_start;
        }

        var builder = try ProjectionBuilder.init(self, line_start);
        defer builder.deinit();
        var window: [chunk_size + 4]u8 = undefined;
        var carry: usize = 0;
        var read_offset = line_start;
        while (true) {
            const part = try self.residentPart(file, read_offset, revision);
            @memcpy(window[carry..][0..part.len], self.bytes[0..part.len]);
            const length = carry + part.len;
            read_offset += part.len;
            const lf = std.mem.indexOfScalar(u8, window[0..length], '\n');
            const final = lf != null or read_offset == part.total_size;
            const limit = if (lf) |end| if (end > 0 and window[end - 1] == '\r') end - 1 else end else length;
            const line_end = builder.offset + limit;
            var consumed: usize = 0;
            while (consumed < limit) {
                const remaining = window[consumed..limit];
                if (!final) {
                    // Preserve an incomplete scalar or a possible CRLF until
                    // the next copy. Never measure split UTF-8 as replacements.
                    const expected = std.unicode.utf8ByteSequenceLength(remaining[0]) catch 1;
                    if (expected > remaining.len or (remaining[0] == '\r' and remaining.len == 1)) break;
                }
                const before = builder.offset;
                try builder.cell(remaining);
                consumed += builder.offset - before;
            }
            if (final) return builder.finish(line_end);
            carry = length - consumed;
            std.debug.assert(carry <= 3);
            std.mem.copyForwards(u8, window[0..carry], window[consumed..length]);
        }
    }
};

const ProjectionBuilder = struct {
    job: *Job,
    line_start: usize,
    offset: usize,
    column: usize = 0,
    anchors: std.ArrayList(Anchor) = .empty,

    fn init(job: *Job, line_start: usize) !ProjectionBuilder {
        var self: ProjectionBuilder = .{ .job = job, .line_start = line_start, .offset = line_start };
        try self.anchors.append(std.heap.page_allocator, .{ .offset = line_start, .column = 0 });
        return self;
    }

    fn deinit(self: *ProjectionBuilder) void {
        self.anchors.deinit(std.heap.page_allocator);
    }

    fn cell(self: *ProjectionBuilder, bytes: []const u8) !void {
        if (self.offset - self.anchors.items[self.anchors.items.len - 1].offset >= anchor_stride)
            try self.anchors.append(std.heap.page_allocator, .{ .offset = self.offset, .column = self.column });
        const unit = self.job.options.cell.?(bytes, self.column);
        if (unit.len == 0 or unit.len > 4 or unit.len > bytes.len) return error.InvalidCell;
        self.offset += unit.len;
        self.column += unit.width;
    }

    fn finish(self: *ProjectionBuilder, line_end: usize) !Projection {
        if (self.offset != line_end) return error.InvalidProjection;
        if (self.anchors.items[self.anchors.items.len - 1].offset != line_end)
            try self.anchors.append(std.heap.page_allocator, .{ .offset = line_end, .column = self.column });
        return .{
            .line_start = self.line_start,
            .line_end = line_end,
            .total_columns = self.column,
            .anchors = try self.anchors.toOwnedSlice(std.heap.page_allocator),
        };
    }
};

const Found = struct { offset: usize, row: usize };

const Matcher = struct {
    job: *const Job,
    lower: usize,
    upper: usize,
    offset: usize = 0,
    row: usize = 0,
    matched: usize = 0,

    fn feed(self: *Matcher, bytes: []const u8) ?Found {
        const query = self.job.query[0..self.job.query_len];
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            if (self.matched == 0) {
                // No candidate is in progress, so skip directly to its first
                // byte. Count skipped newlines without running KMP per byte.
                const remaining = bytes[index..];
                const skipped = std.mem.indexOfScalar(u8, remaining, query[0]) orelse remaining.len;
                self.row += std.mem.count(u8, remaining[0..skipped], "\n");
                self.offset += skipped;
                index += skipped;
                if (index == bytes.len) return null;
            }
            const byte = bytes[index];
            if (byte == '\n') self.row += 1;
            while (self.matched > 0 and byte != query[self.matched]) self.matched = self.job.prefix[self.matched - 1];
            if (byte == query[self.matched]) self.matched += 1;
            self.offset += 1;
            if (self.matched == query.len) {
                const start = self.offset - query.len;
                self.matched = self.job.prefix[self.matched - 1];
                // A complete match contains exactly the query's newlines.
                // Undo their contribution to recover the row at its start.
                if (start >= self.lower and start < self.upper) return .{ .offset = start, .row = self.row - self.job.query_newlines };
            }
        }
        return null;
    }

    fn finished(self: *const Matcher) bool {
        return self.offset >= self.upper +| (self.job.query_len - 1);
    }
};

fn sameVersion(a: std.fs.File.Stat, b: std.fs.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime and a.ctime == b.ctime;
}

fn abortSearch(err: anyerror) bool {
    return err == error.Cancelled or err == error.OutOfMemory or
        err == error.SourceChanged or err == error.ContentChanged;
}

const TestSources = struct {
    files: []const TestFile,
    requests: usize = 0,
    first_offset: ?usize = null,
    change_after_first: bool = false,

    const TestFile = union(enum) { text: []const u8, disk: []const u8, failed };

    fn read(self: *TestSources, request: Request, destination: []u8) Source {
        if (self.first_offset == null) self.first_offset = request.offset;
        self.requests += 1;
        const revision: u64 = if (self.change_after_first and self.requests > 1) 2 else 1;
        return switch (self.files[request.file]) {
            .text => |text| blk: {
                const offset = @min(request.offset, text.len);
                const len = @min(destination.len, text.len - offset);
                @memcpy(destination[0..len], text[offset..][0..len]);
                break :blk .{ .resident = .{ .len = len, .total_size = text.len, .revision = revision } };
            },
            .disk => |path| .{ .disk = .{ .path = path, .revision = revision } },
            .failed => .{ .unavailable = error.AccessDenied },
        };
    }

    fn finish(self: *TestSources, job: *Job) !Result {
        var timer = try std.time.Timer.start();
        while (!job.isDone()) {
            if (timer.read() > 5 * std.time.ns_per_s) return error.SearchTestTimeout;
            if (!job.service(self, read)) std.Thread.sleep(100 * std.time.ns_per_us);
        }
        return job.takeResult();
    }
};

fn testCell(bytes: []const u8, column: usize) Cell {
    if (bytes[0] == '\t') return .{ .len = 1, .width = 4 - column % 4 };
    if (bytes[0] < 0x20 or bytes[0] == 0x7f) return .{ .len = 1, .width = 2 };
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .len = 1, .width = 1 };
    if (length > bytes.len) return .{ .len = 1, .width = 1 };
    const scalar = std.unicode.utf8Decode(bytes[0..length]) catch return .{ .len = 1, .width = 1 };
    return .{ .len = length, .width = if (scalar == '界') 2 else if (scalar == 0x301) 0 else 1 };
}

fn testColumns(bytes: []const u8) usize {
    var offset: usize = 0;
    var column: usize = 0;
    while (offset < bytes.len) {
        const unit = testCell(bytes[offset..], column);
        offset += unit.len;
        column += unit.width;
    }
    return column;
}

test "matched line projections preserve UTF8 and CRLF across resident chunks" {
    const prefix = "before\r\n";
    const text = try std.testing.allocator.alloc(u8, prefix.len + 2 * chunk_size + 12);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    @memcpy(text[0..prefix.len], prefix);
    @memcpy(text[prefix.len + chunk_size - 1 ..][0..4], "界\t");
    const target = prefix.len + chunk_size + 20;
    @memcpy(text[target..][0..6], "needle");
    const line_end = prefix.len + 2 * chunk_size - 1;
    @memcpy(text[line_end..][0..2], "\r\n");
    const files = [_]TestSources.TestFile{.{ .text = text }};
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, "needle", .{
        .file_count = 1,
        .origin_file = 0,
        .origin_offset = 0,
        .cell = testCell,
    });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    const projection = result.match.?.projection.?;
    try std.testing.expectEqual(prefix.len, projection.line_start);
    try std.testing.expectEqual(line_end, projection.line_end);
    try std.testing.expectEqual(@as(usize, 2 * chunk_size), projection.total_columns);
    try std.testing.expectEqualDeep(Anchor{ .offset = prefix.len, .column = 0 }, projection.anchors[0]);
    try std.testing.expectEqualDeep(Anchor{ .offset = line_end, .column = projection.total_columns }, projection.anchors[projection.anchors.len - 1]);
    for (projection.anchors, 0..) |anchor, index| {
        try std.testing.expectEqual(testColumns(text[prefix.len..anchor.offset]), anchor.column);
        if (index != 0) try std.testing.expect(anchor.offset - projection.anchors[index - 1].offset <= anchor_stride + 3);
    }
}

test "projections handle empty lines and a final bare carriage return" {
    for ([_][]const u8{ "\r\n", "abneedle\r" }) |text| {
        const files = [_]TestSources.TestFile{.{ .text = text }};
        var sources: TestSources = .{ .files = &files };
        const job = try Job.start(std.testing.allocator, if (text.len == 2) "\r" else "needle", .{
            .file_count = 1,
            .origin_file = 0,
            .origin_offset = 0,
            .cell = testCell,
        });
        defer job.deinit();
        var result = try sources.finish(job);
        defer result.deinit();
        const projection = result.match.?.projection.?;
        const end: usize = if (text.len == 2) 0 else text.len;
        try std.testing.expectEqual(end, projection.line_end);
        try std.testing.expectEqual(testColumns(text[0..end]), projection.total_columns);
        try std.testing.expectEqual(@as(usize, 0), projection.anchors[0].offset);
        try std.testing.expectEqual(end, projection.anchors[projection.anchors.len - 1].offset);
    }
}

test "a resident change while preparing display anchors invalidates the match" {
    const files = [_]TestSources.TestFile{.{ .text = " needle" }};
    var sources: TestSources = .{ .files = &files, .change_after_first = true };
    const job = try Job.start(std.testing.allocator, "needle", .{
        .file_count = 1,
        .origin_file = 0,
        .origin_offset = 0,
        .cell = testCell,
    });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expect(result.match == null);
    try std.testing.expectEqual(error.SourceChanged, result.failure.?);
}

test "unchanged line hints reuse editor projection without reading or measuring it" {
    const files = [_]TestSources.TestFile{.{ .text = "first\nneedle" }};
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, "needle", .{
        .file_count = 1,
        .origin_file = 0,
        .origin_offset = 0,
        .cell = struct {
            fn cell(_: []const u8, _: usize) Cell {
                @panic("an existing line projection should not be measured again");
            }
        }.cell,
        .projected_line = .{ .file = 0, .revision = 1, .line_start = 6, .line_end = 12 },
    });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 6), result.match.?.offset);
    try std.testing.expect(result.match.?.projection == null);
    try std.testing.expectEqual(@as(usize, 1), sources.requests);

    const stale = try Job.start(std.testing.allocator, "needle", .{
        .file_count = 1,
        .origin_file = 0,
        .origin_offset = 0,
        .cell = testCell,
        .projected_line = .{ .file = 0, .revision = 0, .line_start = 6, .line_end = 12 },
    });
    defer stale.deinit();
    var stale_result = try sources.finish(stale);
    defer stale_result.deinit();
    try std.testing.expect(stale_result.match.?.projection != null);
}

test "search follows catalog order, wraps once, and honors file scope" {
    const files = [_]TestSources.TestFile{ .{ .text = "hit a" }, .{ .text = "b hit" }, .{ .text = "hit c" } };
    var sources: TestSources = .{ .files = &files };
    const forward = try Job.start(std.testing.allocator, "hit", .{ .file_count = 3, .origin_file = 1, .origin_offset = 2 });
    defer forward.deinit();
    var next = try sources.finish(forward);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 2), next.match.?.file);
    try std.testing.expectEqual(@as(usize, 0), next.match.?.offset);
    try std.testing.expect(!next.match.?.wrapped);

    const wrapped = try Job.start(std.testing.allocator, "hit", .{ .file_count = 3, .origin_file = 2, .origin_offset = 0 });
    defer wrapped.deinit();
    var first = try sources.finish(wrapped);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.match.?.file);
    try std.testing.expect(first.match.?.wrapped);

    const local = try Job.start(std.testing.allocator, "hit", .{ .file_count = 3, .origin_file = 1, .origin_offset = 2, .current_file_only = true });
    defer local.deinit();
    var same = try sources.finish(local);
    defer same.deinit();
    try std.testing.expectEqual(@as(usize, 1), same.match.?.file);
    try std.testing.expectEqual(@as(usize, 2), same.match.?.offset);
    try std.testing.expect(same.match.?.wrapped);
}

test "literal streaming matches across chunks and counts CRLF rows" {
    const text = try std.testing.allocator.alloc(u8, chunk_size + 32);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    @memcpy(text[0..6], "a\r\nb\n\n");
    const target = "界.[needle]";
    const at = chunk_size - 2;
    @memcpy(text[at..][0..target.len], target);
    const files = [_]TestSources.TestFile{.{ .text = text }};
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, target, .{ .file_count = 1, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expectEqual(at, result.match.?.offset);
    try std.testing.expectEqual(@as(usize, 3), result.match.?.row);
    try std.testing.expectEqual(@as(usize, 2), sources.requests);
    try std.testing.expect(result.match.?.document == null);
}

test "overlapping matches start after the cursor and wrap prefix is bounded" {
    const files = [_]TestSources.TestFile{.{ .text = "aaaa" }};
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, "aaa", .{ .file_count = 1, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.match.?.offset);
    try std.testing.expect(!result.match.?.wrapped);
}

test "match rows account for query newlines and repeated prefixes" {
    const Case = struct { text: []const u8, query: []const u8 };
    const cases = [_]Case{
        .{ .text = "before\n\nneedleafter", .query = "\nneedle" },
        .{ .text = "before\nneedle\nend", .query = "needle\n" },
        .{ .text = "before\nneedle\nmiddle\nend", .query = "needle\nmiddle\n" },
        .{ .text = "before\nab\nab\nab\nac\nend", .query = "ab\nab\nac\n" },
        .{ .text = "before\naaaaabaaaaabaaaac", .query = "aaaac" },
        .{ .text = "before\nab\nfailed\nabac\nend", .query = "abac" },
        .{ .text = "before\nend", .query = "\n" },
        .{ .text = "\nneedle\nend", .query = "\nneedle\n" },
    };
    for (cases) |case| {
        const files = [_]TestSources.TestFile{.{ .text = case.text }};
        var sources: TestSources = .{ .files = &files };
        const job = try Job.start(std.testing.allocator, case.query, .{ .file_count = 1, .origin_file = 0, .origin_offset = 0 });
        defer job.deinit();
        var result = try sources.finish(job);
        defer result.deinit();
        const expected = std.mem.indexOf(u8, case.text, case.query).?;
        try std.testing.expectEqual(expected, result.match.?.offset);
        try std.testing.expectEqual(std.mem.count(u8, case.text[0..expected], "\n"), result.match.?.row);
        try std.testing.expectEqual(expected == 0, result.match.?.wrapped);
    }
}

test "multiline match rows survive chunk boundaries and prefix fallback" {
    const text = try std.testing.allocator.alloc(u8, chunk_size + 32);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    @memcpy(text[0..6], "a\r\nb\n\n");
    const target = "ab\nab\nac\n";
    const at = chunk_size - 2;
    // The extra prefix starts a candidate that fails after the chunk boundary.
    @memcpy(text[at - 3 .. at], "ab\n");
    @memcpy(text[at..][0..target.len], target);
    const files = [_]TestSources.TestFile{.{ .text = text }};
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, target, .{ .file_count = 1, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expectEqual(at, result.match.?.offset);
    try std.testing.expectEqual(@as(usize, 4), result.match.?.row);
    try std.testing.expectEqual(@as(usize, 2), sources.requests);
}

test "unavailable files are skipped once and missing matches complete" {
    const files = [_]TestSources.TestFile{ .failed, .{ .text = "" }, .{ .text = "haystack" } };
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, "needle", .{ .file_count = 3, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expect(result.match == null);
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
}

test "resident versions cannot be mixed across chunks" {
    const text = try std.testing.allocator.alloc(u8, chunk_size + 10);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    @memcpy(text[chunk_size..][0..6], "needle");
    const files = [_]TestSources.TestFile{.{ .text = text }};
    var sources: TestSources = .{ .files = &files, .change_after_first = true };
    const job = try Job.start(std.testing.allocator, "needle", .{ .file_count = 1, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expect(result.match == null);
    try std.testing.expectEqual(error.SourceChanged, result.failure.?);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
}

test "repeat search starts at the origin and counts its LF or CRLF once" {
    const text = try std.testing.allocator.alloc(u8, 4 * chunk_size + 32);
    defer std.testing.allocator.free(text);
    const origin = 4 * chunk_size;
    for ([_][]const u8{ "\nneedle", "\r\nneedle" }) |suffix| {
        @memset(text, 'x');
        @memcpy(text[0..6], "a\r\nb\n\n");
        @memcpy(text[origin..][0..suffix.len], suffix);
        const files = [_]TestSources.TestFile{.{ .text = text }};
        var sources: TestSources = .{ .files = &files };
        const job = try Job.start(std.testing.allocator, "needle", .{
            .file_count = 1,
            .origin_file = 0,
            .origin_offset = origin,
            .origin_row = 3,
        });
        defer job.deinit();
        var result = try sources.finish(job);
        defer result.deinit();
        try std.testing.expectEqual(@as(?usize, origin), sources.first_offset);
        try std.testing.expectEqual(@as(usize, 1), sources.requests);
        try std.testing.expectEqual(origin + suffix.len - "needle".len, result.match.?.offset);
        try std.testing.expectEqual(@as(usize, 4), result.match.?.row);
        try std.testing.expect(!result.match.?.wrapped);
    }
}

test "cancellation wakes a worker waiting for resident text" {
    const job = try Job.start(std.testing.allocator, "needle", .{ .file_count = 1, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    // No UI response is necessary to cancel a pending request.
    job.cancel();
    var timer = try std.time.Timer.start();
    while (!job.isDone()) {
        if (timer.read() > std.time.ns_per_s) return error.SearchTestTimeout;
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    var result = job.takeResult();
    defer result.deinit();
    try std.testing.expectEqual(error.Cancelled, result.failure.?);
}

test "disk search prepares only its matched destination and rejects oversized files" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "hay\r\nneedle\r\nlast" });
    const huge = try temp.dir.createFile("huge", .{});
    try huge.setEndPos(storage.max_file_size + 1);
    huge.close();
    const path = try temp.dir.realpathAlloc(std.testing.allocator, "a");
    defer std.testing.allocator.free(path);
    const huge_path = try temp.dir.realpathAlloc(std.testing.allocator, "huge");
    defer std.testing.allocator.free(huge_path);
    const files = [_]TestSources.TestFile{ .{ .disk = huge_path }, .{ .disk = path } };
    var sources: TestSources = .{ .files = &files };
    const job = try Job.start(std.testing.allocator, "needle", .{ .file_count = 2, .origin_file = 0, .origin_offset = 0 });
    defer job.deinit();
    var result = try sources.finish(job);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), result.match.?.file);
    try std.testing.expectEqual(@as(usize, 5), result.match.?.offset);
    try std.testing.expectEqual(@as(usize, 1), result.match.?.row);
    try std.testing.expectEqual(@as(?usize, 3), result.match.?.line_count);
    try std.testing.expectEqualStrings("hay\r\nneedle\r\nlast", result.match.?.document.?.buffer.bytes.items);
    try std.testing.expectEqualStrings("\r\n", result.match.?.document.?.buffer.newline);

    const resumed = try Job.start(std.testing.allocator, "needle", .{
        .file_count = 2,
        .origin_file = 1,
        .origin_offset = 3,
        .origin_row = 0,
        .cell = testCell,
    });
    defer resumed.deinit();
    var resumed_result = try sources.finish(resumed);
    defer resumed_result.deinit();
    try std.testing.expectEqual(@as(usize, 5), resumed_result.match.?.offset);
    try std.testing.expectEqual(@as(usize, 1), resumed_result.match.?.row);
    try std.testing.expect(!resumed_result.match.?.wrapped);
    const projection = resumed_result.match.?.projection.?;
    try std.testing.expectEqual(@as(usize, 5), projection.line_start);
    try std.testing.expectEqual(@as(usize, 11), projection.line_end);
    try std.testing.expectEqual(@as(usize, 6), projection.total_columns);
}
