// ELF64 Loader
//
// Parses and loads ELF64 executables into process address space.

const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const console = @import("../lib/console.zig");

// ELF magic number
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

// ELF class (32 vs 64 bit)
const ELFCLASS64: u8 = 2;

// ELF data encoding
const ELFDATA2LSB: u8 = 1; // Little endian

// ELF machine types
const EM_X86_64: u16 = 62;

// ELF types
const ET_EXEC: u16 = 2; // Executable
const ET_DYN: u16 = 3; // Shared object (PIE)

// Program header types
const PT_NULL: u32 = 0;
const PT_LOAD: u32 = 1;
const PT_DYNAMIC: u32 = 2;
const PT_INTERP: u32 = 3;
const PT_NOTE: u32 = 4;
const PT_PHDR: u32 = 6;

// Program header flags
const PF_X: u32 = 1; // Execute
const PF_W: u32 = 2; // Write
const PF_R: u32 = 4; // Read

// Page size
const PAGE_SIZE: u64 = 4096;

// Default user stack location (below kernel space)
const USER_STACK_TOP: u64 = 0x7FFFFFFFE000;
const USER_STACK_SIZE: u64 = 8 * PAGE_SIZE; // 32KB

/// ELF64 file header
pub const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

/// ELF64 program header
pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

/// ELF load result
pub const LoadResult = struct {
    entry_point: u64,
    stack_pointer: u64,
};

/// Load error types
pub const LoadError = error{
    InvalidMagic,
    InvalidClass,
    InvalidMachine,
    InvalidType,
    LoadFailed,
    StackAllocFailed,
};

/// Validate ELF header
pub fn validateHeader(header: *const Elf64Header) LoadError!void {
    // Check magic
    if (header.e_ident[0] != ELF_MAGIC[0] or
        header.e_ident[1] != ELF_MAGIC[1] or
        header.e_ident[2] != ELF_MAGIC[2] or
        header.e_ident[3] != ELF_MAGIC[3])
    {
        return LoadError.InvalidMagic;
    }

    // Check class (64-bit)
    if (header.e_ident[4] != ELFCLASS64) {
        return LoadError.InvalidClass;
    }

    // Check machine (x86_64)
    if (header.e_machine != EM_X86_64) {
        return LoadError.InvalidMachine;
    }

    // Check type (executable or PIE)
    if (header.e_type != ET_EXEC and header.e_type != ET_DYN) {
        return LoadError.InvalidType;
    }
}

/// Load an ELF binary into an address space
pub fn load(data: []const u8, space: *vmm.AddressSpace) LoadError!LoadResult {
    if (data.len < @sizeOf(Elf64Header)) {
        return LoadError.InvalidMagic;
    }

    // Parse header
    const header: *const Elf64Header = @ptrCast(@alignCast(data.ptr));
    try validateHeader(header);

    console.log(.debug, "ELF: Loading binary, entry={x}", .{header.e_entry});

    // Load program headers
    const phdr_offset = header.e_phoff;
    const phdr_size = header.e_phentsize;
    const phdr_count = header.e_phnum;

    var i: u16 = 0;
    while (i < phdr_count) : (i += 1) {
        const offset = phdr_offset + @as(u64, i) * phdr_size;
        if (offset + @sizeOf(Elf64Phdr) > data.len) {
            continue;
        }

        const phdr: *const Elf64Phdr = @ptrCast(@alignCast(data.ptr + offset));

        if (phdr.p_type == PT_LOAD) {
            try loadSegment(data, phdr, space);
        }
    }

    // Set up user stack
    const stack_base = USER_STACK_TOP - USER_STACK_SIZE;
    const stack_pages = USER_STACK_SIZE / PAGE_SIZE;

    const stack_flags = vmm.MapFlags{ .writable = true, .user = true };
    if (!vmm.allocPages(space, stack_base, stack_pages, stack_flags)) {
        return LoadError.StackAllocFailed;
    }

    console.log(.debug, "ELF: Stack at {x}-{x}", .{ stack_base, USER_STACK_TOP });

    return LoadResult{
        .entry_point = header.e_entry,
        .stack_pointer = USER_STACK_TOP - 8, // Leave space for alignment
    };
}

/// Load a single PT_LOAD segment
fn loadSegment(data: []const u8, phdr: *const Elf64Phdr, space: *vmm.AddressSpace) LoadError!void {
    const vaddr = phdr.p_vaddr;
    const memsz = phdr.p_memsz;
    const filesz = phdr.p_filesz;
    const offset = phdr.p_offset;

    // Calculate page-aligned addresses
    const page_start = vaddr & ~@as(u64, PAGE_SIZE - 1);
    const page_end = (vaddr + memsz + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
    const num_pages = (page_end - page_start) / PAGE_SIZE;

    console.log(.debug, "ELF: Loading segment {x}-{x} ({} pages)", .{ vaddr, vaddr + memsz, num_pages });

    // Set up flags based on segment permissions
    var flags = vmm.MapFlags{ .user = true };
    if ((phdr.p_flags & PF_W) != 0) {
        flags.writable = true;
    }
    if ((phdr.p_flags & PF_X) == 0) {
        flags.no_execute = true;
    }

    // Allocate pages
    if (!vmm.allocPages(space, page_start, num_pages, flags)) {
        return LoadError.LoadFailed;
    }

    // Copy data from file
    if (filesz > 0 and offset + filesz <= data.len) {
        const src = data[offset..][0..filesz];
        const dst: [*]u8 = @ptrFromInt(pmm.physToVirt(space.translate(vaddr) orelse return LoadError.LoadFailed));

        for (0..filesz) |j| {
            dst[j] = src[j];
        }
    }

    // Zero BSS (memsz > filesz)
    if (memsz > filesz) {
        const bss_start = vaddr + filesz;
        const bss_size = memsz - filesz;

        // Zero the BSS region
        const dst: [*]u8 = @ptrFromInt(pmm.physToVirt(space.translate(bss_start) orelse return LoadError.LoadFailed));
        for (0..bss_size) |j| {
            dst[j] = 0;
        }
    }
}

/// Get segment flags as string (for debugging)
pub fn flagsToString(flags: u32) []const u8 {
    if ((flags & PF_R) != 0 and (flags & PF_W) != 0 and (flags & PF_X) != 0) return "RWX";
    if ((flags & PF_R) != 0 and (flags & PF_W) != 0) return "RW-";
    if ((flags & PF_R) != 0 and (flags & PF_X) != 0) return "R-X";
    if ((flags & PF_R) != 0) return "R--";
    if ((flags & PF_W) != 0) return "-W-";
    if ((flags & PF_X) != 0) return "--X";
    return "---";
}
