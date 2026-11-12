const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const ScenarioOptions = struct {
    repetitions: usize = 30,
    prefixes: std.ArrayList([]const u8) = .empty,
    list: bool = false,
    output_path: ?[]const u8 = null,

    pub fn parse(allocator: Allocator, args: []const [:0]const u8) !?ScenarioOptions {
        var options: ScenarioOptions = .{};
        errdefer options.prefixes.deinit(allocator);
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                options.prefixes.deinit(allocator);
                return null;
            }
            if (std.mem.eql(u8, arg, "--list")) {
                options.list = true;
                continue;
            }
            var parts = std.mem.splitScalar(u8, arg, '=');
            const option = parts.first();
            const kind: enum { repetitions, scenario, output } = if (std.mem.eql(u8, option, "--repetitions"))
                .repetitions
            else if (std.mem.eql(u8, option, "--scenario"))
                .scenario
            else if (std.mem.eql(u8, option, "--output"))
                .output
            else
                return error.UnknownOption;
            const value = if (parts.index != null) parts.rest() else value: {
                index += 1;
                if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingOptionValue;
                break :value args[index];
            };
            switch (kind) {
                .repetitions => {
                    options.repetitions = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRepetitions;
                    if (options.repetitions == 0) return error.InvalidRepetitions;
                },
                .scenario => try options.prefixes.append(allocator, value),
                .output => options.output_path = value,
            }
        }
        return options;
    }

    pub fn selects(options: ScenarioOptions, name: []const u8) bool {
        if (options.prefixes.items.len == 0) return true;
        for (options.prefixes.items) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) return true;
        }
        return false;
    }
};

pub fn emit(output: *std.Io.Writer, record: anytype) !void {
    try std.json.Stringify.value(record, .{}, output);
    try output.writeByte('\n');
    try output.flush();
}

pub fn print(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try stdout.interface.print(fmt, args);
    try stdout.interface.flush();
}

pub fn jsonFields(json: *std.json.Stringify, fields: anytype) !void {
    inline for (std.meta.fields(@TypeOf(fields))) |field| {
        try json.objectField(field.name);
        try json.write(@field(fields, field.name));
    }
}

pub const RunMetadata = struct {
    type: []const u8 = "run",
    started_utc: []const u8,
    revision: ?[]const u8,
    working_tree_dirty: bool,
    platform: []const u8,
    architecture: []const u8,
    cpu: ?[]const u8,
    logical_cpus: ?usize,

    pub fn deinit(self: RunMetadata, allocator: Allocator) void {
        allocator.free(self.started_utc);
        if (self.revision) |value| allocator.free(value);
        allocator.free(self.platform);
        allocator.free(self.architecture);
        if (self.cpu) |value| allocator.free(value);
    }
};

pub fn emitRun(output: *std.Io.Writer, metadata: RunMetadata, fields: anytype) !void {
    var json: std.json.Stringify = .{ .writer = output };
    try json.beginObject();
    try jsonFields(&json, metadata);
    try jsonFields(&json, fields);
    try json.endObject();
    try output.writeByte('\n');
    try output.flush();
}

pub fn commandOutput(allocator: Allocator, argv: []const []const u8) !?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = std.posix.getenv("TOME_MEASUREMENT_ROOT"),
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return null;
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

pub fn runMetadata(allocator: Allocator) !RunMetadata {
    const started = try utcStamp(allocator, std.time.microTimestamp(), true);
    errdefer allocator.free(started);
    const revision = try commandOutput(allocator, &.{ "git", "rev-parse", "HEAD" });
    errdefer if (revision) |value| allocator.free(value);
    const status = try commandOutput(allocator, &.{ "git", "status", "--porcelain" });
    defer if (status) |value| allocator.free(value);
    const os = std.posix.uname();
    const architecture = try allocator.dupe(u8, std.mem.sliceTo(&os.machine, 0));
    errdefer allocator.free(architecture);
    const platform = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
        std.mem.sliceTo(&os.sysname, 0), std.mem.sliceTo(&os.release, 0), architecture,
    });
    errdefer allocator.free(platform);
    const cpu = if (builtin.os.tag == .macos)
        try commandOutput(allocator, &.{ "sysctl", "-n", "machdep.cpu.brand_string" })
    else
        null;
    return .{
        .started_utc = started,
        .revision = revision,
        .working_tree_dirty = if (status) |value| value.len != 0 else false,
        .platform = platform,
        .architecture = architecture,
        .cpu = cpu,
        .logical_cpus = std.Thread.getCpuCount() catch null,
    };
}

fn utcStamp(allocator: Allocator, micros_since_epoch: i64, comptime iso: bool) ![]u8 {
    const micros: u64 = @intCast(@max(0, micros_since_epoch));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = micros / std.time.us_per_s };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, if (iso)
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}+00:00"
    else
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}.{d:0>6}Z", .{
        day.year,                   month.month.numeric(),     month.day_index + 1,
        time.getHoursIntoDay(),     time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
        micros % std.time.us_per_s,
    });
}

pub fn expandHome(allocator: Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = std.posix.getenv("HOME") orelse return error.HomeDirectoryUnavailable;
        return std.fs.path.join(allocator, &.{ home, path[@min(path.len, 2)..] });
    }
    return allocator.dupe(u8, path);
}

// Resolve existing ancestors so a result cannot enter the workspace through a symlink.
fn resolvePath(allocator: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse ".";
            if (std.mem.eql(u8, path, parent)) return err;
            const resolved = try resolvePath(allocator, parent);
            defer allocator.free(resolved);
            return std.fs.path.resolve(allocator, &.{ resolved, std.fs.path.basename(path) });
        },
        else => return err,
    };
}

