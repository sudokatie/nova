// Physical Memory Manager
//
// Bitmap-based allocator for physical page frames.
// Tracks free/used pages from the bootloader memory map.

const limine = @import("../limine.zig");
const console = @import("../lib/console.zig");

// Page size constants
pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_SHIFT: u6 = 12;

// Memory statistics
var total_pages: u64 = 0;
var used_pages: u64 = 0;
var free_pages: u64 = 0;

// Bitmap for tracking page allocation
// Each bit represents one 4KB page (1 = used, 0 = free)
var bitmap: [*]u8 = undefined;
var bitmap_size: u64 = 0;
var highest_page: u64 = 0;

// HHDM offset for physical to virtual address translation
var hhdm_offset: u64 = 0;

/// Initialize the physical memory manager from Limine memory map
pub fn init(memmap: *limine.MemoryMapResponse, hhdm: *limine.HhdmResponse) void {
    hhdm_offset = hhdm.offset;

    // First pass: find highest physical address and count usable memory
    var highest_addr: u64 = 0;
    var usable_bytes: u64 = 0;

    for (memmap.entries()[0..memmap.entry_count]) |entry| {
        const entry_end = entry.base + entry.length;
        if (entry_end > highest_addr) {
            highest_addr = entry_end;
        }
        if (entry.kind == .usable) {
            usable_bytes += entry.length;
        }
    }

    // Calculate bitmap size (one bit per page)
    highest_page = highest_addr / PAGE_SIZE;
    bitmap_size = (highest_page + 7) / 8; // Round up to bytes
    total_pages = highest_page;

    console.log(.debug, "PMM: highest addr {x}, {} pages, bitmap {} bytes", .{ highest_addr, highest_page, bitmap_size });

    // Find a usable region large enough for the bitmap
    var bitmap_phys: u64 = 0;
    for (memmap.entries()[0..memmap.entry_count]) |entry| {
        if (entry.kind == .usable and entry.length >= bitmap_size) {
            bitmap_phys = entry.base;
            break;
        }
    }

    if (bitmap_phys == 0) {
        console.log(.err, "PMM: No memory region large enough for bitmap!", .{});
        return;
    }

    // Map bitmap to virtual address via HHDM
    bitmap = @ptrFromInt(bitmap_phys + hhdm_offset);

    // Initialize bitmap: mark all pages as used
    for (0..bitmap_size) |i| {
        bitmap[i] = 0xFF;
    }
    used_pages = total_pages;
    free_pages = 0;

    // Second pass: mark usable regions as free (except bitmap region)
    for (memmap.entries()[0..memmap.entry_count]) |entry| {
        if (entry.kind == .usable) {
            const start_page = entry.base / PAGE_SIZE;
            const end_page = (entry.base + entry.length) / PAGE_SIZE;

            var page = start_page;
            while (page < end_page) : (page += 1) {
                // Don't free the bitmap region itself
                const page_addr = page * PAGE_SIZE;
                if (page_addr >= bitmap_phys and page_addr < bitmap_phys + bitmap_size) {
                    continue;
                }
                freePage(page * PAGE_SIZE);
            }
        }
    }

    console.log(.info, "PMM initialized: {} total pages, {} free ({} MB)", .{
        total_pages,
        free_pages,
        (free_pages * PAGE_SIZE) / 1024 / 1024,
    });
}

/// Allocate a single physical page
/// Returns physical address or null if out of memory
pub fn allocPage() ?u64 {
    // Find first free bit in bitmap
    var byte_idx: u64 = 0;
    while (byte_idx < bitmap_size) : (byte_idx += 1) {
        if (bitmap[byte_idx] != 0xFF) {
            // Found a byte with at least one free bit
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                const mask = @as(u8, 1) << bit;
                if ((bitmap[byte_idx] & mask) == 0) {
                    // Found free page - mark as used
                    bitmap[byte_idx] |= mask;
                    used_pages += 1;
                    free_pages -= 1;
                    return (byte_idx * 8 + bit) * PAGE_SIZE;
                }
            }
        }
    }
    return null; // Out of memory
}

/// Free a physical page
pub fn freePage(phys_addr: u64) void {
    const page = phys_addr / PAGE_SIZE;
    if (page >= highest_page) {
        console.log(.warn, "PMM: Attempted to free invalid page {x}", .{phys_addr});
        return;
    }

    const byte_idx = page / 8;
    const bit: u3 = @truncate(page % 8);
    const mask = @as(u8, 1) << bit;

    if ((bitmap[byte_idx] & mask) == 0) {
        console.log(.warn, "PMM: Double free of page {x}", .{phys_addr});
        return;
    }

    bitmap[byte_idx] &= ~mask;
    used_pages -= 1;
    free_pages += 1;
}

/// Allocate contiguous physical pages
/// Returns physical address of first page or null if not enough contiguous memory
pub fn allocPages(count: u64) ?u64 {
    if (count == 0) return null;
    if (count == 1) return allocPage();

    // Find contiguous free pages
    var start_page: u64 = 0;
    var found_count: u64 = 0;

    var page: u64 = 0;
    while (page < highest_page) : (page += 1) {
        const byte_idx = page / 8;
        const bit: u3 = @truncate(page % 8);
        const mask = @as(u8, 1) << bit;

        if ((bitmap[byte_idx] & mask) == 0) {
            // Page is free
            if (found_count == 0) {
                start_page = page;
            }
            found_count += 1;
            if (found_count >= count) {
                // Found enough contiguous pages - mark all as used
                var i: u64 = 0;
                while (i < count) : (i += 1) {
                    const p = start_page + i;
                    const b_idx = p / 8;
                    const b: u3 = @truncate(p % 8);
                    bitmap[b_idx] |= @as(u8, 1) << b;
                }
                used_pages += count;
                free_pages -= count;
                return start_page * PAGE_SIZE;
            }
        } else {
            // Page is used - reset search
            found_count = 0;
        }
    }

    return null; // Not enough contiguous memory
}

/// Free contiguous physical pages
pub fn freePages(phys_addr: u64, count: u64) void {
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        freePage(phys_addr + i * PAGE_SIZE);
    }
}

/// Get free page count
pub fn getFreePageCount() u64 {
    return free_pages;
}

/// Get used page count
pub fn getUsedPageCount() u64 {
    return used_pages;
}

/// Get total page count
pub fn getTotalPageCount() u64 {
    return total_pages;
}

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) u64 {
    return phys + hhdm_offset;
}

/// Convert virtual address to physical using HHDM
pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}
