const std = @import("std");
const common = @import("common.zig");
const file_stats = @import("file_stats.zig");

const usage =
    \\Usage: zig build benchmark-scroll -- <repository> [options]
    \\
    \\  --steps N       Send N Page Down events (default: one traversal).
    \\  --rows N        Viewport rows (default: 40, minimum: 3).
    \\  --cols N        Viewport columns (default: 120, minimum: 2).
    \\  --output PATH   Create a JSONL report outside the target directory.
    \\
;

const Options = struct {
    repository: []const u8 = "",
    binary: []const u8 = "",
    steps: ?usize = null,
    rows: usize = 40,
    cols: usize = 120,
    output: ?[]const u8 = null,

    fn parse(args: []const []const u8) !?Options {
        var options: Options = .{};
        var positionals_only = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (!positionals_only and std.mem.eql(u8, arg, "--")) {
                positionals_only = true;
            } else if (!positionals_only and std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return null;
                var parts = std.mem.splitScalar(u8, arg, '=');
                const flag = parts.first();
                const kind: enum { binary, steps, rows, cols, output } = if (std.mem.eql(u8, flag, "--binary"))
                    .binary
                else if (std.mem.eql(u8, flag, "--steps"))
                    .steps
                else if (std.mem.eql(u8, flag, "--rows"))
                    .rows
                else if (std.mem.eql(u8, flag, "--cols"))
                    .cols
                else if (std.mem.eql(u8, flag, "--output"))
                    .output
                else
                    return error.UnknownOption;
                const argument = if (parts.index != null) parts.rest() else blk: {
                    index += 1;
                    if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingOptionValue;
                    break :blk args[index];
                };
                switch (kind) {
                    .binary => options.binary = argument,
                    .steps => options.steps = std.fmt.parseInt(usize, argument, 10) catch return error.InvalidSteps,
                    .rows => options.rows = std.fmt.parseInt(usize, argument, 10) catch return error.InvalidRows,
                    .cols => options.cols = std.fmt.parseInt(usize, argument, 10) catch return error.InvalidCols,
                    .output => options.output = argument,
                }
            } else {
                if (options.repository.len != 0) return error.UnexpectedArgument;
                options.repository = arg;
            }
        }
        if (options.repository.len == 0) return error.ExpectedRepository;
        if (options.binary.len == 0) return error.ExpectedWorkerBinary;
        if (options.steps == 0) return error.InvalidSteps;
        if (options.rows < 3) return error.InvalidRows;
        if (options.cols < 2) return error.InvalidCols;
        return options;
    }
};

pub fn main() void {
    run() catch |err| {
        std.debug.print("benchmark-scroll: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    const options = (Options.parse(args[1..]) catch |err| {
        std.debug.print("{s}", .{usage});
        return err;
    }) orelse return common.print("{s}", .{usage});
    const expanded_root = try common.expandHome(allocator, options.repository);
    const root = try std.fs.cwd().realpathAlloc(allocator, expanded_root);
    var dir = try std.fs.openDirAbsolute(root, .{});
    defer dir.close();
    const result_path = try common.resultPath(allocator, options.output, "scroll-", root);
    const file = try common.createResult(result_path);
    defer file.close();
    var output_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&output_buffer);
    const output = &file_writer.interface;
    common.installInterruptHandler();

    const workload = if (options.steps) |steps| try std.fmt.allocPrint(allocator, "{d}", .{steps}) else "one traversal";
    try common.print("Results: {s}\nRepository: {s}\nWorkload: {s} Page Down; {d} rows x {d} columns\n", .{
        result_path, root, workload, options.rows, options.cols,
    });
    runReport(allocator, options, root, dir, output) catch |err| {
        try common.finish(output, err);
        return err;
    };
    try common.finish(output, null);
}

