const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage.zig");
const Loader = @import("loader.zig").Job;

pub const cache_file_limit = 8;
pub const cache_byte_limit = 8 * 1024 * 1024;

pub const Entry = struct {
    name: []u8,
    path: []u8,
    document: ?*storage.Document = null,
    // Retained after eviction so viewport probing need not reload distant files.
    // A successful ensure refreshes it after loading or editing the document.
    line_count: ?usize = null,
    dirty: bool = false,
    load_error: ?anyerror = null,
    last_used: u64 = 0,
    allow_new: bool = false,
    // Changes to contents or residency invalidate borrowed search positions.
    revision: u64 = 0,
};

pub const SaveAllResult = struct {
    saved: usize = 0,
    failed: usize = 0,
    first_error: ?anyerror = null,
    first_failed: ?usize = null,
};

/// Discovery records paths, never file contents. Only nearby documents are read.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    entries: std.ArrayList(Entry) = .empty,
    // Keep redraw-time eviction proportional to resident buffers, not the tree.
    resident: std.ArrayList(usize) = .empty,
    initial_index: usize = 0,
    active_index: ?usize = null,
    clock: u64 = 0,
    requested: ?*Loader = null,
    next_requested: ?usize = null,
    // Protect the actual viewport, even when it spans more than eight files.
    // Search scans do not call request() and never enter this list.
    viewport: std.ArrayList(usize) = .empty,
    collecting_viewport: bool = false,

    pub fn open(allocator: std.mem.Allocator, root_path: []const u8, initial_path: ?[]const u8) !Workspace {
        var self: Workspace = .{
            .allocator = allocator,
            .root = try std.fs.cwd().realpathAlloc(allocator, root_path),
        };
        errdefer self.deinit();
        var dir = try std.fs.cwd().openDir(self.root, .{ .iterate = true });
        defer dir.close();
        try self.discover(dir, "");

        if (initial_path) |path| {
            const cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd);
            const absolute = std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
                error.FileNotFound => try std.fs.path.resolve(allocator, &.{ cwd, path }),
                else => return err,
            };
            defer allocator.free(absolute);
            var found = false;
            for (self.entries.items) |*entry| {
                if (std.mem.eql(u8, absolute, entry.path)) {
                    entry.allow_new = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                const name = try std.fs.path.relative(allocator, self.root, absolute);
                defer allocator.free(name);
                try self.append(name, absolute);
                self.entries.items[self.entries.items.len - 1].allow_new = true;
            }
            std.mem.sort(Entry, self.entries.items, {}, entryLessThan);
            for (self.entries.items, 0..) |entry, index| {
                if (std.mem.eql(u8, absolute, entry.path)) {
                    self.initial_index = index;
                    break;
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        if (self.requested) |job| job.deinit();
        while (self.resident.items.len != 0) self.unload(self.resident.items[self.resident.items.len - 1]);
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.resident.deinit(self.allocator);
        self.viewport.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.root);
    }

    const Child = struct { name: []u8, directory: bool };

    fn discover(self: *Workspace, dir: std.fs.Dir, prefix: []const u8) anyerror!void {
        var children: std.ArrayList(Child) = .empty;
        defer {
            for (children.items) |child| self.allocator.free(child.name);
            children.deinit(self.allocator);
        }
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            // Following directory links can escape the workspace or create cycles.
            if (entry.kind != .file and entry.kind != .directory) continue;
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            try children.append(self.allocator, .{ .name = name, .directory = entry.kind == .directory });
        }
        std.mem.sort(Child, children.items, {}, struct {
            fn lessThan(_: void, a: Child, b: Child) bool {
                if (a.directory != b.directory) return a.directory;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        for (children.items) |child| {
            const relative = try std.fs.path.join(self.allocator, &.{ prefix, child.name });
            defer self.allocator.free(relative);
            if (child.directory) {
                var nested = dir.openDir(child.name, .{ .iterate = true, .no_follow = true }) catch continue;
                defer nested.close();
                self.discover(nested, relative) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
            } else {
                const absolute = try std.fs.path.join(self.allocator, &.{ self.root, relative });
                defer self.allocator.free(absolute);
                try self.append(relative, absolute);
            }
        }
    }

    fn append(self: *Workspace, name: []const u8, path: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.entries.append(self.allocator, .{ .name = owned_name, .path = owned_path });
    }

    /// Request one complete file's renderable content. Includes loading, newline
    /// preparation, line counting, and cache trimming; excludes viewport layout
    /// and rendering. The document is borrowed until eviction or deinit. Set
    /// active_index to protect a document across requests for other files.
    pub fn ensure(self: *Workspace, index: usize) !*storage.Document {
        const entry = &self.entries.items[index];
        if (entry.load_error) |err| return err;
        if (entry.document == null) {
            if (!entry.allow_new) {
                std.fs.cwd().access(entry.path, .{}) catch |err| {
                    entry.load_error = err;
                    return err;
                };
            }
            try self.resident.ensureUnusedCapacity(self.allocator, 1);
            const document = try self.allocator.create(storage.Document);
            errdefer self.allocator.destroy(document);
            document.* = storage.Document.open(self.allocator, entry.path) catch |err| {
                if (err != error.OutOfMemory) entry.load_error = err;
                return err;
            };
            if (!entry.allow_new and document.is_new) {
                // A discovered file can disappear between access and open.
                document.deinit();
                entry.load_error = error.FileNotFound;
                return error.FileNotFound;
            }
            entry.document = document;
            entry.revision +%= 1;
            // An evicted file may have changed on disk since its previous load.
            entry.line_count = null;
            self.resident.appendAssumeCapacity(index);
        }
        if (entry.line_count == null) {
            entry.line_count = entry.document.?.buffer.line_count;
        }
        self.clock +%= 1;
        entry.last_used = self.clock;
        self.trim(index);
        return entry.document.?;
    }

    /// Admit a document already prepared off the UI thread. Ownership transfers
    /// only on success; callers must validate their search/load revision first.
    pub fn adopt(self: *Workspace, index: usize, prepared: storage.Document, line_count: usize) !*storage.Document {
        const entry = &self.entries.items[index];
        if (entry.document != null) return error.DocumentAlreadyResident;
        try self.resident.ensureUnusedCapacity(self.allocator, 1);
        const document = try self.allocator.create(storage.Document);
        document.* = prepared;
        entry.document = document;
        entry.line_count = line_count;
        entry.load_error = null;
        entry.revision +%= 1;
        self.resident.appendAssumeCapacity(index);
        self.clock +%= 1;
        entry.last_used = self.clock;
        self.trim(index);
        return document;
    }

    /// Begin/end surround a frame, not a search. Deferring trim until the end
    /// prevents a frame with many small files from evicting its own first rows.
    pub fn beginFrame(self: *Workspace) void {
        self.viewport.clearRetainingCapacity();
        self.collecting_viewport = true;
    }

    pub fn endFrame(self: *Workspace) void {
        self.collecting_viewport = false;
        self.trim(self.active_index orelse 0);
    }

    /// Nonblocking readiness request used by interactive viewport traversal.
    /// Resident hits do not recount a potentially large edited buffer.
    pub fn request(self: *Workspace, index: usize) !?*storage.Document {
        const entry = &self.entries.items[index];
        if (self.collecting_viewport and std.mem.indexOfScalar(usize, self.viewport.items, index) == null)
            try self.viewport.append(self.allocator, index);
        if (entry.load_error) |err| return err;
        if (entry.document) |document| {
            self.clock +%= 1;
            entry.last_used = self.clock;
            return document;
        }
        if (self.requested) |job| {
            // Keep one latest request, rather than an unbounded queue of rows
            // that may cease to be visible before preparation completes.
            self.next_requested = if (job.index == index and !job.cancelled.load(.acquire)) null else index;
        } else {
            self.requested = try Loader.start(self.allocator, entry.path, index, entry.revision, entry.allow_new);
        }
        return null;
    }

    pub fn hasPendingRequest(self: *const Workspace) bool {
        return self.requested != null or self.next_requested != null;
    }

    /// Superseded work is discarded when it finishes; cancellation never joins
    /// a running worker on the input/rendering thread.
    pub fn cancelRequested(self: *Workspace) void {
        if (self.requested) |job| job.cancel();
        self.next_requested = null;
    }

    /// Publish completed preparation, then start the latest waiting request.
    /// Returns whether a readiness/failure change calls for another frame.
    pub fn pollRequested(self: *Workspace) !bool {
        const job = self.requested orelse return false;
        if (!job.isDone()) return false;
        self.requested = null;
        defer job.deinit();
        const entry = &self.entries.items[job.index];
        var changed = false;
        if (!job.cancelled.load(.acquire) and entry.revision == job.revision and entry.document == null) {
            if (job.document) |document| {
                _ = try self.adopt(job.index, document, job.line_count);
                job.document = null;
                changed = true;
            } else if (job.failure) |err| {
                if (err == error.OutOfMemory) return err;
                entry.load_error = err;
                changed = true;
            }
        }
        const next = self.next_requested;
        self.next_requested = null;
        if (next) |index| {
            // It may already have been admitted by a search destination.
            _ = self.request(index) catch |err| {
                if (err == error.OutOfMemory) return err;
                return true;
            };
        }
        return changed;
    }

    fn unload(self: *Workspace, index: usize) void {
        const entry = &self.entries.items[index];
        if (entry.document) |document| {
            document.deinit();
            self.allocator.destroy(document);
            entry.document = null;
            entry.revision +%= 1;
            const position = std.mem.indexOfScalar(usize, self.resident.items, index).?;
            _ = self.resident.swapRemove(position);
        }
    }

    /// Dirty buffers, undo histories, and active/requested documents are retained.
    /// A single large active file can therefore exceed the clean-cache budget.
    fn trim(self: *Workspace, requested: usize) void {
        while (true) {
            var count: usize = 0;
            var bytes: usize = 0;
            var oldest: ?usize = null;
            for (self.resident.items) |index| {
                const entry = self.entries.items[index];
                const document = entry.document.?;
                if (entry.dirty or document.is_new or document.history.items.items.len != 0) continue;
                count += 1;
                bytes += document.buffer.bytes.capacity;
                if (index == requested or self.active_index == index or
                    std.mem.indexOfScalar(usize, self.viewport.items, index) != null) continue;
                if (oldest == null or entry.last_used < self.entries.items[oldest.?].last_used) oldest = index;
            }
            if (count <= cache_file_limit and bytes <= cache_byte_limit) return;
            self.unload(oldest orelse return);
        }
    }

    pub fn markDirty(self: *Workspace, index: usize) void {
        std.debug.assert(self.entries.items[index].document != null);
        self.entries.items[index].dirty = true;
        self.entries.items[index].line_count = null;
        self.entries.items[index].revision +%= 1;
    }

    pub fn hasChanges(self: *const Workspace) bool {
        for (self.entries.items) |entry| if (entry.dirty) return true;
        return false;
    }

    pub fn save(self: *Workspace, index: usize) !void {
        const document = try self.ensure(index);
        try document.save();
        self.entries.items[index].dirty = false;
        self.entries.items[index].allow_new = false;
        self.trim(index);
    }

    pub fn saveAll(self: *Workspace) SaveAllResult {
        var result: SaveAllResult = .{};
        for (self.entries.items, 0..) |entry, index| {
            const document = entry.document orelse continue;
            if (!entry.dirty and !document.is_new) continue;
            self.save(index) catch |err| {
                result.failed += 1;
                if (result.first_error == null) {
                    result.first_error = err;
                    result.first_failed = index;
                }
                continue;
            };
            result.saved += 1;
        }
        return result;
    }
};

// Compare each path component with directories ahead of files, matching DFS.
fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    var left = a.name;
    var right = b.name;
    while (true) {
        const a_slash = std.mem.indexOfScalar(u8, left, std.fs.path.sep);
        const b_slash = std.mem.indexOfScalar(u8, right, std.fs.path.sep);
        const a_part = left[0 .. a_slash orelse left.len];
        const b_part = right[0 .. b_slash orelse right.len];
        if (!std.mem.eql(u8, a_part, b_part)) {
            if ((a_slash != null) != (b_slash != null)) return a_slash != null;
            return std.mem.lessThan(u8, a_part, b_part);
        }
        if (a_slash == null or b_slash == null) return a_slash != null and b_slash == null;
        left = left[a_slash.? + 1 ..];
        right = right[b_slash.? + 1 ..];
    }
}

fn finishRequested(workspace: *Workspace) !void {
    for (0..5000) |_| {
        _ = try workspace.pollRequested();
        if (!workspace.hasPendingRequest()) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.LoaderDidNotFinish;
}

test "asynchronous requests prepare content without admitting until polled" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one\r\ntwo\r\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();

    try std.testing.expect(try workspace.request(0) == null);
    try std.testing.expect(workspace.hasPendingRequest());
    try std.testing.expect(workspace.entries.items[0].document == null);
    try std.testing.expectEqual(@as(u64, 0), workspace.entries.items[0].revision);
    try finishRequested(&workspace);
    const entry = &workspace.entries.items[0];
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", entry.document.?.buffer.bytes.items);
    try std.testing.expectEqualStrings("\r\n", entry.document.?.buffer.newline);
    try std.testing.expectEqual(@as(?usize, 3), entry.line_count);
    const revision = entry.revision;
    try std.testing.expectEqual(entry.document, try workspace.request(0));
    try std.testing.expectEqual(revision, entry.revision);

    try entry.document.?.buffer.insert(entry.document.?.allocator, "new\n");
    workspace.markDirty(0);
    try std.testing.expect(entry.revision != revision);
    try std.testing.expect(entry.line_count == null);
    _ = try workspace.request(0);
    try std.testing.expect(entry.line_count == null); // no synchronous recount
}

test "obsolete loader completion cannot replace a resident edited document" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "original" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    _ = try workspace.request(0);
    const document = try workspace.ensure(0);
    try document.buffer.insert(std.testing.allocator, "edited ");
    workspace.markDirty(0);
    const revision = workspace.entries.items[0].revision;
    try finishRequested(&workspace);
    try std.testing.expectEqual(document, workspace.entries.items[0].document.?);
    try std.testing.expectEqualStrings("edited original", document.buffer.bytes.items);
    try std.testing.expectEqual(revision, workspace.entries.items[0].revision);
}

