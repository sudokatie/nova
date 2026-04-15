// vfs.zig - Virtual Filesystem Interface
//
// Provides a unified interface for filesystem operations.
// Filesystems register with the VFS and mount at specific paths.

const std = @import("std");

/// Maximum path length
pub const MAX_PATH = 256;

/// Maximum filename length
pub const MAX_NAME = 64;

/// Maximum open files per process
pub const MAX_OPEN_FILES = 32;

/// File types
pub const FileType = enum(u8) {
    regular,
    directory,
    device,
    symlink,
    socket,
    fifo,
};

/// File permissions (Unix-style)
pub const Permissions = packed struct {
    other_execute: bool = false,
    other_write: bool = false,
    other_read: bool = false,
    group_execute: bool = false,
    group_write: bool = false,
    group_read: bool = false,
    owner_execute: bool = false,
    owner_write: bool = false,
    owner_read: bool = false,
    _padding: u7 = 0,
};

/// Default permissions: rwxr-xr-x (755)
pub const DEFAULT_DIR_PERMS = Permissions{
    .owner_read = true,
    .owner_write = true,
    .owner_execute = true,
    .group_read = true,
    .group_execute = true,
    .other_read = true,
    .other_execute = true,
};

/// Default permissions: rw-r--r-- (644)
pub const DEFAULT_FILE_PERMS = Permissions{
    .owner_read = true,
    .owner_write = true,
    .group_read = true,
    .other_read = true,
};

/// File metadata
pub const Stat = struct {
    file_type: FileType,
    permissions: Permissions,
    size: u64,
    uid: u32,
    gid: u32,
    atime: u64, // Access time
    mtime: u64, // Modification time
    ctime: u64, // Creation time
    inode: u64,
    nlink: u32, // Number of hard links
};

/// Directory entry
pub const DirEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    file_type: FileType,
    inode: u64,

    pub fn getName(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *DirEntry, name: []const u8) void {
        const len = @min(name.len, MAX_NAME);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
    }
};

/// Open file flags
pub const OpenFlags = packed struct {
    read: bool = false,
    write: bool = false,
    append: bool = false,
    create: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
    _padding: u10 = 0,
};

/// Seek origin
pub const SeekOrigin = enum {
    start,
    current,
    end,
};

/// VFS error codes
pub const VfsError = error{
    NotFound,
    AlreadyExists,
    NotDirectory,
    IsDirectory,
    NotEmpty,
    NoSpace,
    ReadOnly,
    InvalidPath,
    TooManyOpenFiles,
    BadFileDescriptor,
    PermissionDenied,
    IoError,
    NotSupported,
};

/// Filesystem operations interface
pub const FsOps = struct {
    /// Create a file
    create: ?*const fn (fs: *Filesystem, path: []const u8, file_type: FileType, perms: Permissions) VfsError!*Inode = null,

    /// Lookup a file by path
    lookup: ?*const fn (fs: *Filesystem, path: []const u8) VfsError!*Inode = null,

    /// Read from a file
    read: ?*const fn (inode: *Inode, buffer: []u8, offset: u64) VfsError!usize = null,

    /// Write to a file
    write: ?*const fn (inode: *Inode, data: []const u8, offset: u64) VfsError!usize = null,

    /// Read directory entries
    readdir: ?*const fn (inode: *Inode, entries: []DirEntry, offset: u64) VfsError!usize = null,

    /// Create a directory
    mkdir: ?*const fn (fs: *Filesystem, path: []const u8, perms: Permissions) VfsError!*Inode = null,

    /// Remove a file
    unlink: ?*const fn (fs: *Filesystem, path: []const u8) VfsError!void = null,

    /// Remove a directory
    rmdir: ?*const fn (fs: *Filesystem, path: []const u8) VfsError!void = null,

    /// Get file status
    stat: ?*const fn (inode: *Inode) Stat = null,

    /// Truncate file
    truncate: ?*const fn (inode: *Inode, size: u64) VfsError!void = null,

    /// Rename/move a file
    rename: ?*const fn (fs: *Filesystem, old_path: []const u8, new_path: []const u8) VfsError!void = null,
};

