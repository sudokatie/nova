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

// ============= Copy-on-Write Support =============

/// Page reference counts for COW
const MAX_COW_PAGES: usize = 16384;
var cow_refcounts: [MAX_COW_PAGES]u16 = [_]u16{0} ** MAX_COW_PAGES;

/// Get COW index for a physical page
fn cowIndex(phys: u64) ?usize {
    const page_num = phys / PAGE_SIZE;
    if (page_num < MAX_COW_PAGES) {
        return @intCast(page_num);
    }
    return null;
}

/// Increment COW reference count
pub fn cowRef(phys: u64) void {
    if (cowIndex(phys)) |idx| {
        if (cow_refcounts[idx] < 65535) {
            cow_refcounts[idx] += 1;
        }
    }
}

/// Decrement COW reference count
pub fn cowUnref(phys: u64) void {
    if (cowIndex(phys)) |idx| {
        if (cow_refcounts[idx] > 0) {
            cow_refcounts[idx] -= 1;
        }
    }
}

/// Get COW reference count
pub fn cowCount(phys: u64) u16 {
    if (cowIndex(phys)) |idx| {
        return cow_refcounts[idx];
    }
    return 0;
}

/// Check if page is COW (shared and read-only)
pub fn isCowPage(space: *AddressSpace, virt: u64) bool {
    if (space.translate(virt)) |phys| {
        // Check if mapped read-only and has multiple refs
        const indices = paging.getIndices(virt);
        const pml4: *paging.Table = @ptrFromInt(pmm.physToVirt(space.pml4_phys));
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

        // COW page: present, not writable, has COW bit set
        if (pte.isPresent() and !pte.isWritable()) {
            return cowCount(phys) > 1;
        }
    }
    return false;
}

/// Handle COW page fault - copy page and make it writable
pub fn handleCowFault(space: *AddressSpace, virt: u64) bool {
    const old_phys = space.translate(virt) orelse return false;

    // Allocate new page
    const new_phys = pmm.allocPage() orelse return false;

    // Copy contents
    const src: [*]const u8 = @ptrFromInt(pmm.physToVirt(old_phys));
    const dst: [*]u8 = @ptrFromInt(pmm.physToVirt(new_phys));
    for (0..PAGE_SIZE) |i| {
        dst[i] = src[i];
    }

    // Unmap old, map new with write permissions
    _ = space.unmapPage(virt);
    const flags = MapFlags{ .writable = true, .user = true };
    if (!space.mapPage(virt, new_phys, flags)) {
        pmm.freePage(new_phys);
        return false;
    }

    // Decrement ref count on old page
    cowUnref(old_phys);

    // Free old page if no more references
    if (cowCount(old_phys) == 0) {
        pmm.freePage(old_phys);
    }

    console.log(.debug, "VMM: COW fault handled at {x}", .{virt});
    return true;
}

/// Fork an address space (COW copy)
pub fn forkAddressSpace(dst: *AddressSpace, src: *AddressSpace) bool {
    // Copy user space pages as COW (entries 0-255 in PML4)
    const src_pml4: *paging.Table = @ptrFromInt(pmm.physToVirt(src.pml4_phys));

    for (0..256) |pml4_idx| {
        const pml4e = src_pml4.getEntry(@intCast(pml4_idx));
        if (!pml4e.isPresent()) continue;

        // Walk PDPT
        const pdpt: *paging.Table = @ptrFromInt(pmm.physToVirt(pml4e.getPhysAddr()));
        for (0..512) |pdpt_idx| {
            const pdpte = pdpt.getEntry(@intCast(pdpt_idx));
            if (!pdpte.isPresent()) continue;

            // Walk PD
            const pd: *paging.Table = @ptrFromInt(pmm.physToVirt(pdpte.getPhysAddr()));
            for (0..512) |pd_idx| {
                const pde = pd.getEntry(@intCast(pd_idx));
                if (!pde.isPresent()) continue;

                // Walk PT
                const pt: *paging.Table = @ptrFromInt(pmm.physToVirt(pde.getPhysAddr()));
                for (0..512) |pt_idx| {
                    const pte = pt.getEntry(@intCast(pt_idx));
                    if (!pte.isPresent()) continue;

                    const phys = pte.getPhysAddr();
                    const virt = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_idx) << 30) |
                        (@as(u64, pd_idx) << 21) |
                        (@as(u64, pt_idx) << 12);

                    // Mark both source and dest as read-only (COW)
                    const cow_flags = MapFlags{ .writable = false, .user = true };

                    // Remove write permission from source
                    _ = src.unmapPage(virt);
                    _ = src.mapPage(virt, phys, cow_flags);

                    // Map same page in dest as read-only
                    _ = dst.mapPage(virt, phys, cow_flags);

                    // Increment reference count
                    cowRef(phys);
                    cowRef(phys); // Once for each mapping
                }
            }
        }
    }

    // Copy kernel mappings (not COW - shared directly)
    dst.cloneKernelMappings(src);

    console.log(.debug, "VMM: Address space forked with COW", .{});
    return true;
}