test "cancelled loading is discarded and only the latest waiting request starts" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "a", "b", "c" }) |name|
        try temp.dir.writeFile(.{ .sub_path = name, .data = name });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    _ = try workspace.request(0);
    workspace.cancelRequested();
    _ = try workspace.request(1);
    _ = try workspace.request(2);
    try finishRequested(&workspace);
    try std.testing.expect(workspace.entries.items[0].document == null);
    try std.testing.expect(workspace.entries.items[1].document == null);
    try std.testing.expectEqualStrings("c", workspace.entries.items[2].document.?.buffer.bytes.items);
}

test "asynchronous viewport larger than cache finishes without eviction cycling" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file_count = cache_file_limit + 4;
    for (0..file_count) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file{d:0>2}", .{index});
        try temp.dir.writeFile(.{ .sub_path = name, .data = "x" });
    }
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    workspace.active_index = 0;
    var complete = false;
    for (0..file_count + 1) |_| {
        workspace.beginFrame();
        var ready: usize = 0;
        for (0..file_count) |index| {
            if (try workspace.request(index) == null) break;
            ready += 1;
        }
        workspace.endFrame();
        if (ready == file_count) {
            complete = true;
            break;
        }
        try finishRequested(&workspace);
    }
    try std.testing.expect(complete);
    try std.testing.expectEqual(file_count, workspace.resident.items.len);
    workspace.beginFrame();
    _ = try workspace.request(0);
    workspace.endFrame();
    try std.testing.expect(workspace.resident.items.len <= cache_file_limit);
    try std.testing.expect(workspace.entries.items[0].document != null);
    var evicted = false;
    for (workspace.entries.items[1..]) |entry| {
        if (entry.document == null) {
            evicted = true;
            try std.testing.expect(entry.revision >= 2);
        }
    }
    try std.testing.expect(evicted);
}