fn runReport(allocator: std.mem.Allocator, options: Options, root: []const u8, dir: std.fs.Dir, output: *std.Io.Writer) !void {
    const metadata = try common.runMetadata(allocator);
    const revision = try common.commandOutput(allocator, &.{ "git", "-C", root, "rev-parse", "HEAD" });
    try common.emitRun(output, metadata, .{
        .suite = "repository_scroll",
        .suite_version = 1,
        .repository = root,
        .repository_revision = revision,
        .steps = options.steps,
        .rows = options.rows,
        .cols = options.cols,
        .os_cache = "uncontrolled; no pre-run content inventory or discarded warmup",
        .workload = "Page Down then frame generation, sequentially without pacing",
        .excluded = "terminal input, terminal writes/display, JSON reporting, post-run inventory",
        .inventory = "post-run snapshot of discovered regular files; LF+1 logical lines",
    });

    var report: Report = .{ .allocator = allocator };
    const worker_wall_ns = try runWorker(&report, options, root, output);
    try report.validate(options.steps);
    try common.emit(output, .{
        .type = "worker_wall",
        .elapsed_ns = worker_wall_ns,
        .includes = "process startup, discovery, measured work, and JSON reporting",
    });
    try report.summarize(output);
    try common.print("Collecting post-run file and line statistics...\n", .{});
    const inventory = try report.inventory(dir, output);
    try common.checkInterrupted();
    try report.printResults(inventory);
}

fn runWorker(report: *Report, options: Options, root: []const u8, output: *std.Io.Writer) !u64 {
    var steps_buffer: [32]u8 = undefined;
    var rows_buffer: [32]u8 = undefined;
    var cols_buffer: [32]u8 = undefined;
    const argv = [_][]const u8{
        options.binary,
        root,
        try std.fmt.bufPrint(&steps_buffer, "{d}", .{options.steps orelse 0}),
        try std.fmt.bufPrint(&rows_buffer, "{d}", .{options.rows}),
        try std.fmt.bufPrint(&cols_buffer, "{d}", .{options.cols}),
    };
    var timer = try std.time.Timer.start();
    var last_progress: u64 = 0;
    var child = std.process.Child.init(&argv, report.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    errdefer _ = child.kill() catch {};
    var poller = std.Io.poll(std.heap.page_allocator, enum { stdout }, .{ .stdout = child.stdout.? });
    defer poller.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const stdout = poller.reader(.stdout);
    while (true) {
        try common.checkInterrupted();
        const active = try poller.pollTimeout(100 * std.time.ns_per_ms);
        const previous_count = report.scroll.items.len;
        while (std.mem.indexOfScalar(u8, stdout.buffered(), '\n')) |end| {
            try common.checkInterrupted();
            try report.receive(&scratch, stdout.buffered()[0..end], output);
            stdout.toss(end + 1);
        }
        const now = timer.read();
        if (now - last_progress >= 5 * std.time.ns_per_s and report.scroll.items.len != previous_count) {
            last_progress = now;
            try common.print("  {d} pages; current file index {?d}\n", .{ report.scroll.items.len, report.current_file });
        }
        if (!active) break;
    }
    if (stdout.buffered().len != 0) try report.receive(&scratch, stdout.buffered(), output);
    const term = try child.wait();
    try common.checkInterrupted();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("tome-scroll worker terminated with {any}\n", .{term});
        return error.WorkerFailed;
    }
    return timer.read();
}

const Worker = struct { max_file_size: u64, discovered_files: usize, discovery_ns: u64 };
const Complete = struct { steps: usize, stop_reason: []const u8, discovered_files: usize };
const CatalogEntry = struct { file_index: usize, file_name: []const u8, line_count: ?u64, error_name: ?[]const u8 };
const Timing = struct { metric: enum { startup_to_frame, scroll_to_frame }, elapsed_ns: u64 };
const ScrollSample = struct {
    iteration: usize,
    elapsed_ns: u64,
    before_file_index: ?usize,
    before_cursor_byte: usize,
    file_index: ?usize,
    cursor_byte: usize,
    rendered_bytes: usize,

    fn fasterThan(self: ScrollSample, other: ScrollSample) bool {
        if (self.elapsed_ns == other.elapsed_ns) return self.iteration < other.iteration;
        return self.elapsed_ns < other.elapsed_ns;
    }
};

const TimingSummary = struct {
    type: []const u8 = "summary",
    metric: []const u8,
    sample_count: usize,
    total_ns: u128,
    min_ns: ?u64 = null,
    median_ns: ?f64 = null,
    p95_ns: ?u64 = null,
    max_ns: ?u64 = null,
    over_16_67_ms: usize,

    fn from(metric: []const u8, values: []u64) TimingSummary {
        var total: u128 = 0;
        var over: usize = 0;
        for (values) |ns| {
            total += ns;
            if (ns > std.time.ns_per_s / 60) over += 1;
        }
        var summary: TimingSummary = .{ .metric = metric, .sample_count = values.len, .total_ns = total, .over_16_67_ms = over };
        if (values.len != 0) {
            std.mem.sort(u64, values, {}, std.sort.asc(u64));
            summary.min_ns = values[0];
            summary.median_ns = common.median(values);
            summary.p95_ns = common.p95(values);
            summary.max_ns = values[values.len - 1];
        }
        return summary;
    }
};