// ============= Demand Paging Support =============

/// Demand page tracking - pages that should be allocated on first access
const MAX_DEMAND_REGIONS: usize = 64;

pub const DemandRegion = struct {
    start: u64,
    end: u64,
    flags: MapFlags,
    active: bool,

    pub fn init() DemandRegion {
        return .{ .start = 0, .end = 0, .flags = .{}, .active = false };
    }
};

var demand_regions: [MAX_DEMAND_REGIONS]DemandRegion = [_]DemandRegion{DemandRegion.init()} ** MAX_DEMAND_REGIONS;

/// Register a demand-paged region
pub fn registerDemandRegion(start: u64, size: u64, flags: MapFlags) bool {
    for (&demand_regions) |*r| {
        if (!r.active) {
            r.start = start;
            r.end = start + size;
            r.flags = flags;
            r.active = true;
            return true;
        }
    }
    return false;
}

/// Check if address is in a demand-paged region
pub fn getDemandRegion(addr: u64) ?*DemandRegion {
    for (&demand_regions) |*r| {
        if (r.active and addr >= r.start and addr < r.end) {
            return r;
        }
    }
    return null;
}

/// Handle demand page fault - allocate page on first access
pub fn handleDemandFault(space: *AddressSpace, fault_addr: u64) bool {
    const region = getDemandRegion(fault_addr) orelse return false;

    const page_addr = fault_addr & ~@as(u64, PAGE_SIZE - 1);

    // Allocate and map the page
    const phys = pmm.allocPage() orelse return false;

    if (!space.mapPage(page_addr, phys, region.flags)) {
        pmm.freePage(phys);
        return false;
    }

    // Zero the new page
    const page: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
    for (0..PAGE_SIZE) |i| {
        page[i] = 0;
    }

    console.log(.debug, "VMM: Demand fault handled at {x}", .{fault_addr});
    return true;
}

/// Handle page fault (entry point from IDT)
pub fn handlePageFault(fault_addr: u64, error_code: u64) bool {
    const space = getKernelSpace(); // TODO: get current process space

    // Error code bits:
    // bit 0: present (1 = protection violation, 0 = not present)
    // bit 1: write (1 = write, 0 = read)
    // bit 2: user (1 = user mode, 0 = supervisor)
    const is_present = (error_code & 1) != 0;
    const is_write = (error_code & 2) != 0;

    if (is_present and is_write) {
        // Write to read-only page - might be COW
        if (isCowPage(space, fault_addr)) {
            return handleCowFault(space, fault_addr);
        }
    } else if (!is_present) {
        // Page not present - might be demand paging
        if (getDemandRegion(fault_addr) != null) {
            return handleDemandFault(space, fault_addr);
        }
    }

    // Unhandled fault
    console.log(.err, "VMM: Unhandled page fault at {x}, error={x}", .{ fault_addr, error_code });
    return false;
}