test "catalog orders containers first recursively without reading file contents" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("z/deep");
    try temp.dir.makePath("a");
    try temp.dir.makePath(".git");
    for ([_][]const u8{ "z/deep/x", "z/a", "a/z", "a/a", "a.txt", ".hidden", ".git/ignored" }) |path|
        try temp.dir.writeFile(.{ .sub_path = path, .data = "content" });
    temp.dir.symLink(".", "loop", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => if (builtin.os.tag != .windows) return err,
        else => return err,
    };
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    const expected = [_][]const u8{ "a/a", "a/z", "z/deep/x", "z/a", ".hidden", "a.txt" };
    try std.testing.expectEqual(expected.len, workspace.entries.items.len);
    for (workspace.entries.items, expected) |entry, name| {
        const native_name = try std.testing.allocator.dupe(u8, name);
        defer std.testing.allocator.free(native_name);
        std.mem.replaceScalar(u8, native_name, '/', std.fs.path.sep);
        try std.testing.expectEqualStrings(native_name, entry.name);
        try std.testing.expect(entry.document == null);
        try std.testing.expect(entry.line_count == null);
    }
}

test "request prepares newline style and line count before returning" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one\r\ntwo\r\n" });
    try temp.dir.writeFile(.{ .sub_path = "empty", .data = "" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();

    const document = try workspace.ensure(0);
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", document.buffer.bytes.items);
    try std.testing.expectEqualStrings("\r\n", document.buffer.newline);
    try std.testing.expectEqual(@as(?usize, 3), workspace.entries.items[0].line_count);
    try std.testing.expectEqual(document, try workspace.ensure(0));
    _ = try workspace.ensure(1);
    try std.testing.expectEqual(@as(?usize, 1), workspace.entries.items[1].line_count);
}

test "editing invalidates preparation and a resident request refreshes it" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "one" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();

    const document = try workspace.ensure(0);
    try std.testing.expectEqual(@as(?usize, 1), workspace.entries.items[0].line_count);
    try document.buffer.insert(std.testing.allocator, "two\nthree\n");
    workspace.markDirty(0);
    try std.testing.expect(workspace.entries.items[0].line_count == null);
    try std.testing.expectEqual(document, try workspace.ensure(0));
    try std.testing.expectEqual(@as(?usize, 3), workspace.entries.items[0].line_count);
}

