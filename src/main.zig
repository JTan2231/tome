const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const Workspace = @import("content").Workspace;
const Editor = @import("editor.zig").Editor;

const usage =
    \\Usage: tome [file | directory]
    \\
    \\Browse the current or given directory, or start at a given file.
    \\Files load near the cursor; long workspaces scroll in a loop.
    \\
    \\  i       enter insert mode
    \\  a       append after the current character (within the line)
    \\  Escape  return to normal mode
    \\  hjkl    move in normal/visual mode (arrows work in any mode)
    \\  gg / G  first / last line; at that border, previous / next file
    \\  u / r   undo / redo the current file in normal mode
    \\  v / V   select characters / whole lines (Shift+V)
    \\  o       swap ends of a visual selection
    \\  y       yank selection; yy or Y yanks a line in normal mode
    \\  p / P   paste after / before (below / above for whole lines)
    \\  d / c   delete / change selection; dd / cc operate on a line
    \\  x       delete a character or selection
    \\  D / C   delete / change through end of line
    \\  y/d/c + hjkl, 0, $, gg, G, arrows, Home, End operate on a motion
    \\  /text   search forward (literal, case-sensitive; Enter starts)
    \\  n       next match; Escape cancels a pending search
    \\  Space f filter workspace files and jump to the selected file
    \\  Space g search workspace text and jump to the selected match
    \\  :w      write all changed files
    \\  :wt     write the file under the cursor
    \\  :q      quit (refuses unsaved changes)
    \\  :q!     quit and discard changes
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("tome: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux and builtin.os.tag != .windows) {
        @compileError("tome currently supports macOS, Linux, and Windows terminals");
    }
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try std.fs.File.stdout().writeAll(usage);
        return;
    }
    if (args.len > 2) {
        std.debug.print("{s}", .{usage});
        return error.ExpectedAtMostOnePath;
    }

    var file_arg: ?[]const u8 = null;
    if (args.len == 2) {
        // Let the OS resolve directory paths, including symlinks before `..`.
        std.posix.chdirZ(args[1]) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => file_arg = args[1],
            else => return err,
        };
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const initial_file = if (file_arg) |path| try absoluteFilePath(allocator, cwd, path) else null;
    defer if (initial_file) |path| allocator.free(path);
    var root: []const u8 = cwd;
    if (initial_file) |path| {
        const relative = try std.fs.path.relative(allocator, cwd, path);
        defer allocator.free(relative);
        if (std.fs.path.isAbsolute(relative) or std.mem.eql(u8, relative, "..") or
            std.mem.startsWith(u8, relative, ".." ++ std.fs.path.sep_str))
        {
            root = std.fs.path.dirname(path) orelse cwd;
        }
    }
    var workspace = try Workspace.open(allocator, root, initial_file);
    defer workspace.deinit();
    // An explicitly requested file should report open errors, not silently skip.
    if (initial_file != null) _ = try workspace.ensure(workspace.initial_index);
    var editor = try Editor.initWorkspace(allocator, &workspace);
    defer editor.deinit();
    var tty = try terminal.Terminal.init();
    defer tty.deinit();
    // These defers also run after I/O failures and handled termination signals.
    defer tty.writeAll("\x1b[?2026l\x1b[?2004l\x1b[0 q\x1b[?25h\x1b[0m\x1b[?1049l") catch {};
    try tty.writeAll("\x1b[?1049h\x1b[?2004h");
    try editor.run(&tty);
}

fn absoluteFilePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return std.fs.path.resolve(allocator, &.{ cwd, path });

    // Let Windows apply the current directory of the path's drive, even for a new file.
    const windows = std.os.windows;
    const wide_path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    defer allocator.free(wide_path);
    var full: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = windows.kernel32.GetFullPathNameW(wide_path.ptr, full.len, &full, null);
    if (len == 0) return windows.unexpectedError(windows.GetLastError());
    if (len >= full.len) return error.NameTooLong;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, full[0..len]);
}

test {
    _ = @import("terminal.zig");
    _ = @import("display.zig");
    _ = @import("editor.zig");
    _ = @import("stream.zig");
}