/// Inode - represents a file or directory
pub const Inode = struct {
    id: u64,
    file_type: FileType,
    permissions: Permissions,
    size: u64,
    uid: u32,
    gid: u32,
    atime: u64,
    mtime: u64,
    ctime: u64,
    nlink: u32,
    fs: *Filesystem,
    data: ?*anyopaque, // Filesystem-specific data

    pub fn stat(self: *Inode) Stat {
        return Stat{
            .file_type = self.file_type,
            .permissions = self.permissions,
            .size = self.size,
            .uid = self.uid,
            .gid = self.gid,
            .atime = self.atime,
            .mtime = self.mtime,
            .ctime = self.ctime,
            .inode = self.id,
            .nlink = self.nlink,
        };
    }
};

/// Filesystem instance
pub const Filesystem = struct {
    name: [32]u8,
    name_len: u8,
    ops: FsOps,
    root: ?*Inode,
    data: ?*anyopaque, // Filesystem-specific data
    read_only: bool,

    pub fn getName(self: *const Filesystem) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Mount point
pub const MountPoint = struct {
    path: [MAX_PATH]u8,
    path_len: u16,
    fs: *Filesystem,
    next: ?*MountPoint,

    pub fn getPath(self: *const MountPoint) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Open file descriptor
pub const FileDescriptor = struct {
    inode: *Inode,
    offset: u64,
    flags: OpenFlags,
    refcount: u32,
};

/// Global VFS state
var mount_list: ?*MountPoint = null;
var next_fd: u32 = 3; // 0, 1, 2 reserved for stdin/out/err

/// Mount a filesystem at a path
pub fn mount(fs: *Filesystem, path: []const u8) VfsError!void {
    // Create mount point
    const mp = @as(*MountPoint, @ptrFromInt(@intFromPtr(&mount_storage) + mount_count * @sizeOf(MountPoint)));
    if (mount_count >= MAX_MOUNTS) return error.NoSpace;

    const len = @min(path.len, MAX_PATH);
    @memcpy(mp.path[0..len], path[0..len]);
    mp.path_len = @intCast(len);
    mp.fs = fs;
    mp.next = mount_list;
    mount_list = mp;
    mount_count += 1;
}

var mount_storage: [MAX_MOUNTS * @sizeOf(MountPoint)]u8 = undefined;
var mount_count: usize = 0;
const MAX_MOUNTS = 16;

/// Find filesystem for a path
pub fn findFilesystem(path: []const u8) ?*Filesystem {
    var mp = mount_list;
    var best_match: ?*MountPoint = null;
    var best_len: usize = 0;

    while (mp) |m| : (mp = m.next) {
        const mp_path = m.getPath();
        if (path.len >= mp_path.len) {
            if (std.mem.startsWith(u8, path, mp_path)) {
                if (mp_path.len > best_len) {
                    best_match = m;
                    best_len = mp_path.len;
                }
            }
        }
    }

    if (best_match) |m| {
        return m.fs;
    }
    return null;
}

/// Get relative path within filesystem
pub fn relativePath(path: []const u8, mount_path: []const u8) []const u8 {
    if (path.len <= mount_path.len) return "/";
    const rel = path[mount_path.len..];
    if (rel.len == 0 or rel[0] != '/') {
        // Path was exact mount point
        return "/";
    }
    return rel;
}

// High-level VFS operations

/// Open a file
pub fn open(path: []const u8, flags: OpenFlags) VfsError!*FileDescriptor {
    const fs = findFilesystem(path) orelse return error.NotFound;
    const ops = fs.ops;

    // Try to look up existing file
    var inode: *Inode = undefined;
    if (ops.lookup) |lookup_fn| {
        const lookup_result = lookup_fn(fs, path);
        if (lookup_result) |found_inode| {
            inode = found_inode;
        } else |err| {
            if (err == error.NotFound and flags.create) {
                // Create new file
                if (ops.create) |create_fn| {
                    inode = try create_fn(fs, path, .regular, DEFAULT_FILE_PERMS);
                } else {
                    return error.NotSupported;
                }
            } else {
                return err;
            }
        }
    } else {
        return error.NotSupported;
    }

    // Truncate if requested
    if (flags.truncate and flags.write) {
        if (ops.truncate) |trunc_fn| {
            try trunc_fn(inode, 0);
        }
    }

    // Create file descriptor
    const fd = @as(*FileDescriptor, @ptrFromInt(@intFromPtr(&fd_storage) + fd_count * @sizeOf(FileDescriptor)));
    if (fd_count >= MAX_FDS) return error.TooManyOpenFiles;

    fd.inode = inode;
    fd.offset = if (flags.append) inode.size else 0;
    fd.flags = flags;
    fd.refcount = 1;
    fd_count += 1;

    return fd;
}

var fd_storage: [MAX_FDS * @sizeOf(FileDescriptor)]u8 = undefined;
var fd_count: usize = 0;
const MAX_FDS = 256;

/// Read from file descriptor
pub fn read(fd: *FileDescriptor, buffer: []u8) VfsError!usize {
    if (!fd.flags.read) return error.PermissionDenied;

    const ops = fd.inode.fs.ops;
    if (ops.read) |read_fn| {
        const bytes_read = try read_fn(fd.inode, buffer, fd.offset);
        fd.offset += bytes_read;
        return bytes_read;
    }
    return error.NotSupported;
}

/// Write to file descriptor
pub fn write(fd: *FileDescriptor, data: []const u8) VfsError!usize {
    if (!fd.flags.write) return error.PermissionDenied;
    if (fd.inode.fs.read_only) return error.ReadOnly;

    const ops = fd.inode.fs.ops;
    if (ops.write) |write_fn| {
        const bytes_written = try write_fn(fd.inode, data, fd.offset);
        fd.offset += bytes_written;
        return bytes_written;
    }
    return error.NotSupported;
}

/// Seek in file
pub fn seek(fd: *FileDescriptor, offset: i64, origin: SeekOrigin) VfsError!u64 {
    const new_offset: i64 = switch (origin) {
        .start => offset,
        .current => @as(i64, @intCast(fd.offset)) + offset,
        .end => @as(i64, @intCast(fd.inode.size)) + offset,
    };

    if (new_offset < 0) return error.InvalidPath;
    fd.offset = @intCast(new_offset);
    return fd.offset;
}

/// Close file descriptor
pub fn close(fd: *FileDescriptor) void {
    fd.refcount -= 1;
    // Note: In a full implementation, we'd reclaim the fd slot
}

/// Create directory
pub fn mkdir(path: []const u8, perms: Permissions) VfsError!void {
    const fs = findFilesystem(path) orelse return error.NotFound;
    if (fs.read_only) return error.ReadOnly;

    if (fs.ops.mkdir) |mkdir_fn| {
        _ = try mkdir_fn(fs, path, perms);
    } else {
        return error.NotSupported;
    }
}

/// Remove file
pub fn unlink(path: []const u8) VfsError!void {
    const fs = findFilesystem(path) orelse return error.NotFound;
    if (fs.read_only) return error.ReadOnly;

    if (fs.ops.unlink) |unlink_fn| {
        try unlink_fn(fs, path);
    } else {
        return error.NotSupported;
    }
}

/// Remove directory
pub fn rmdir(path: []const u8) VfsError!void {
    const fs = findFilesystem(path) orelse return error.NotFound;
    if (fs.read_only) return error.ReadOnly;

    if (fs.ops.rmdir) |rmdir_fn| {
        try rmdir_fn(fs, path);
    } else {
        return error.NotSupported;
    }
}

/// Get file status
pub fn stat(path: []const u8) VfsError!Stat {
    const fs = findFilesystem(path) orelse return error.NotFound;

    if (fs.ops.lookup) |lookup_fn| {
        const inode = try lookup_fn(fs, path);
        return inode.stat();
    }
    return error.NotSupported;
}

/// Read directory
pub fn readdir(path: []const u8, entries: []DirEntry) VfsError!usize {
    const fs = findFilesystem(path) orelse return error.NotFound;

    if (fs.ops.lookup) |lookup_fn| {
        const inode = try lookup_fn(fs, path);
        if (inode.file_type != .directory) return error.NotDirectory;

        if (fs.ops.readdir) |readdir_fn| {
            return try readdir_fn(inode, entries, 0);
        }
    }
    return error.NotSupported;
}
