// Global Descriptor Table (GDT)
//
// Sets up segment descriptors for x86-64 long mode.
// In long mode, most segmentation is ignored, but GDT is still required.

const cpu = @import("cpu.zig");

// GDT Entry (8 bytes)
const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8,
    base_high: u8,
};

// System Segment Descriptor (16 bytes) - for TSS
const SystemDescriptor = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

// Task State Segment (TSS)
pub const TSS = packed struct {
    reserved0: u32 = 0,
    // Stack pointers for privilege level changes
    rsp0: u64 = 0, // Ring 0 stack
    rsp1: u64 = 0, // Ring 1 stack
    rsp2: u64 = 0, // Ring 2 stack
    reserved1: u64 = 0,
    // Interrupt Stack Table
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = @sizeOf(TSS),
};

// GDT layout:
// 0: Null descriptor
// 1: Kernel code (64-bit)
// 2: Kernel data
// 3: User code (64-bit)
// 4: User data
// 5-6: TSS (16 bytes)

const GDT_ENTRIES = 7; // 5 regular + 2 for TSS

var gdt: [GDT_ENTRIES]GDTEntry align(8) = undefined;
var tss: TSS = .{};
var gdtr: cpu.GDTPointer = undefined;

// Access byte flags
const ACCESS_PRESENT: u8 = 0x80;
const ACCESS_DPL_RING0: u8 = 0x00;
const ACCESS_DPL_RING3: u8 = 0x60;
const ACCESS_SEGMENT: u8 = 0x10;
const ACCESS_EXECUTABLE: u8 = 0x08;
const ACCESS_RW: u8 = 0x02;
const ACCESS_ACCESSED: u8 = 0x01;

// TSS access
const ACCESS_TSS_AVAILABLE: u8 = 0x89;

// Flags
const FLAG_GRANULARITY: u8 = 0x80;
const FLAG_SIZE_32: u8 = 0x40;
const FLAG_LONG_MODE: u8 = 0x20;

/// Create a GDT entry
fn createEntry(base: u32, limit: u20, access: u8, flags: u8) GDTEntry {
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .flags_limit_high = (@as(u8, flags) & 0xF0) | (@as(u8, @truncate(limit >> 16)) & 0x0F),
        .base_high = @truncate(base >> 24),
    };
}

/// Initialize the GDT
pub fn init() void {
    // Null descriptor
    gdt[0] = createEntry(0, 0, 0, 0);

    // Kernel code segment (selector 0x08)
    gdt[1] = createEntry(
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_DPL_RING0 | ACCESS_SEGMENT | ACCESS_EXECUTABLE | ACCESS_RW,
        FLAG_GRANULARITY | FLAG_LONG_MODE,
    );

    // Kernel data segment (selector 0x10)
    gdt[2] = createEntry(
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_DPL_RING0 | ACCESS_SEGMENT | ACCESS_RW,
        FLAG_GRANULARITY | FLAG_SIZE_32,
    );

    // User code segment (selector 0x18 | 3 = 0x1B)
    gdt[3] = createEntry(
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_DPL_RING3 | ACCESS_SEGMENT | ACCESS_EXECUTABLE | ACCESS_RW,
        FLAG_GRANULARITY | FLAG_LONG_MODE,
    );

    // User data segment (selector 0x20 | 3 = 0x23)
    gdt[4] = createEntry(
        0,
        0xFFFFF,
        ACCESS_PRESENT | ACCESS_DPL_RING3 | ACCESS_SEGMENT | ACCESS_RW,
        FLAG_GRANULARITY | FLAG_SIZE_32,
    );

    // TSS descriptor (selector 0x28)
    setTSSDescriptor();

    // Load GDT
    gdtr = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    cpu.loadGDT(&gdtr);

    // Reload segments
    reloadSegments();
}

/// Set up the TSS descriptor in the GDT
fn setTSSDescriptor() void {
    const tss_addr = @intFromPtr(&tss);
    const tss_size = @sizeOf(TSS) - 1;

    // TSS is a 16-byte system descriptor in long mode
    // We treat gdt[5] and gdt[6] as a single SystemDescriptor
    const sys_desc: *SystemDescriptor = @ptrCast(&gdt[5]);
    sys_desc.* = .{
        .limit_low = @truncate(tss_size),
        .base_low = @truncate(tss_addr),
        .base_mid = @truncate(tss_addr >> 16),
        .access = ACCESS_TSS_AVAILABLE,
        .flags_limit_high = @truncate(tss_size >> 16),
        .base_high = @truncate(tss_addr >> 24),
        .base_upper = @truncate(tss_addr >> 32),
        .reserved = 0,
    };
}

/// Reload segment registers after loading GDT
fn reloadSegments() void {
    // Reload CS via far jump
    asm volatile (
        \\push $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
    );

    // Reload data segments
    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
    );
}

/// Load the Task Register with TSS selector
pub fn loadTSS() void {
    cpu.loadTR(0x28);
}

/// Set the kernel stack pointer in TSS (for syscall/interrupt returns)
pub fn setKernelStack(stack: u64) void {
    tss.rsp0 = stack;
}

/// Set an IST entry (for dedicated interrupt stacks)
pub fn setIST(ist: u3, stack: u64) void {
    switch (ist) {
        1 => tss.ist1 = stack,
        2 => tss.ist2 = stack,
        3 => tss.ist3 = stack,
        4 => tss.ist4 = stack,
        5 => tss.ist5 = stack,
        6 => tss.ist6 = stack,
        7 => tss.ist7 = stack,
        else => {},
    }
}