const RepositorySummary = struct {
    type: []const u8 = "repository_summary",
    file_count: usize = 0,
    loaded_files: usize = 0,
    failed_files: usize = 0,
    unvisited_files: usize = 0,
    stats_files: usize = 0,
    stats_unavailable_files: usize = 0,
    total_bytes: u128 = 0,
    total_lines: u128 = 0,
    max_line_bytes: u64 = 0,
    line_size_counts: file_stats.LineSizeCounts = .{},
    changed_during_inventory: usize = 0,
    line_count_mismatches: usize = 0,
};

const FileRecord = struct {
    entry: CatalogEntry,
    stats: file_stats.FileStats,

    fn matches(self: FileRecord) ?bool {
        if (self.entry.line_count == null or self.stats.stats_status != .ok) return null;
        return self.entry.line_count == self.stats.line_count;
    }

    pub fn jsonStringify(self: FileRecord, jws: *std.json.Stringify) !void {
        try jws.beginObject();
        try common.jsonFields(jws, .{
            .type = "file",
            .file_index = self.entry.file_index,
            .file_name = self.entry.file_name,
            .error_name = self.entry.error_name,
            .measured_line_count = self.entry.line_count,
            .loaded = self.entry.line_count != null,
            .line_count_matches_measurement = self.matches(),
        });
        try self.stats.writeFields(jws);
        try jws.endObject();
    }

    fn largerThan(_: void, a: FileRecord, b: FileRecord) bool {
        return (a.stats.byte_count orelse 0) > (b.stats.byte_count orelse 0);
    }
};

const Inventory = struct { summary: RepositorySummary, files: []FileRecord };