fn isWithin(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/';
}

pub fn resultPath(allocator: Allocator, requested: ?[]const u8, prefix: []const u8, outside: ?[]const u8) ![]const u8 {
    const path = if (requested) |value| blk: {
        if (value.len == 0) return error.EmptyOutputPath;
        const expanded = try expandHome(allocator, value);
        defer allocator.free(expanded);
        break :blk try resolvePath(allocator, expanded);
    } else blk: {
        const checkout = std.posix.getenv("TOME_MEASUREMENT_ROOT") orelse ".";
        const preferred = try std.fs.path.join(allocator, &.{ checkout, "measurement/results" });
        defer allocator.free(preferred);
        const directory = try resolvePath(allocator, preferred);
        defer allocator.free(directory);
        const stamp = try utcStamp(allocator, std.time.microTimestamp(), false);
        defer allocator.free(stamp);
        const filename = try std.fmt.allocPrint(allocator, "{s}{s}.jsonl", .{ prefix, stamp });
        defer allocator.free(filename);
        if (outside) |root| {
            if (isWithin(directory, root)) {
                const fallback = try std.fs.path.join(allocator, &.{ tempRoot(), "tome-measurements", filename });
                defer allocator.free(fallback);
                break :blk try resolvePath(allocator, fallback);
            }
        }
        const candidate = try std.fs.path.join(allocator, &.{ directory, filename });
        defer allocator.free(candidate);
        break :blk try resolvePath(allocator, candidate);
    };
    errdefer allocator.free(path);
    if (outside) |root| {
        if (isWithin(path, root)) return error.ResultInsideWorkspace;
    }
    return path;
}

pub fn createResult(path: []const u8) !std.fs.File {
    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    return std.fs.cwd().createFile(path, .{ .exclusive = true });
}

fn tempRoot() []const u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |name| {
        if (std.posix.getenv(name)) |path| {
            if (path.len != 0) return path;
        }
    }
    return "/tmp";
}

pub const TempDir = struct {
    allocator: Allocator,
    path: []const u8,

    pub fn init(allocator: Allocator, prefix: []const u8) !TempDir {
        const parent = try std.fs.cwd().realpathAlloc(allocator, tempRoot());
        defer allocator.free(parent);
        while (true) {
            const suffix = std.crypto.random.int(u64);
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}{x:0>16}", .{ parent, prefix, suffix });
            errdefer allocator.free(path);
            std.posix.mkdir(path, 0o700) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return err,
            };
            return .{ .allocator = allocator, .path = path };
        }
    }

    pub fn deinit(self: TempDir) void {
        std.fs.deleteTreeAbsolute(self.path) catch |err|
            std.debug.print("Could not remove {s}: {s}\n", .{ self.path, @errorName(err) });
        self.allocator.free(self.path);
    }
};

var interrupted = std.atomic.Value(bool).init(false);

fn handleSignal(_: i32) callconv(.c) void {
    interrupted.store(true, .monotonic);
}

pub fn installInterruptHandler() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

pub fn checkInterrupted() error{Interrupted}!void {
    if (interrupted.load(.monotonic)) return error.Interrupted;
}

pub fn finish(output: *std.Io.Writer, failure: ?anyerror) !void {
    if (failure) |err| {
        try emit(output, .{ .type = "run_end", .status = "failed", .@"error" = @errorName(err) });
    } else {
        checkInterrupted() catch |err| {
            try emit(output, .{ .type = "run_end", .status = "failed", .@"error" = @errorName(err) });
            return err;
        };
        try emit(output, .{ .type = "run_end", .status = "complete" });
    }
}

pub fn median(sorted: []const u64) f64 {
    const middle = sorted.len / 2;
    const upper: f64 = @floatFromInt(sorted[middle]);
    if (sorted.len % 2 != 0) return upper;
    const lower: f64 = @floatFromInt(sorted[middle - 1]);
    return (lower + upper) / 2;
}

pub fn p95(sorted: []const u64) u64 {
    // ceil(0.95 * N) == N - floor(N / 20).
    return sorted[sorted.len - sorted.len / 20 - 1];
}

test "scroll results reject a symlink into the measured tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("workspace");
    try tmp.dir.symLink("workspace", "link", .{ .is_directory = true });
    const root = try tmp.dir.realpathAlloc(allocator, "workspace");
    defer allocator.free(root);
    const parent = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(parent);
    const inside = try std.fs.path.join(allocator, &.{ parent, "link", "new", "report.jsonl" });
    defer allocator.free(inside);
    try std.testing.expectError(error.ResultInsideWorkspace, resultPath(allocator, inside, "scroll-", root));

    const sibling = try std.fs.path.join(allocator, &.{ parent, "workspace-results", "report.jsonl" });
    defer allocator.free(sibling);
    const accepted = try resultPath(allocator, sibling, "scroll-", root);
    defer allocator.free(accepted);
    try std.testing.expectEqualStrings(sibling, accepted);
}

test "report timestamps retain UTC microsecond precision in metadata and filenames" {
    const allocator = std.testing.allocator;
    const micros = 1_709_164_800_000_005;
    const metadata = try utcStamp(allocator, micros, true);
    defer allocator.free(metadata);
    try std.testing.expectEqualStrings("2024-02-29T00:00:00.000005+00:00", metadata);
    const filename = try utcStamp(allocator, micros, false);
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("20240229T000000.000005Z", filename);
}
