// VFS Server
//
// Virtual Filesystem Server for Nova microkernel.
// Routes file operations to filesystem drivers via IPC.

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

// VFS message types
pub const MSG_OPEN: u32 = 1;
pub const MSG_CLOSE: u32 = 2;
pub const MSG_READ: u32 = 3;
pub const MSG_WRITE: u32 = 4;
pub const MSG_STAT: u32 = 5;
pub const MSG_READDIR: u32 = 6;
pub const MSG_MKDIR: u32 = 7;
pub const MSG_UNLINK: u32 = 8;

// File descriptor table (simple static allocation)
const MAX_FDS: usize = 64;
const MAX_FILES: usize = 128;

const FileDescriptor = struct {
    valid: bool,
    file_idx: usize,
    offset: u64,
    flags: u32,
};

const FileNode = struct {
    valid: bool,
    name: [64]u8,
    name_len: usize,
    size: u64,
    is_dir: bool,
    data: [1024]u8, // Simple in-memory storage
    data_len: usize,
};

var fd_table: [MAX_FDS]FileDescriptor = [_]FileDescriptor{.{
    .valid = false,
    .file_idx = 0,
    .offset = 0,
    .flags = 0,
}} ** MAX_FDS;

var files: [MAX_FILES]FileNode = [_]FileNode{.{
    .valid = false,
    .name = [_]u8{0} ** 64,
    .name_len = 0,
    .size = 0,
    .is_dir = false,
    .data = [_]u8{0} ** 1024,
    .data_len = 0,
}} ** MAX_FILES;

var next_fd: usize = 3; // 0, 1, 2 reserved for stdin/out/err

/// Main entry point for VFS server
export fn main() i32 {
    libnova.println("VFS server starting...");

    // Initialize root directory
    initRootFs();

    libnova.println("VFS server ready, waiting for requests...");

    // Main message loop
    while (true) {
        // In a full implementation, we'd:
        // 1. Receive message from IPC port
        // 2. Parse the request type
        // 3. Handle the request
        // 4. Send reply

        // For now, just yield
        syscall.yield();
    }

    return 0;
}

/// Initialize root filesystem
fn initRootFs() void {
    // Create root directory
    files[0] = .{
        .valid = true,
        .name = [_]u8{0} ** 64,
        .name_len = 1,
        .size = 0,
        .is_dir = true,
        .data = [_]u8{0} ** 1024,
        .data_len = 0,
    };
    files[0].name[0] = '/';

    // Create /dev directory
    files[1] = .{
        .valid = true,
        .name = [_]u8{0} ** 64,
        .name_len = 4,
        .size = 0,
        .is_dir = true,
        .data = [_]u8{0} ** 1024,
        .data_len = 0,
    };
    const dev_name = "/dev";
    for (dev_name, 0..) |c, i| {
        files[1].name[i] = c;
    }

    // Create /tmp directory
    files[2] = .{
        .valid = true,
        .name = [_]u8{0} ** 64,
        .name_len = 4,
        .size = 0,
        .is_dir = true,
        .data = [_]u8{0} ** 1024,
        .data_len = 0,
    };
    const tmp_name = "/tmp";
    for (tmp_name, 0..) |c, i| {
        files[2].name[i] = c;
    }

    libnova.println("  Root filesystem initialized");
}

/// Open a file
fn vfsOpen(path: []const u8, flags: u32) i32 {
    // Find file
    for (files, 0..) |*f, i| {
        if (f.valid and f.name_len == path.len) {
            var match = true;
            for (0..path.len) |j| {
                if (f.name[j] != path[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                // Allocate fd
                if (next_fd >= MAX_FDS) return -1;
                fd_table[next_fd] = .{
                    .valid = true,
                    .file_idx = i,
                    .offset = 0,
                    .flags = flags,
                };
                const fd = next_fd;
                next_fd += 1;
                return @intCast(fd);
            }
        }
    }
    return -1; // Not found
}

/// Close a file
fn vfsClose(fd: usize) i32 {
    if (fd >= MAX_FDS or !fd_table[fd].valid) return -1;
    fd_table[fd].valid = false;
    return 0;
}

/// Read from a file
fn vfsRead(fd: usize, buf: []u8) i64 {
    if (fd >= MAX_FDS or !fd_table[fd].valid) return -1;

    const fdi = &fd_table[fd];
    const file = &files[fdi.file_idx];

    if (file.is_dir) return -1; // Can't read directory

    const offset = fdi.offset;
    if (offset >= file.data_len) return 0; // EOF

    const available = file.data_len - offset;
    const to_read = @min(buf.len, available);

    for (0..to_read) |i| {
        buf[i] = file.data[offset + i];
    }

    fdi.offset += to_read;
    return @intCast(to_read);
}

/// Write to a file
fn vfsWrite(fd: usize, buf: []const u8) i64 {
    if (fd >= MAX_FDS or !fd_table[fd].valid) return -1;

    const fdi = &fd_table[fd];
    const file = &files[fdi.file_idx];

    if (file.is_dir) return -1;

    const offset = fdi.offset;
    const space = 1024 - offset;
    const to_write = @min(buf.len, space);

    for (0..to_write) |i| {
        file.data[offset + i] = buf[i];
    }

    fdi.offset += to_write;
    if (fdi.offset > file.data_len) {
        file.data_len = fdi.offset;
        file.size = file.data_len;
    }

    return @intCast(to_write);
}
