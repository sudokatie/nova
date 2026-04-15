// ramfs.zig - RAM-based filesystem
//
// Simple in-memory filesystem for Nova.
// Data is stored in kernel heap and lost on reboot.
// Useful for /tmp, early boot, and testing.

const std = @import("std");
const vfs = @import("vfs.zig");

/// Maximum files in ramfs
const MAX_FILES = 1024;

/// Maximum data blocks per file
const MAX_BLOCKS_PER_FILE = 256;

/// Block size (4KB)
const BLOCK_SIZE = 4096;

/// Maximum total data blocks
const MAX_TOTAL_BLOCKS = 4096; // 16MB max

/// Ramfs file data
const RamfsFile = struct {
    name: [vfs.MAX_NAME]u8,
    name_len: u8,
    parent: ?*RamfsFile,
    children: ?*RamfsFile, // First child (for directories)
    next_sibling: ?*RamfsFile,
    inode: vfs.Inode,
    data_blocks: [MAX_BLOCKS_PER_FILE]?*[BLOCK_SIZE]u8,
    num_blocks: u16,
    in_use: bool,

    pub fn getName(self: *const RamfsFile) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *RamfsFile, name: []const u8) void {
        const len = @min(name.len, vfs.MAX_NAME);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
    }
};

/// Ramfs state
const RamfsState = struct {
    files: [MAX_FILES]RamfsFile,
    blocks: [MAX_TOTAL_BLOCKS]?*[BLOCK_SIZE]u8,
    next_inode: u64,
    used_blocks: u32,
    fs: vfs.Filesystem,
};

var state: RamfsState = undefined;
var initialized: bool = false;

/// Initialize ramfs
pub fn init() *vfs.Filesystem {
    if (initialized) {
        return &state.fs;
    }

    // Initialize file table
    for (&state.files) |*f| {
        f.in_use = false;
        f.children = null;
        f.next_sibling = null;
        f.parent = null;
        f.num_blocks = 0;
        for (&f.data_blocks) |*b| {
            b.* = null;
        }
    }

    // Initialize block table
    for (&state.blocks) |*b| {
        b.* = null;
    }

    state.next_inode = 1;
    state.used_blocks = 0;

    // Setup filesystem
    const name = "ramfs";
    @memcpy(state.fs.name[0..name.len], name);
    state.fs.name_len = name.len;
    state.fs.ops = FsOps;
    state.fs.read_only = false;
    state.fs.data = @ptrCast(&state);

    // Create root directory
    const root = allocFile() orelse unreachable;
    root.setName("/");
    root.inode.id = state.next_inode;
    state.next_inode += 1;
    root.inode.file_type = .directory;
    root.inode.permissions = vfs.DEFAULT_DIR_PERMS;
    root.inode.size = 0;
    root.inode.uid = 0;
    root.inode.gid = 0;
    root.inode.atime = 0;
    root.inode.mtime = 0;
    root.inode.ctime = 0;
    root.inode.nlink = 2; // . and parent
    root.inode.fs = &state.fs;
    root.inode.data = @ptrCast(root);
    root.parent = root; // Root is its own parent
    root.in_use = true;

    state.fs.root = &root.inode;
    initialized = true;

    return &state.fs;
}

/// Filesystem operations
const FsOps = vfs.FsOps{
    .create = create,
    .lookup = lookup,
    .read = read,
    .write = write,
    .readdir = readdir,
    .mkdir = mkdir,
    .unlink = unlink,
    .rmdir = rmdir,
    .stat = stat,
    .truncate = truncate,
    .rename = null, // TODO
};

/// Allocate a file entry
fn allocFile() ?*RamfsFile {
    for (&state.files) |*f| {
        if (!f.in_use) {
            f.in_use = true;
            f.children = null;
            f.next_sibling = null;
            f.num_blocks = 0;
            return f;
        }
    }
    return null;
}

/// Free a file entry
fn freeFile(file: *RamfsFile) void {
    // Free data blocks
    for (file.data_blocks[0..file.num_blocks]) |block| {
        if (block) |b| {
            freeBlock(b);
        }
    }
    file.in_use = false;
}