const Report = struct {
    allocator: std.mem.Allocator,
    worker: ?Worker = null,
    complete: ?Complete = null,
    catalog: std.ArrayList(CatalogEntry) = .empty,
    startup: ?u64 = null,
    scroll: std.ArrayList(u64) = .empty,
    slowest: [10]ScrollSample = undefined,
    slow_count: usize = 0,
    current_file: ?usize = null,
    summaries: [2]TimingSummary = undefined,

    fn receive(self: *Report, arena: *std.heap.ArenaAllocator, line: []const u8, output: *std.Io.Writer) !void {
        defer _ = arena.reset(.retain_capacity);
        const scratch = arena.allocator();
        var record = try std.json.parseFromSliceLeaky(std.json.Value, scratch, line, .{});
        if (record != .object or self.complete != null) return error.UnexpectedWorkerRecord;
        const kind = record.object.get("type") orelse return error.UnexpectedWorkerRecord;
        if (kind != .string) return error.UnexpectedWorkerRecord;
        if (std.mem.eql(u8, kind.string, "worker")) {
            if (self.worker != null) return error.DuplicateWorkerMetadata;
            self.worker = try decode(Worker, scratch, record);
        } else {
            if (self.worker == null) return error.MissingWorkerMetadata;
            if (std.mem.eql(u8, kind.string, "sample")) {
                const timing = try decode(Timing, scratch, record);
                switch (timing.metric) {
                    .startup_to_frame => {
                        if (self.startup != null) return error.DuplicateStartupSample;
                        self.startup = timing.elapsed_ns;
                    },
                    .scroll_to_frame => {
                        const sample = try decode(ScrollSample, scratch, record);
                        if (sample.iteration != self.scroll.items.len) return error.InvalidWorkerIteration;
                        if (sample.file_index) |index| {
                            if (index >= self.worker.?.discovered_files) return error.InvalidWorkerFileIndex;
                        }
                        self.current_file = sample.file_index;
                        try self.scroll.append(self.allocator, sample.elapsed_ns);
                        self.keepSlowest(sample);
                    },
                }
            } else if (std.mem.eql(u8, kind.string, "file")) {
                var entry = try decode(CatalogEntry, scratch, record);
                if (entry.file_index != self.catalog.items.len) return error.InvalidWorkerFileIndex;
                entry.file_name = try self.allocator.dupe(u8, entry.file_name);
                if (entry.error_name) |name| entry.error_name = try self.allocator.dupe(u8, name);
                try self.catalog.append(self.allocator, entry);
                record.object.getPtr("type").?.* = .{ .string = "catalog_file" };
            } else if (std.mem.eql(u8, kind.string, "complete")) {
                var complete = try decode(Complete, scratch, record);
                complete.stop_reason = try self.allocator.dupe(u8, complete.stop_reason);
                self.complete = complete;
            } else {
                return error.UnexpectedWorkerRecord;
            }
        }
        try common.emit(output, record);
    }

    fn decode(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
        return std.json.parseFromValueLeaky(T, allocator, value, .{ .ignore_unknown_fields = true });
    }

    fn keepSlowest(self: *Report, sample: ScrollSample) void {
        var position: usize = 0;
        while (position < self.slow_count and !self.slowest[position].fasterThan(sample)) : (position += 1) {}
        if (position == self.slowest.len) return;
        self.slow_count = @min(self.slow_count + 1, self.slowest.len);
        std.mem.copyBackwards(ScrollSample, self.slowest[position + 1 .. self.slow_count], self.slowest[position .. self.slow_count - 1]);
        self.slowest[position] = sample;
    }

    fn validate(self: *const Report, requested_steps: ?usize) !void {
        const worker = self.worker orelse return error.MissingWorkerMetadata;
        const complete = self.complete orelse return error.IncompleteTraversal;
        if (self.startup == null) return error.MissingStartupSample;
        if (self.catalog.items.len != worker.discovered_files or self.catalog.items.len != complete.discovered_files) return error.IncompleteCatalog;
        if (self.scroll.items.len != complete.steps or complete.steps != (requested_steps orelse complete.steps)) return error.IncompleteTraversal;
    }

    fn summarize(self: *Report, output: *std.Io.Writer) !void {
        var startup_values = [_]u64{self.startup.?};
        self.summaries = .{
            TimingSummary.from("startup_to_frame", &startup_values),
            TimingSummary.from("scroll_to_frame", self.scroll.items),
        };
        for (self.summaries) |summary| try common.emit(output, summary);
        for (self.slowest[0..self.slow_count]) |sample| {
            try common.emit(output, .{
                .type = "slow_frame",
                .metric = "scroll_to_frame",
                .iteration = sample.iteration,
                .elapsed_ns = sample.elapsed_ns,
                .before_file_index = sample.before_file_index,
                .before_cursor_byte = sample.before_cursor_byte,
                .file_index = sample.file_index,
                .cursor_byte = sample.cursor_byte,
                .rendered_bytes = sample.rendered_bytes,
                .file_name = self.sampleName(sample),
            });
        }
    }

    fn sampleName(self: *const Report, sample: ScrollSample) ?[]const u8 {
        return if (sample.file_index) |index| self.catalog.items[index].file_name else null;
    }

    fn inventory(self: *const Report, dir: std.fs.Dir, output: *std.Io.Writer) !Inventory {
        const files = try self.allocator.alloc(FileRecord, self.catalog.items.len);
        var summary: RepositorySummary = .{ .file_count = files.len };
        for (self.catalog.items, files) |entry, *record| {
            try common.checkInterrupted();
            const stats = file_stats.read(dir, entry.file_name, self.worker.?.max_file_size);
            record.* = .{ .entry = entry, .stats = stats };
            try common.emit(output, record.*);
            summary.loaded_files += @intFromBool(entry.line_count != null);
            summary.failed_files += @intFromBool(entry.error_name != null);
            summary.unvisited_files += @intFromBool(entry.line_count == null and entry.error_name == null);
            summary.total_bytes += stats.byte_count orelse 0;
            summary.changed_during_inventory += @intFromBool(stats.changed_during_inventory orelse false);
            summary.line_count_mismatches += @intFromBool(record.matches() == false);
            if (stats.stats_status == .ok) {
                summary.stats_files += 1;
                summary.total_lines += stats.line_count.?;
                summary.max_line_bytes = @max(summary.max_line_bytes, stats.max_line_bytes.?);
                summary.line_size_counts.add(stats.line_size_counts.?);
            } else {
                summary.stats_unavailable_files += 1;
            }
        }
        try common.emit(output, summary);
        return .{ .summary = summary, .files = files };
    }

    fn printResults(self: *const Report, result: Inventory) !void {
        const complete = self.complete.?;
        try common.print("\nDiscovery: {d:.3} ms; {d} Page Down events ({s}).\n", .{
            millis(self.worker.?.discovery_ns), complete.steps, complete.stop_reason,
        });
        for (self.summaries) |summary| {
            if (summary.sample_count == 0) continue;
            try common.print("{s}: total {d:.3} s; median {d:.3} ms; p95 {d:.3} ms; max {d:.3} ms ({d} over 16.67 ms)\n", .{
                summary.metric,
                @as(f64, @floatFromInt(summary.total_ns)) / std.time.ns_per_s,
                summary.median_ns.? / std.time.ns_per_ms,
                millis(summary.p95_ns.?),
                millis(summary.max_ns.?),
                summary.over_16_67_ms,
            });
        }
        const repo = result.summary;
        try common.print("Files: {d} discovered, {d} loaded, {d} failed, {d} unvisited.\n", .{
            repo.file_count, repo.loaded_files, repo.failed_files, repo.unvisited_files,
        });
        try common.print("Post-run inventory: {d} bytes, {d} lines; longest line {d} bytes ({d} files without line stats).\n", .{
            repo.total_bytes, repo.total_lines, repo.max_line_bytes, repo.stats_unavailable_files,
        });
        const counts = repo.line_size_counts;
        try common.print("Line sizes (content bytes): 0: {d}, 1-80: {d}, 81-256: {d}, 257-1024: {d}, 1025-4096: {d}, 4097-65536: {d}, 65537+: {d}\n", .{
            counts.@"0", counts.@"1-80", counts.@"81-256", counts.@"257-1024", counts.@"1025-4096", counts.@"4097-65536", counts.@"65537+",
        });
        if (repo.changed_during_inventory > 0 or repo.line_count_mismatches > 0) {
            try common.print("Inventory changes: {d} changed while scanning; {d} line counts differ from the measured workload.\n", .{
                repo.changed_during_inventory, repo.line_count_mismatches,
            });
        }
        try common.print("Largest files (bytes / lines / longest line bytes):\n", .{});
        std.mem.sort(FileRecord, result.files, {}, FileRecord.largerThan);
        for (result.files[0..@min(5, result.files.len)]) |record| {
            try common.print("  {?d} / {?d} / {?d}  {s}\n", .{
                record.stats.byte_count, record.stats.line_count, record.stats.max_line_bytes, record.entry.file_name,
            });
        }
        try common.print("Slowest scroll events (destination file; event can cross multiple files):\n", .{});
        for (self.slowest[0..@min(5, self.slow_count)]) |sample| {
            try common.print("  {d:.3} ms  page {d}  {s}\n", .{
                millis(sample.elapsed_ns), sample.iteration + 1, self.sampleName(sample) orelse "(empty workspace)",
            });
        }
    }
};

