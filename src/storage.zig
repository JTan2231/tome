const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

/// A simple in-memory editor deliberately limits the amount read at once.
pub const max_file_size = 64 * 1024 * 1024;

pub const Document = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    buffer: Buffer,
    is_new: bool,
    saved_stat: ?std.fs.File.Stat,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Document {
        if (path.len == 0) return error.EmptyPath;
        const cwd = std.fs.cwd();
        const resolved = cwd.realpathAlloc(allocator, path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // Do not replace a dangling symlink with a fresh regular file.
                var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                if (cwd.readLink(path, &link_buffer)) |_| {
                    return error.DanglingSymlink;
                } else |link_err| switch (link_err) {
                    error.FileNotFound, error.NotLink => {},
                    else => return link_err,
                }
                const parent = try cwd.realpathAlloc(allocator, std.fs.path.dirname(path) orelse ".");
                defer allocator.free(parent);
                break :blk try std.fs.path.join(allocator, &.{ parent, std.fs.path.basename(path) });
            },
            else => return err,
        };
        errdefer allocator.free(resolved);

        const initial_stat = try statOrMissing(resolved);
        if (initial_stat) |stat| {
            if (stat.kind != .file) return error.NotRegularFile;
            if (stat.size > max_file_size) return error.FileTooBig;
            const file = try cwd.openFile(resolved, .{});
            defer file.close();
            const before = try file.stat();
            if (before.kind != .file) return error.NotRegularFile;
            const bytes = try file.readToEndAlloc(allocator, max_file_size);
            errdefer allocator.free(bytes);
            const after = try file.stat();
            if (!sameVersion(before, after)) return error.FileChangedOnDisk;
            return .{
                .allocator = allocator,
                .path = resolved,
                .buffer = Buffer.init(.fromOwnedSlice(bytes)),
                .is_new = false,
                .saved_stat = after,
            };
        }
        return .{
            .allocator = allocator,
            .path = resolved,
            .buffer = Buffer.init(.empty),
            .is_new = true,
            .saved_stat = null,
        };
    }

    pub fn deinit(self: *Document) void {
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn save(self: *Document) !void {
        try self.checkUnchanged();
        if (self.saved_stat != null) {
            // Replacing a file only needs directory permission. Respect the
            // file's own write permission as users expect from an editor.
            const writable = try std.fs.cwd().openFile(self.path, .{ .mode = .read_write });
            writable.close();
        }

        var atomic = try std.fs.cwd().atomicFile(self.path, .{
            .mode = if (self.saved_stat) |stat| stat.mode & 0o777 else std.fs.File.default_mode,
            .write_buffer = &.{},
        });
        defer atomic.deinit();
        const file = atomic.file_writer.file;
        try file.writeAll(self.buffer.bytes.items);
        // chmod after creation avoids the umask stripping existing permission bits.
        if (self.saved_stat) |stat| try file.chmod(stat.mode & 0o777);
        try file.sync();
        try self.checkUnchanged();
        try atomic.finish();
        self.saved_stat = try statOrMissing(self.path);
        self.is_new = false;
    }

    fn checkUnchanged(self: *const Document) !void {
        const current = try statOrMissing(self.path);
        if (self.saved_stat) |saved| {
            const now = current orelse return error.FileChangedOnDisk;
            if (now.kind != .file or !sameVersion(saved, now)) return error.FileChangedOnDisk;
        } else if (current != null) {
            return error.FileChangedOnDisk;
        }
    }
};

fn statOrMissing(path: []const u8) !?std.fs.File.Stat {
    // The stored path was resolved on open. Refuse a new symlink introduced
    // afterwards rather than replacing that link on save.
    const stat = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return std.fs.File.Stat.fromPosix(stat);
}

fn sameVersion(a: std.fs.File.Stat, b: std.fs.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime and a.ctime == b.ctime;
}

fn tempPath(allocator: std.mem.Allocator, dir: std.fs.Dir, basename: []const u8) ![]u8 {
    const path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    return std.fs.path.join(allocator, &.{ path, basename });
}

test "new file saves exact bytes and can be saved again" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try tempPath(std.testing.allocator, temp.dir, "new.txt");
    defer std.testing.allocator.free(path);
    var doc = try Document.open(std.testing.allocator, path);
    defer doc.deinit();
    try std.testing.expect(doc.is_new);
    try doc.buffer.insert(std.testing.allocator, "hello\r\nworld\x00\xff");
    try doc.save();
    try std.testing.expect(!doc.is_new);
    try doc.buffer.insert(std.testing.allocator, "!");
    try doc.save();
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "new.txt", 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "hello\r\nworld\x00\xff!", bytes);
}

test "external changes are not overwritten" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "existing", .data = "first" });
    const path = try tempPath(std.testing.allocator, temp.dir, "existing");
    defer std.testing.allocator.free(path);
    var doc = try Document.open(std.testing.allocator, path);
    defer doc.deinit();
    try doc.buffer.insert(std.testing.allocator, "edited");
    try temp.dir.writeFile(.{ .sub_path = "existing", .data = "external content" });
    try std.testing.expectError(error.FileChangedOnDisk, doc.save());
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "existing", 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("external content", bytes);
}

test "file created after opening an absent path is not overwritten" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try tempPath(std.testing.allocator, temp.dir, "new");
    defer std.testing.allocator.free(path);
    var doc = try Document.open(std.testing.allocator, path);
    defer doc.deinit();
    try temp.dir.writeFile(.{ .sub_path = "new", .data = "another writer" });
    try std.testing.expectError(error.FileChangedOnDisk, doc.save());
}

test "save follows existing symlink and retains target permission bits" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const target = try temp.dir.createFile("target", .{ .mode = 0o640 });
    try target.writeAll("original\r\n");
    try target.chmod(0o640);
    target.close();
    try temp.dir.symLink("target", "link", .{});
    const path = try tempPath(std.testing.allocator, temp.dir, "link");
    defer std.testing.allocator.free(path);
    var doc = try Document.open(std.testing.allocator, path);
    defer doc.deinit();
    try std.testing.expectEqualStrings("\r\n", doc.buffer.newline);
    try doc.buffer.insert(std.testing.allocator, "new ");
    try doc.save();
    var link_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("target", try temp.dir.readLink("link", &link_buffer));
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "target", 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new original\r\n", bytes);
    const stat = try temp.dir.statFile("target");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o640), stat.mode & 0o777);
}

test "nonregular files and dangling symlinks are rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try tempPath(std.testing.allocator, temp.dir, ".");
    defer std.testing.allocator.free(directory);
    try std.testing.expectError(error.NotRegularFile, Document.open(std.testing.allocator, directory));
    try temp.dir.symLink("absent", "dangling", .{});
    const link = try tempPath(std.testing.allocator, temp.dir, "dangling");
    defer std.testing.allocator.free(link);
    try std.testing.expectError(error.DanglingSymlink, Document.open(std.testing.allocator, link));
}
