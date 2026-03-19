// Virtual Memory Manager
//
// Manages address spaces and page table mappings.
// Uses 4-level paging on x86_64.

const paging = @import("../arch/x86_64/paging.zig");
const pmm = @import("pmm.zig");
const console = @import("../lib/console.zig");
const limine = @import("../limine.zig");

pub const PAGE_SIZE: u64 = 4096;

// Kernel address space starts at this offset (higher half)
pub const KERNEL_BASE: u64 = 0xFFFFFFFF80000000;

// User address space boundary
pub const USER_MAX: u64 = 0x0000800000000000;

/// Page mapping flags
pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    no_execute: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,

    pub fn toEntryFlags(self: MapFlags) u64 {
        var flags: u64 = paging.Flags.PRESENT;
        if (self.writable) flags |= paging.Flags.WRITABLE;
        if (self.user) flags |= paging.Flags.USER;
        if (self.no_execute) flags |= paging.Flags.NO_EXECUTE;
        if (self.write_through) flags |= paging.Flags.WRITE_THROUGH;
        if (self.cache_disable) flags |= paging.Flags.CACHE_DISABLE;
        return flags;
    }
};

/// An address space (process or kernel)
pub const AddressSpace = struct {
    pml4_phys: u64, // Physical address of PML4 table

    /// Create a new address space (allocates PML4)
    pub fn create() ?AddressSpace {
        const pml4_phys = pmm.allocPage() orelse {
            console.log(.err, "VMM: Failed to allocate PML4 table", .{});
            return null;
        };

        // Zero the PML4 table
        const pml4_virt: [*]u8 = @ptrFromInt(pmm.physToVirt(pml4_phys));
        for (0..PAGE_SIZE) |i| {
            pml4_virt[i] = 0;
        }

        return .{ .pml4_phys = pml4_phys };
    }

    /// Create address space from existing PML4 (e.g., from Limine)
    pub fn fromExisting(pml4_phys: u64) AddressSpace {
        return .{ .pml4_phys = pml4_phys };
    }

    /// Map a virtual page to a physical page
    pub fn mapPage(self: *AddressSpace, virt_addr: u64, phys_addr: u64, flags: MapFlags) bool {
        const indices = paging.getIndices(virt_addr);
        const entry_flags = flags.toEntryFlags();

        // PML4 -> PDPT
        const pdpt_phys = self.getOrCreateTable(self.pml4_phys, indices.pml4, entry_flags) orelse return false;

        // PDPT -> PD
        const pd_phys = self.getOrCreateTable(pdpt_phys, indices.pdpt, entry_flags) orelse return false;

        // PD -> PT
        const pt_phys = self.getOrCreateTable(pd_phys, indices.pd, entry_flags) orelse return false;

        // Set the final PTE
        const pt: *paging.Table = @ptrFromInt(pmm.physToVirt(pt_phys));
        const entry = pt.getEntry(indices.pt);

        if (entry.isPresent()) {
            console.log(.warn, "VMM: Overwriting existing mapping at {x}", .{virt_addr});
        }

        entry.* = paging.Entry.init(phys_addr, entry_flags);

        // Invalidate TLB for this address
        paging.invlpg(virt_addr);

        return true;
    }

    /// Unmap a virtual page
    pub fn unmapPage(self: *AddressSpace, virt_addr: u64) bool {
        const indices = paging.getIndices(virt_addr);

        // Walk page tables to find the PTE
        const pml4: *paging.Table = @ptrFromInt(pmm.physToVirt(self.pml4_phys));
        const pml4e = pml4.getEntry(indices.pml4);
        if (!pml4e.isPresent()) return false;

        const pdpt: *paging.Table = @ptrFromInt(pmm.physToVirt(pml4e.getPhysAddr()));
        const pdpte = pdpt.getEntry(indices.pdpt);
        if (!pdpte.isPresent()) return false;

        const pd: *paging.Table = @ptrFromInt(pmm.physToVirt(pdpte.getPhysAddr()));
        const pde = pd.getEntry(indices.pd);
        if (!pde.isPresent()) return false;

        const pt: *paging.Table = @ptrFromInt(pmm.physToVirt(pde.getPhysAddr()));
        const pte = pt.getEntry(indices.pt);
        if (!pte.isPresent()) return false;

        // Clear the entry
        pte.* = paging.Entry.empty();

        // Invalidate TLB
        paging.invlpg(virt_addr);

        return true;
    }

    /// Get physical address for a virtual address (returns null if not mapped)
    pub fn translate(self: *AddressSpace, virt_addr: u64) ?u64 {
        const indices = paging.getIndices(virt_addr);

        const pml4: *paging.Table = @ptrFromInt(pmm.physToVirt(self.pml4_phys));
        const pml4e = pml4.getEntry(indices.pml4);
        if (!pml4e.isPresent()) return null;

        const pdpt: *paging.Table = @ptrFromInt(pmm.physToVirt(pml4e.getPhysAddr()));
        const pdpte = pdpt.getEntry(indices.pdpt);
        if (!pdpte.isPresent()) return null;

        // Check for 1GB huge page
        if (pdpte.isHuge()) {
            const base = pdpte.getPhysAddr() & 0xFFFFFFFFC0000000; // 1GB aligned
            return base | (virt_addr & 0x3FFFFFFF);
        }

        const pd: *paging.Table = @ptrFromInt(pmm.physToVirt(pdpte.getPhysAddr()));
        const pde = pd.getEntry(indices.pd);
        if (!pde.isPresent()) return null;

        // Check for 2MB huge page
        if (pde.isHuge()) {
            const base = pde.getPhysAddr() & 0xFFFFFFFFFFE00000; // 2MB aligned
            return base | (virt_addr & 0x1FFFFF);
        }

        const pt: *paging.Table = @ptrFromInt(pmm.physToVirt(pde.getPhysAddr()));
        const pte = pt.getEntry(indices.pt);
        if (!pte.isPresent()) return null;

        return pte.getPhysAddr() | @as(u64, indices.offset);
    }

    /// Switch to this address space (load PML4 into CR3)
    pub fn activate(self: *AddressSpace) void {
        paging.setCr3(self.pml4_phys);
    }

    /// Clone kernel mappings (high memory) into this address space
    pub fn cloneKernelMappings(self: *AddressSpace, source: *AddressSpace) void {
        const src_pml4: *paging.Table = @ptrFromInt(pmm.physToVirt(source.pml4_phys));
        const dst_pml4: *paging.Table = @ptrFromInt(pmm.physToVirt(self.pml4_phys));

        // Copy upper half of PML4 (entries 256-511 are kernel space)
        for (256..512) |i| {
            dst_pml4.entries[i] = src_pml4.entries[i];
        }
    }

    // Helper: get or create a table entry, return physical address of next table
    fn getOrCreateTable(self: *AddressSpace, table_phys: u64, index: u9, flags: u64) ?u64 {
        _ = self;
        const table: *paging.Table = @ptrFromInt(pmm.physToVirt(table_phys));
        const entry = table.getEntry(index);

        if (entry.isPresent()) {
            // Table exists, update flags if needed (make more permissive)
            if ((flags & paging.Flags.WRITABLE) != 0 and !entry.isWritable()) {
                entry.setFlags(paging.Flags.WRITABLE);
            }
            if ((flags & paging.Flags.USER) != 0 and !entry.isUser()) {
                entry.setFlags(paging.Flags.USER);
            }
            return entry.getPhysAddr();
        }

        // Allocate new table
        const new_table_phys = pmm.allocPage() orelse {
            console.log(.err, "VMM: Failed to allocate page table", .{});
            return null;
        };

        // Zero the new table
        const new_table: [*]u8 = @ptrFromInt(pmm.physToVirt(new_table_phys));
        for (0..PAGE_SIZE) |i| {
            new_table[i] = 0;
        }

        // Set the entry (intermediate tables always get PRESENT | WRITABLE | USER)
        // User bit is needed so user pages can be reached
        entry.* = paging.Entry.init(new_table_phys, paging.Flags.PRESENT | paging.Flags.WRITABLE | paging.Flags.USER);

        return new_table_phys;
    }
};