/// Allocate a data block
fn allocBlock() ?*[BLOCK_SIZE]u8 {
    if (state.used_blocks >= MAX_TOTAL_BLOCKS) return null;

    // In a real kernel, this would use the heap allocator
    // For now, use a simple static pool
    for (&state.blocks) |*slot| {
        if (slot.* == null) {
            // Create block from static storage
            slot.* = @ptrCast(&block_storage[state.used_blocks * BLOCK_SIZE]);
            state.used_blocks += 1;
            @memset(slot.*.?, 0);
            return slot.*;
        }
    }
    return null;
}

var block_storage: [MAX_TOTAL_BLOCKS * BLOCK_SIZE]u8 = undefined;

/// Free a data block
fn freeBlock(block: *[BLOCK_SIZE]u8) void {
    // In static allocation, just mark as available
    _ = block;
    // Note: Real implementation would free to heap
}

/// Parse path and find parent directory
fn parsePath(path: []const u8) struct { parent: ?*RamfsFile, name: []const u8 } {
    if (path.len == 0 or path[0] != '/') {
        return .{ .parent = null, .name = "" };
    }

    // Start from root
    var current = @as(*RamfsFile, @alignCast(@ptrCast(state.fs.root.?.data.?)));
    var remaining = path[1..]; // Skip leading /

    while (remaining.len > 0) {
        // Find next component
        var end: usize = 0;
        while (end < remaining.len and remaining[end] != '/') : (end += 1) {}

        const component = remaining[0..end];

        // Check if this is the last component
        if (end >= remaining.len or (end + 1 >= remaining.len)) {
            // This is the target name
            return .{ .parent = current, .name = component };
        }

        // Navigate to child directory
        if (findChild(current, component)) |child| {
            if (child.inode.file_type != .directory) {
                return .{ .parent = null, .name = "" }; // Not a directory
            }
            current = child;
            remaining = remaining[end + 1 ..];
        } else {
            return .{ .parent = null, .name = "" }; // Path not found
        }
    }

    // Path was just "/"
    return .{ .parent = current, .name = "" };
}

/// Find child by name
fn findChild(parent: *RamfsFile, name: []const u8) ?*RamfsFile {
    var child = parent.children;
    while (child) |c| : (child = c.next_sibling) {
        if (std.mem.eql(u8, c.getName(), name)) {
            return c;
        }
    }
    return null;
}

/// Add child to parent
fn addChild(parent: *RamfsFile, child: *RamfsFile) void {
    child.parent = parent;
    child.next_sibling = parent.children;
    parent.children = child;
    parent.inode.nlink += 1;
}

/// Remove child from parent
fn removeChild(parent: *RamfsFile, child: *RamfsFile) void {
    if (parent.children == child) {
        parent.children = child.next_sibling;
    } else {
        var prev = parent.children;
        while (prev) |p| : (prev = p.next_sibling) {
            if (p.next_sibling == child) {
                p.next_sibling = child.next_sibling;
                break;
            }
        }
    }
    parent.inode.nlink -= 1;
}

// VFS operations implementation

fn create(fs: *vfs.Filesystem, path: []const u8, file_type: vfs.FileType, perms: vfs.Permissions) vfs.VfsError!*vfs.Inode {
    _ = fs;

    const parsed = parsePath(path);
    if (parsed.parent == null or parsed.name.len == 0) {
        return error.InvalidPath;
    }

    // Check if already exists
    if (findChild(parsed.parent.?, parsed.name) != null) {
        return error.AlreadyExists;
    }

    // Allocate new file
    const file = allocFile() orelse return error.NoSpace;
    file.setName(parsed.name);
    file.inode.id = state.next_inode;
    state.next_inode += 1;
    file.inode.file_type = file_type;
    file.inode.permissions = perms;
    file.inode.size = 0;
    file.inode.uid = 0;
    file.inode.gid = 0;
    file.inode.atime = 0;
    file.inode.mtime = 0;
    file.inode.ctime = 0;
    file.inode.nlink = 1;
    file.inode.fs = &state.fs;
    file.inode.data = @ptrCast(file);

    addChild(parsed.parent.?, file);

    return &file.inode;
}

fn lookup(fs: *vfs.Filesystem, path: []const u8) vfs.VfsError!*vfs.Inode {
    _ = fs;

    if (path.len == 0) return error.InvalidPath;

    // Handle root
    if (path.len == 1 and path[0] == '/') {
        return state.fs.root.?;
    }

    const parsed = parsePath(path);
    if (parsed.parent == null) {
        return error.NotFound;
    }

    if (parsed.name.len == 0) {
        // Path points to a directory (ended with /)
        return &parsed.parent.?.inode;
    }

    if (findChild(parsed.parent.?, parsed.name)) |child| {
        return &child.inode;
    }

    return error.NotFound;
}

