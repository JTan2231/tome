const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub fn openReadNoFollow(dir: std.fs.Dir, path: []const u8) !std.fs.File {
    if (builtin.os.tag == .windows) return openWindowsNoFollow(dir, path, windows.GENERIC_READ);
    return .{ .handle = try std.posix.openat(dir.fd, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NONBLOCK = true,
        .NOFOLLOW = true,
    }, 0) };
}

pub fn statNoFollow(path: []const u8) !std.fs.File.Stat {
    const dir = std.fs.cwd();
    if (builtin.os.tag == .windows) {
        const file = try openWindowsNoFollow(dir, path, windows.FILE_READ_ATTRIBUTES);
        defer file.close();
        return file.stat();
    }
    return .fromPosix(try std.posix.fstatat(dir.fd, path, std.posix.AT.SYMLINK_NOFOLLOW));
}

extern "kernel32" fn GetFileType(handle: windows.HANDLE) callconv(.winapi) windows.DWORD;
const file_type_disk = 1;

fn openWindowsNoFollow(dir: std.fs.Dir, path: []const u8, access: windows.ACCESS_MASK) !std.fs.File {
    const wide_path = try windows.sliceToPrefixedFileW(dir.fd, path);
    const wide = wide_path.span();
    const byte_len = std.math.cast(u16, wide.len * 2) orelse return error.NameTooLong;
    var name: windows.UNICODE_STRING = .{
        .Length = byte_len,
        .MaximumLength = byte_len,
        .Buffer = @constCast(wide.ptr),
    };
    var attributes: windows.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWTF16(wide)) null else dir.fd,
        .Attributes = 0,
        .ObjectName = &name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var handle: windows.HANDLE = undefined;
    var status: windows.IO_STATUS_BLOCK = undefined;
    // Use synchronous I/O so the caller can stat and read this same handle.
    switch (windows.ntdll.NtCreateFile(
        &handle,
        access | windows.SYNCHRONIZE,
        &attributes,
        &status,
        null,
        windows.FILE_ATTRIBUTE_NORMAL,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        windows.FILE_OPEN,
        windows.FILE_OPEN_REPARSE_POINT | windows.FILE_SYNCHRONOUS_IO_NONALERT,
        null,
        0,
    )) {
        .SUCCESS => {},
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND, .NOT_A_DIRECTORY => return error.FileNotFound,
        .OBJECT_NAME_INVALID => return error.BadPathName,
        .ACCESS_DENIED, .SHARING_VIOLATION, .DELETE_PENDING => return error.AccessDenied,
        else => |err| return windows.unexpectedStatus(err),
    }
    const file: std.fs.File = .{ .handle = handle };
    errdefer file.close();
    if (GetFileType(handle) != file_type_disk) return error.NotRegularFile;
    return file;
}