test "eviction retains line counts and reloading refreshes changed contents" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..cache_file_limit + 1) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file{d:0>2}", .{index});
        try temp.dir.writeFile(.{ .sub_path = name, .data = "one\n" });
    }
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    for (0..workspace.entries.items.len) |index| _ = try workspace.ensure(index);
    try std.testing.expect(workspace.entries.items[0].document == null);
    try std.testing.expectEqual(@as(?usize, 2), workspace.entries.items[0].line_count);

    try temp.dir.writeFile(.{ .sub_path = "file00", .data = "one\ntwo\nthree" });
    const document = try workspace.ensure(0);
    try std.testing.expectEqualStrings("one\ntwo\nthree", document.buffer.bytes.items);
    try std.testing.expectEqual(@as(?usize, 3), workspace.entries.items[0].line_count);
}

test "clean cache is bounded and dirty documents survive eviction" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..20) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file{d:0>2}", .{index});
        try temp.dir.writeFile(.{ .sub_path = name, .data = "content" });
    }
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    const first = try workspace.ensure(0);
    try first.buffer.insert(std.testing.allocator, "edited ");
    workspace.markDirty(0);
    workspace.active_index = 1;
    _ = try workspace.ensure(1);
    for (2..20) |index| _ = try workspace.ensure(index);
    try std.testing.expectEqualStrings("edited content", workspace.entries.items[0].document.?.buffer.bytes.items);
    try std.testing.expect(workspace.entries.items[1].document != null);
    try std.testing.expect(workspace.entries.items[2].document == null);
    var clean: usize = 0;
    for (workspace.entries.items) |entry| if (entry.document != null and !entry.dirty) {
        clean += 1;
    };
    try std.testing.expect(clean <= cache_file_limit);
    try std.testing.expectEqual(clean + 1, workspace.resident.items.len);
    for (workspace.resident.items, 0..) |index, position| {
        try std.testing.expect(workspace.entries.items[index].document != null);
        try std.testing.expect(std.mem.indexOfScalar(usize, workspace.resident.items[0..position], index) == null);
    }
    try std.testing.expect(workspace.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), workspace.saveAll().saved);
    try std.testing.expect(!workspace.hasChanges());
    try std.testing.expect(workspace.resident.items.len <= cache_file_limit);
    // Reloading an evicted file must not accumulate stale resident entries.
    _ = try workspace.ensure(2);
    try std.testing.expect(workspace.resident.items.len <= cache_file_limit);
}