fn read(inode: *vfs.Inode, buffer: []u8, offset: u64) vfs.VfsError!usize {
    const file = @as(*RamfsFile, @alignCast(@ptrCast(inode.data.?)));

    if (inode.file_type == .directory) {
        return error.IsDirectory;
    }

    if (offset >= inode.size) {
        return 0;
    }

    const available = inode.size - offset;
    const to_read = @min(buffer.len, available);

    var bytes_read: usize = 0;
    var current_offset = offset;

    while (bytes_read < to_read) {
        const block_idx = current_offset / BLOCK_SIZE;
        const block_offset = current_offset % BLOCK_SIZE;
        const block_remaining = BLOCK_SIZE - block_offset;
        const chunk_size = @min(block_remaining, to_read - bytes_read);

        if (block_idx >= file.num_blocks) break;
        if (file.data_blocks[block_idx]) |block| {
            @memcpy(buffer[bytes_read..][0..chunk_size], block[block_offset..][0..chunk_size]);
        }

        bytes_read += chunk_size;
        current_offset += chunk_size;
    }

    return bytes_read;
}

fn write(inode: *vfs.Inode, data: []const u8, offset: u64) vfs.VfsError!usize {
    const file = @as(*RamfsFile, @alignCast(@ptrCast(inode.data.?)));

    if (inode.file_type == .directory) {
        return error.IsDirectory;
    }

    var bytes_written: usize = 0;
    var current_offset = offset;

    while (bytes_written < data.len) {
        const block_idx = current_offset / BLOCK_SIZE;
        const block_offset = current_offset % BLOCK_SIZE;
        const block_remaining = BLOCK_SIZE - block_offset;
        const chunk_size = @min(block_remaining, data.len - bytes_written);

        // Ensure block exists
        if (block_idx >= MAX_BLOCKS_PER_FILE) {
            return error.NoSpace;
        }

        while (file.num_blocks <= block_idx) {
            file.data_blocks[file.num_blocks] = allocBlock() orelse return error.NoSpace;
            file.num_blocks += 1;
        }

        if (file.data_blocks[block_idx]) |block| {
            @memcpy(block[block_offset..][0..chunk_size], data[bytes_written..][0..chunk_size]);
        }

        bytes_written += chunk_size;
        current_offset += chunk_size;
    }

    // Update size if we extended the file
    if (offset + bytes_written > inode.size) {
        inode.size = offset + bytes_written;
    }

    return bytes_written;
}

fn readdir(inode: *vfs.Inode, entries: []vfs.DirEntry, offset: u64) vfs.VfsError!usize {
    const dir = @as(*RamfsFile, @alignCast(@ptrCast(inode.data.?)));

    if (inode.file_type != .directory) {
        return error.NotDirectory;
    }

    var count: usize = 0;
    var idx: u64 = 0;
    var child = dir.children;

    // Skip to offset
    while (child != null and idx < offset) : ({
        child = child.?.next_sibling;
        idx += 1;
    }) {}

    // Fill entries
    while (child != null and count < entries.len) : ({
        child = child.?.next_sibling;
        count += 1;
    }) {
        entries[count].setName(child.?.getName());
        entries[count].file_type = child.?.inode.file_type;
        entries[count].inode = child.?.inode.id;
    }

    return count;
}

fn mkdir(fs: *vfs.Filesystem, path: []const u8, perms: vfs.Permissions) vfs.VfsError!*vfs.Inode {
    return create(fs, path, .directory, perms);
}

fn unlink(fs: *vfs.Filesystem, path: []const u8) vfs.VfsError!void {
    _ = fs;

    const parsed = parsePath(path);
    if (parsed.parent == null or parsed.name.len == 0) {
        return error.InvalidPath;
    }

    const file = findChild(parsed.parent.?, parsed.name) orelse return error.NotFound;

    if (file.inode.file_type == .directory) {
        return error.IsDirectory;
    }

    removeChild(parsed.parent.?, file);
    freeFile(file);
}

