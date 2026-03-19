// Kernel Heap Allocator
//
// Slab-based allocator for kernel objects.
// Uses power-of-2 slab caches (16-2048 bytes).
// Large allocations fall back to VMM directly.

const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const console = @import("../lib/console.zig");

pub const PAGE_SIZE: u64 = 4096;

// Large allocation threshold (use VMM directly above this)
const LARGE_THRESHOLD: usize = 2048;

// Slab cache sizes (power of 2)
const CACHE_SIZES = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
const NUM_CACHES = CACHE_SIZES.len;

/// Free list node (embedded in free objects)
const FreeNode = struct {
    next: ?*FreeNode,
};

/// A single slab (one page of objects)
const Slab = struct {
    next: ?*Slab, // Next slab in cache list
    free_count: usize, // Number of free objects
    free_list: ?*FreeNode, // Head of free list

    /// Initialize a slab for given object size
    pub fn init(self: *Slab, obj_size: usize) void {
        self.next = null;

        // Calculate number of objects per slab
        // Leave space for Slab header at start of page
        const header_size = @sizeOf(Slab);
        const usable_space = PAGE_SIZE - header_size;
        const obj_count = usable_space / obj_size;

        self.free_count = obj_count;

        // Build free list (objects start after header)
        const base: usize = @intFromPtr(self) + header_size;
        var prev: ?*FreeNode = null;

        var i: usize = obj_count;
        while (i > 0) : (i -= 1) {
            const obj_addr = base + (i - 1) * obj_size;
            const node: *FreeNode = @ptrFromInt(obj_addr);
            node.next = prev;
            prev = node;
        }
        self.free_list = prev;
    }

    /// Allocate an object from this slab
    pub fn alloc(self: *Slab) ?[*]u8 {
        const node = self.free_list orelse return null;
        self.free_list = node.next;
        self.free_count -= 1;
        return @ptrCast(node);
    }

    /// Free an object back to this slab
    pub fn free(self: *Slab, ptr: [*]u8) void {
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = self.free_list;
        self.free_list = node;
        self.free_count += 1;
    }
};

/// Slab cache for a specific object size
const SlabCache = struct {
    obj_size: usize,
    slabs: ?*Slab, // List of slabs with free space
    full_slabs: ?*Slab, // List of full slabs

    pub fn init(obj_size: usize) SlabCache {
        return .{
            .obj_size = obj_size,
            .slabs = null,
            .full_slabs = null,
        };
    }

    /// Allocate an object from this cache
    pub fn alloc(self: *SlabCache) ?[*]u8 {
        // Try to allocate from existing slab
        if (self.slabs) |slab| {
            const ptr = slab.alloc();
            if (ptr != null) {
                // Move to full list if now full
                if (slab.free_count == 0) {
                    self.slabs = slab.next;
                    slab.next = self.full_slabs;
                    self.full_slabs = slab;
                }
                return ptr;
            }
        }

        // Need a new slab
        const page_phys = pmm.allocPage() orelse return null;
        const slab: *Slab = @ptrFromInt(pmm.physToVirt(page_phys));
        slab.init(self.obj_size);

        const ptr = slab.alloc();

        // Add slab to list (will have free space since we just created it)
        if (slab.free_count > 0) {
            slab.next = self.slabs;
            self.slabs = slab;
        } else {
            slab.next = self.full_slabs;
            self.full_slabs = slab;
        }

        return ptr;
    }

    /// Free an object back to this cache
    pub fn free(self: *SlabCache, ptr: [*]u8) void {
        // Find the slab this object belongs to (page-aligned)
        const slab_addr = @intFromPtr(ptr) & ~@as(usize, PAGE_SIZE - 1);
        const slab: *Slab = @ptrFromInt(slab_addr);

        const was_full = (slab.free_count == 0);
        slab.free(ptr);

        // Move from full list to partial list if it was full
        if (was_full) {
            // Remove from full list
            var prev: ?*Slab = null;
            var curr = self.full_slabs;
            while (curr) |s| {
                if (s == slab) {
                    if (prev) |p| {
                        p.next = s.next;
                    } else {
                        self.full_slabs = s.next;
                    }
                    break;
                }
                prev = s;
                curr = s.next;
            }
            // Add to partial list
            slab.next = self.slabs;
            self.slabs = slab;
        }
    }
};