test "saved documents retain undo history under cache pressure" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for (0..20) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "file{d:0>2}", .{index});
        try temp.dir.writeFile(.{ .sub_path = name, .data = "content" });
    }
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var workspace = try Workspace.open(allocator, root, null);
    defer workspace.deinit();
    const first = try workspace.ensure(0);
    try first.history.beginChange(allocator, &first.buffer);
    try first.buffer.insert(allocator, "edited ");
    workspace.markDirty(0);
    try workspace.save(0);
    try std.testing.expect(!first.history.isDirty());
    for (1..20) |index| _ = try workspace.ensure(index);
    try std.testing.expectEqual(first, workspace.entries.items[0].document.?);
    try std.testing.expect(workspace.entries.items[1].document == null);
    try std.testing.expect(first.history.undo(&first.buffer));
    try std.testing.expectEqualStrings("content", first.buffer.bytes.items);
    try std.testing.expect(first.history.isDirty());
    try std.testing.expect(first.history.redo(&first.buffer));
    try std.testing.expectEqualStrings("edited content", first.buffer.bytes.items);
    try std.testing.expect(!first.history.isDirty());
}

test "save all preserves failed edits and still writes other changed files" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "a" });
    try temp.dir.writeFile(.{ .sub_path = "b", .data = "b" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    for (0..2) |index| {
        const document = try workspace.ensure(index);
        try document.buffer.insert(std.testing.allocator, "edited ");
        workspace.markDirty(index);
    }
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "outside change" });
    const result = workspace.saveAll();
    try std.testing.expectEqual(@as(usize, 1), result.saved);
    try std.testing.expectEqual(@as(usize, 1), result.failed);
    try std.testing.expectEqual(error.FileChangedOnDisk, result.first_error.?);
    try std.testing.expectEqual(@as(usize, 0), result.first_failed.?);
    try std.testing.expect(workspace.entries.items[0].dirty);
    try std.testing.expect(!workspace.entries.items[1].dirty);
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "b", 100);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("edited b", bytes);
}