fn rmdir(fs: *vfs.Filesystem, path: []const u8) vfs.VfsError!void {
    _ = fs;

    const parsed = parsePath(path);
    if (parsed.parent == null or parsed.name.len == 0) {
        return error.InvalidPath;
    }

    const dir = findChild(parsed.parent.?, parsed.name) orelse return error.NotFound;

    if (dir.inode.file_type != .directory) {
        return error.NotDirectory;
    }

    // Check if empty
    if (dir.children != null) {
        return error.NotEmpty;
    }

    removeChild(parsed.parent.?, dir);
    freeFile(dir);
}

fn stat(inode: *vfs.Inode) vfs.Stat {
    return inode.stat();
}

fn truncate(inode: *vfs.Inode, size: u64) vfs.VfsError!void {
    const file = @as(*RamfsFile, @alignCast(@ptrCast(inode.data.?)));

    if (inode.file_type == .directory) {
        return error.IsDirectory;
    }

    // Free blocks beyond new size
    const needed_blocks = (size + BLOCK_SIZE - 1) / BLOCK_SIZE;
    while (file.num_blocks > needed_blocks) {
        file.num_blocks -= 1;
        if (file.data_blocks[file.num_blocks]) |block| {
            freeBlock(block);
            file.data_blocks[file.num_blocks] = null;
        }
    }

    inode.size = size;
}

// Tests
pub fn runTests() bool {
    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test 1: Init
    const fs = init();
    if (fs.root != null) {
        passed += 1;
    } else {
        failed += 1;
    }

    // Test 2: Create file
    if (create(&state.fs, "/test.txt", .regular, vfs.DEFAULT_FILE_PERMS)) |_| {
        passed += 1;
    } else |_| {
        failed += 1;
    }

    // Test 3: Lookup file
    if (lookup(&state.fs, "/test.txt")) |inode| {
        if (inode.file_type == .regular) {
            passed += 1;
        } else {
            failed += 1;
        }
    } else |_| {
        failed += 1;
    }

    // Test 4: Write to file
    if (lookup(&state.fs, "/test.txt")) |inode| {
        const data = "Hello, Nova!";
        if (write(inode, data, 0)) |written| {
            if (written == data.len) {
                passed += 1;
            } else {
                failed += 1;
            }
        } else |_| {
            failed += 1;
        }
    } else |_| {
        failed += 1;
    }

    // Test 5: Read from file
    if (lookup(&state.fs, "/test.txt")) |inode| {
        var buffer: [64]u8 = undefined;
        if (read(inode, &buffer, 0)) |bytes_read| {
            if (bytes_read == 12 and std.mem.eql(u8, buffer[0..12], "Hello, Nova!")) {
                passed += 1;
            } else {
                failed += 1;
            }
        } else |_| {
            failed += 1;
        }
    } else |_| {
        failed += 1;
    }

    // Test 6: Create directory
    if (mkdir(&state.fs, "/testdir", vfs.DEFAULT_DIR_PERMS)) |_| {
        passed += 1;
    } else |_| {
        failed += 1;
    }

    // Test 7: Create file in directory
    if (create(&state.fs, "/testdir/nested.txt", .regular, vfs.DEFAULT_FILE_PERMS)) |_| {
        passed += 1;
    } else |_| {
        failed += 1;
    }

    // Test 8: Readdir
    var entries: [16]vfs.DirEntry = undefined;
    if (lookup(&state.fs, "/")) |root_inode| {
        if (readdir(root_inode, &entries, 0)) |count| {
            if (count >= 2) { // test.txt and testdir
                passed += 1;
            } else {
                failed += 1;
            }
        } else |_| {
            failed += 1;
        }
    } else |_| {
        failed += 1;
    }

    // Test 9: Unlink file
    if (unlink(&state.fs, "/test.txt")) |_| {
        // Verify it's gone
        if (lookup(&state.fs, "/test.txt")) |_| {
            failed += 1;
        } else |_| {
            passed += 1;
        }
    } else |_| {
        failed += 1;
    }

    // Test 10: Rmdir (should fail - not empty)
    if (rmdir(&state.fs, "/testdir")) |_| {
        failed += 1; // Should have failed
    } else |err| {
        if (err == error.NotEmpty) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    // Test 11: Unlink nested, then rmdir
    if (unlink(&state.fs, "/testdir/nested.txt")) |_| {
        if (rmdir(&state.fs, "/testdir")) |_| {
            passed += 1;
        } else |_| {
            failed += 1;
        }
    } else |_| {
        failed += 1;
    }

    // Report
    return failed == 0;
}