fn millis(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const TestWorkerOutput = struct {
    output: *std.Io.Writer,

    pub fn json(self: *TestWorkerOutput, value: anytype) !void {
        try common.emit(self.output, value);
    }
};

fn reportFromTestWorkspace(allocator: std.mem.Allocator, root: []const u8, steps: ?usize, output: *std.Io.Writer) !Report {
    const worker = @import("scroll_worker");
    var messages: std.Io.Writer.Allocating = .init(allocator);
    defer messages.deinit();
    var sink: TestWorkerOutput = .{ .output = &messages.writer };
    try worker.runScroll(allocator, root, steps orelse 0, 6, 40, &sink);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var report: Report = .{ .allocator = allocator };
    var lines = std.mem.tokenizeScalar(u8, messages.written(), '\n');
    while (lines.next()) |line| try report.receive(&scratch, line, output);
    try report.validate(steps);
    try report.summarize(output);
    return report;
}

test "inventory follows the editor catalog, preserves bytes, and reports CRLF and empty lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makeDir("nested");
    try temp.dir.makeDir(".git");
    const contents = .{
        .{ "a.txt", "one\r\ntwo\r\n" },
        .{ ".hidden", "" },
        .{ "nested/b.txt", "line\n" ** 19 ++ "line" },
        .{ ".git/ignored", "not part of the editor workspace" },
    };
    inline for (contents) |entry| try temp.dir.writeFile(.{ .sub_path = entry[0], .data = entry[1] });
    try temp.dir.symLink("a.txt", "link", .{});
    const root = try temp.dir.realpathAlloc(allocator, ".");
    var output: std.Io.Writer.Allocating = .init(allocator);
    var report = try reportFromTestWorkspace(allocator, root, null, &output.writer);
    const inventory = try report.inventory(temp.dir, &output.writer);

    const summary = inventory.summary;
    try std.testing.expectEqual(@as(usize, 3), summary.file_count);
    try std.testing.expectEqual(@as(usize, 3), summary.loaded_files);
    try std.testing.expectEqual(@as(usize, 3), summary.stats_files);
    try std.testing.expectEqual(@as(usize, 0), summary.failed_files);
    try std.testing.expectEqual(@as(usize, 0), summary.unvisited_files);
    try std.testing.expectEqual(@as(u128, 24), summary.total_lines);
    try std.testing.expectEqual(@as(u128, 109), summary.total_bytes);
    try std.testing.expectEqualStrings("nested/b.txt", inventory.files[0].entry.file_name);
    try std.testing.expectEqualStrings(".hidden", inventory.files[1].entry.file_name);
    try std.testing.expectEqual(@as(?u64, 1), inventory.files[1].stats.line_count);
    const crlf = inventory.files[2];
    try std.testing.expectEqualStrings("a.txt", crlf.entry.file_name);
    try std.testing.expectEqual(@as(?u64, 3), crlf.stats.line_count);
    try std.testing.expectEqual(@as(?u64, 3), crlf.entry.line_count);
    try std.testing.expectEqual(@as(?u64, 6), crlf.stats.content_byte_count);
    try std.testing.expectEqual(@as(?u64, 3), crlf.stats.max_line_bytes);
    try std.testing.expectEqual(@as(u64, 1), crlf.stats.line_size_counts.?.@"0");
    inline for (contents) |entry| {
        const actual = try temp.dir.readFileAlloc(allocator, entry[0], 1024);
        try std.testing.expectEqualStrings(entry[1], actual);
    }
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("a.txt", try temp.dir.readLink("link", &link_buffer));
}