test "explicit missing file starts at its sorted position and saves on write all" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "a" });
    try temp.dir.writeFile(.{ .sub_path = "z", .data = "z" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const initial = try std.fs.path.join(std.testing.allocator, &.{ root, "new" });
    defer std.testing.allocator.free(initial);
    var workspace = try Workspace.open(std.testing.allocator, root, initial);
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 1), workspace.initial_index);
    try std.testing.expect((try workspace.ensure(workspace.initial_index)).is_new);
    const result = workspace.saveAll();
    try std.testing.expectEqual(@as(usize, 1), result.saved);
    try std.testing.expectEqual(@as(u64, 0), (try temp.dir.statFile("new")).size);
}

test "explicit nested missing file keeps directories ahead of root files" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makeDir("z");
    try temp.dir.writeFile(.{ .sub_path = "a.txt", .data = "root file" });
    try temp.dir.writeFile(.{ .sub_path = "z/z.txt", .data = "nested file" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const initial = try std.fs.path.join(std.testing.allocator, &.{ root, "z", "a.txt" });
    defer std.testing.allocator.free(initial);
    var workspace = try Workspace.open(std.testing.allocator, root, initial);
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 3), workspace.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.initial_index);
    try std.testing.expectEqualStrings(initial, workspace.entries.items[0].path);
    try std.testing.expectEqualStrings("a.txt", workspace.entries.items[2].name);
}