// Kernel address space (global singleton)
var kernel_space: AddressSpace = undefined;
var initialized: bool = false;

/// Initialize VMM with Limine's address space
pub fn init() void {
    // Get current CR3 (Limine's PML4)
    const cr3 = paging.getCr3();
    kernel_space = AddressSpace.fromExisting(cr3 & paging.Flags.ADDR_MASK);

    // Enable NX if supported
    if (paging.isNxSupported()) {
        paging.enableNx();
        console.log(.info, "VMM: NX bit enabled", .{});
    }

    initialized = true;
    console.log(.info, "VMM initialized: kernel PML4 at {x}", .{kernel_space.pml4_phys});
}

/// Get the kernel address space
pub fn getKernelSpace() *AddressSpace {
    return &kernel_space;
}

/// Create a new user address space (clones kernel mappings)
pub fn createUserSpace() ?AddressSpace {
    var space = AddressSpace.create() orelse return null;
    space.cloneKernelMappings(&kernel_space);
    return space;
}

/// Map a range of pages
pub fn mapRange(space: *AddressSpace, virt_start: u64, phys_start: u64, num_pages: u64, flags: MapFlags) bool {
    var i: u64 = 0;
    while (i < num_pages) : (i += 1) {
        const virt = virt_start + i * PAGE_SIZE;
        const phys = phys_start + i * PAGE_SIZE;
        if (!space.mapPage(virt, phys, flags)) {
            // Rollback on failure
            while (i > 0) : (i -= 1) {
                _ = space.unmapPage(virt_start + (i - 1) * PAGE_SIZE);
            }
            return false;
        }
    }
    return true;
}

/// Unmap a range of pages
pub fn unmapRange(space: *AddressSpace, virt_start: u64, num_pages: u64) void {
    var i: u64 = 0;
    while (i < num_pages) : (i += 1) {
        _ = space.unmapPage(virt_start + i * PAGE_SIZE);
    }
}

/// Allocate and map pages (virtual allocation)
pub fn allocPages(space: *AddressSpace, virt_start: u64, num_pages: u64, flags: MapFlags) bool {
    var i: u64 = 0;
    while (i < num_pages) : (i += 1) {
        const phys = pmm.allocPage() orelse {
            // Free already allocated pages
            while (i > 0) : (i -= 1) {
                const virt = virt_start + (i - 1) * PAGE_SIZE;
                if (space.translate(virt)) |p| {
                    pmm.freePage(p & paging.Flags.ADDR_MASK);
                }
                _ = space.unmapPage(virt);
            }
            return false;
        };

        const virt = virt_start + i * PAGE_SIZE;
        if (!space.mapPage(virt, phys, flags)) {
            pmm.freePage(phys);
            // Rollback
            while (i > 0) : (i -= 1) {
                const v = virt_start + (i - 1) * PAGE_SIZE;
                if (space.translate(v)) |p| {
                    pmm.freePage(p & paging.Flags.ADDR_MASK);
                }
                _ = space.unmapPage(v);
            }
            return false;
        }

        // Zero the page
        const page: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
        for (0..PAGE_SIZE) |j| {
            page[j] = 0;
        }
    }
    return true;
}