test "fixed scroll summaries count only requested events and distinguish failed and unvisited files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const max_size = 64 * 1024 * 1024;
    {
        const huge = try temp.dir.createFile("a-oversized", .{});
        defer huge.close();
        try huge.setEndPos(max_size + 1);
    }
    try temp.dir.writeFile(.{ .sub_path = "b-scroll", .data = "line\n" ** 100 });
    try temp.dir.writeFile(.{ .sub_path = "c-later", .data = "later" });
    const root = try temp.dir.realpathAlloc(allocator, ".");
    var output: std.Io.Writer.Allocating = .init(allocator);
    var report = try reportFromTestWorkspace(allocator, root, 3, &output.writer);
    const inventory = try report.inventory(temp.dir, &output.writer);

    const timing = report.summaries[1];
    try std.testing.expectEqual(@as(usize, 3), timing.sample_count);
    try std.testing.expectEqual(@as(usize, 3), report.slow_count);
    var sample_total: u128 = 0;
    for (report.slowest[0..report.slow_count]) |sample| sample_total += sample.elapsed_ns;
    try std.testing.expectEqual(sample_total, timing.total_ns);
    try std.testing.expect(timing.max_ns.? >= timing.p95_ns.?);
    try std.testing.expect(@as(f64, @floatFromInt(timing.max_ns.?)) >= timing.median_ns.?);
    const summary = inventory.summary;
    try std.testing.expectEqual(@as(usize, 3), summary.file_count);
    try std.testing.expectEqual(@as(usize, 1), summary.loaded_files);
    try std.testing.expectEqual(@as(usize, 1), summary.failed_files);
    try std.testing.expectEqual(@as(usize, 1), summary.unvisited_files);
    try std.testing.expectEqual(@as(usize, 2), summary.stats_files);
    const oversized = inventory.files[0];
    try std.testing.expectEqualStrings("FileTooBig", oversized.entry.error_name.?);
    try std.testing.expectEqual(.oversized, oversized.stats.stats_status);
    try std.testing.expectEqual(@as(?u64, max_size + 1), oversized.stats.byte_count);
    try std.testing.expectEqual(@as(?u64, null), oversized.stats.line_count);
    try std.testing.expectEqual(@as(?u64, null), oversized.entry.line_count);
}