test "byte budget evicts clean buffers before the file-count limit" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "a", "b", "c" }) |name| {
        const file = try temp.dir.createFile(name, .{});
        defer file.close();
        try file.setEndPos(cache_byte_limit / 2);
    }
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    _ = try workspace.ensure(0);
    _ = try workspace.ensure(1);
    _ = try workspace.ensure(2);
    try std.testing.expect(workspace.entries.items[0].document == null);
    var bytes: usize = 0;
    for (workspace.entries.items) |entry| {
        if (entry.document) |document| bytes += document.buffer.bytes.capacity;
    }
    try std.testing.expect(bytes <= cache_byte_limit);
}

test "unavailable and oversized discovered files fail lazily" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "a" });
    const large = try temp.dir.createFile("b", .{});
    try large.setEndPos(storage.max_file_size + 1);
    large.close();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var workspace = try Workspace.open(std.testing.allocator, root, null);
    defer workspace.deinit();
    try temp.dir.deleteFile("a");
    try std.testing.expectError(error.FileNotFound, workspace.ensure(0));
    try std.testing.expectError(error.FileTooBig, workspace.ensure(1));
    try std.testing.expectEqual(error.FileNotFound, workspace.entries.items[0].load_error.?);
    try std.testing.expectEqual(error.FileTooBig, workspace.entries.items[1].load_error.?);
    try std.testing.expectEqual(@as(usize, 0), workspace.saveAll().saved);
}

test "empty directory stays empty and explicit symlink reuses its target" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var empty = try Workspace.open(std.testing.allocator, root, null);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.items.len);
    try std.testing.expect(!empty.hasChanges());
    try temp.dir.writeFile(.{ .sub_path = "target", .data = "contents" });
    temp.dir.symLink("target", "link", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "link" });
    defer std.testing.allocator.free(link);
    var workspace = try Workspace.open(std.testing.allocator, root, link);
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 1), workspace.entries.items.len);
    try std.testing.expectEqualStrings("target", workspace.entries.items[0].name);
    try std.testing.expectEqualStrings("contents", (try workspace.ensure(0)).buffer.bytes.items);
}

test "catalog and resident buffers clean up after allocation failures" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "a", .data = "contents" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn exercise(allocator: std.mem.Allocator, path: []const u8) !void {
            var workspace = try Workspace.open(allocator, path, null);
            defer workspace.deinit();
            _ = try workspace.ensure(0);
        }
    }.exercise, .{root});
}