// Global slab caches
var caches: [NUM_CACHES]SlabCache = undefined;
var initialized: bool = false;

/// Initialize the heap allocator
pub fn init() void {
    for (0..NUM_CACHES) |i| {
        caches[i] = SlabCache.init(CACHE_SIZES[i]);
    }
    initialized = true;
    console.log(.info, "Heap initialized: {} slab caches (16-2048 bytes)", .{NUM_CACHES});
}

/// Get cache index for size (or null if too large)
fn getCacheIndex(size: usize) ?usize {
    for (CACHE_SIZES, 0..) |cache_size, i| {
        if (size <= cache_size) return i;
    }
    return null;
}

/// Allocate memory from kernel heap
pub fn alloc(size: usize) ?[*]u8 {
    if (!initialized) return null;
    if (size == 0) return null;

    // Use slab allocator for small objects
    if (getCacheIndex(size)) |idx| {
        return caches[idx].alloc();
    }

    // Large allocation: use VMM directly
    const num_pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    // Allocate virtual address space (use a fixed large allocation region)
    // For simplicity, just allocate physical pages and use HHDM
    const phys = pmm.allocPages(num_pages) orelse return null;
    const virt = pmm.physToVirt(phys);

    // Store size at start of allocation for free
    const header: *usize = @ptrFromInt(virt);
    header.* = num_pages;
    return @ptrFromInt(virt + @sizeOf(usize));
}

/// Free memory back to kernel heap
pub fn free(ptr: ?[*]u8, size: usize) void {
    if (!initialized) return;
    if (ptr == null) return;

    // Slab allocator for small objects
    if (getCacheIndex(size)) |idx| {
        caches[idx].free(ptr.?);
        return;
    }

    // Large allocation: free via VMM
    const header_addr = @intFromPtr(ptr.?) - @sizeOf(usize);
    const header: *usize = @ptrFromInt(header_addr);
    const num_pages = header.*;
    const phys = pmm.virtToPhys(header_addr);
    pmm.freePages(phys, num_pages);
}

/// Kernel allocator interface (std.mem.Allocator compatible)
pub const allocator = Allocator{};

const Allocator = struct {
    pub fn alloc_fn(self: *Allocator, len: usize, ptr_align: u29, ret_addr: usize) ?[*]u8 {
        _ = self;
        _ = ptr_align;
        _ = ret_addr;
        return alloc(len);
    }

    pub fn resize_fn(self: *Allocator, buf: []u8, buf_align: u29, new_len: usize, ret_addr: usize) ?usize {
        _ = self;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        // Resize not supported - just return null to force realloc
        return null;
    }

    pub fn free_fn(self: *Allocator, buf: []u8, buf_align: u29, ret_addr: usize) void {
        _ = self;
        _ = buf_align;
        _ = ret_addr;
        free(buf.ptr, buf.len);
    }
};

/// Test the heap allocator
pub fn test_heap() void {
    console.log(.debug, "Heap test: allocating small objects...", .{});

    // Test small allocations
    var ptrs: [10]?[*]u8 = undefined;
    for (0..10) |i| {
        ptrs[i] = alloc(32);
        if (ptrs[i]) |p| {
            // Write pattern to verify memory
            p[0] = @truncate(i);
        }
    }

    // Verify and free
    var success = true;
    for (0..10) |i| {
        if (ptrs[i]) |p| {
            if (p[0] != @as(u8, @truncate(i))) {
                console.log(.warn, "  Pattern mismatch at {}", .{i});
                success = false;
            }
            free(p, 32);
        }
    }

    // Test large allocation
    if (alloc(4096)) |large| {
        large[0] = 0xAB;
        large[4095] = 0xCD;
        if (large[0] == 0xAB and large[4095] == 0xCD) {
            console.log(.debug, "  Large allocation verified", .{});
        }
        free(large, 4096);
    }

    if (success) {
        console.log(.info, "Heap test passed", .{});
    } else {
        console.log(.err, "Heap test failed", .{});
    }
}
