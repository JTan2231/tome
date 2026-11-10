//! File content loading and preparation, independent of rendering and terminals.
pub const Buffer = @import("buffer.zig").Buffer;
pub const Document = @import("storage.zig").Document;
pub const Workspace = @import("workspace.zig").Workspace;
pub const max_file_size = @import("storage.zig").max_file_size;
pub const cache_file_limit = @import("workspace.zig").cache_file_limit;
pub const cache_byte_limit = @import("workspace.zig").cache_byte_limit;
pub const search = @import("search.zig");

test {
    _ = @import("buffer.zig");
    _ = @import("storage.zig");
    _ = @import("workspace.zig");
    _ = @import("search.zig");
}
