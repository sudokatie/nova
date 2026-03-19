// x86_64 Page Table Management
//
// 4-level paging: PML4 -> PDPT -> PD -> PT -> Page
// Each table is 512 entries * 8 bytes = 4KB

const pmm = @import("../../mm/pmm.zig");

pub const PAGE_SIZE: u64 = 4096;

/// Page table entry flags
pub const Flags = struct {
    pub const PRESENT: u64 = 1 << 0;
    pub const WRITABLE: u64 = 1 << 1;
    pub const USER: u64 = 1 << 2;
    pub const WRITE_THROUGH: u64 = 1 << 3;
    pub const CACHE_DISABLE: u64 = 1 << 4;
    pub const ACCESSED: u64 = 1 << 5;
    pub const DIRTY: u64 = 1 << 6;
    pub const HUGE_PAGE: u64 = 1 << 7; // 2MB page in PD, 1GB in PDPT
    pub const GLOBAL: u64 = 1 << 8;
    pub const NO_EXECUTE: u64 = 1 << 63;

    // Address mask (bits 12-51 for physical address)
    pub const ADDR_MASK: u64 = 0x000FFFFFFFFFF000;
};

/// A page table entry (PTE, PDE, PDPTE, or PML4E)
pub const Entry = packed struct {
    value: u64,

    pub fn init(phys_addr: u64, flags: u64) Entry {
        return .{ .value = (phys_addr & Flags.ADDR_MASK) | flags };
    }

    pub fn empty() Entry {
        return .{ .value = 0 };
    }

    pub fn isPresent(self: Entry) bool {
        return (self.value & Flags.PRESENT) != 0;
    }

    pub fn isWritable(self: Entry) bool {
        return (self.value & Flags.WRITABLE) != 0;
    }

    pub fn isUser(self: Entry) bool {
        return (self.value & Flags.USER) != 0;
    }

    pub fn isHuge(self: Entry) bool {
        return (self.value & Flags.HUGE_PAGE) != 0;
    }

    pub fn getPhysAddr(self: Entry) u64 {
        return self.value & Flags.ADDR_MASK;
    }

    pub fn setFlags(self: *Entry, flags: u64) void {
        self.value |= flags;
    }

    pub fn clearFlags(self: *Entry, flags: u64) void {
        self.value &= ~flags;
    }
};

/// A page table (512 entries)
pub const Table = struct {
    entries: [512]Entry,

    pub fn init() Table {
        return .{ .entries = [_]Entry{Entry.empty()} ** 512 };
    }

    pub fn getEntry(self: *Table, index: u9) *Entry {
        return &self.entries[index];
    }
};

/// Extract table indices from a virtual address
pub fn getIndices(virt_addr: u64) struct { pml4: u9, pdpt: u9, pd: u9, pt: u9, offset: u12 } {
    return .{
        .pml4 = @truncate((virt_addr >> 39) & 0x1FF),
        .pdpt = @truncate((virt_addr >> 30) & 0x1FF),
        .pd = @truncate((virt_addr >> 21) & 0x1FF),
        .pt = @truncate((virt_addr >> 12) & 0x1FF),
        .offset = @truncate(virt_addr & 0xFFF),
    };
}

/// Invalidate a single TLB entry
pub fn invlpg(virt_addr: u64) void {
    const ptr: *const u8 = @ptrFromInt(virt_addr);
    asm volatile ("invlpg %[addr]"
        :
        : [addr] "m" (ptr.*),
    );
}

/// Flush entire TLB by reloading CR3
pub fn flushTlb() void {
    const cr3 = getCr3();
    setCr3(cr3);
}

/// Get current CR3 (PML4 physical address)
pub fn getCr3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Set CR3 (switch address space)
pub fn setCr3(pml4_phys: u64) void {
    asm volatile ("mov %[val], %%cr3"
        :
        : [val] "r" (pml4_phys),
    );
}

/// Check if NX bit is available
pub fn isNxSupported() bool {
    // Check CPUID for NX support (CPUID.80000001:EDX bit 20)
    // Use extended function 0x80000001 to check for NX bit
    const result = cpuid(0x80000001);
    return (result.edx & (1 << 20)) != 0;
}

pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

pub fn cpuid(leaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [in_eax] "{eax}" (leaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Enable NX bit in EFER MSR
pub fn enableNx() void {
    const EFER_MSR: u32 = 0xC0000080;
    const NXE_BIT: u64 = 1 << 11;

    // Read EFER
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (EFER_MSR),
    );

    const efer = ((@as(u64, high) << 32) | low) | NXE_BIT;

    // Write EFER
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (EFER_MSR),
          [low] "{eax}" (@as(u32, @truncate(efer))),
          [high] "{edx}" (@as(u32, @truncate(efer >> 32))),
    );
}
