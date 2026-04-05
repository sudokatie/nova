// Global Descriptor Table (GDT)
//
// Sets up segmentation for x86-64 long mode.
// Includes TSS for interrupt stack switching.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");
const pmm = @import("../../mm/pmm.zig");

// Segment selectors
pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x18 | 3; // Ring 3
pub const USER_DS: u16 = 0x20 | 3; // Ring 3
pub const TSS_SEL: u16 = 0x28;

// GDT Entry (8 bytes for regular, 16 bytes for TSS)
const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8,
    base_high: u8,

    pub fn init(base: u32, limit: u20, access: u8, flags: u4) GDTEntry {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_mid = @truncate(base >> 16),
            .access = access,
            .flags_limit_high = (@as(u8, flags) << 4) | @as(u8, @truncate(limit >> 16)),
            .base_high = @truncate(base >> 24),
        };
    }

    pub fn null_entry() GDTEntry {
        return .{
            .limit_low = 0,
            .base_low = 0,
            .base_mid = 0,
            .access = 0,
            .flags_limit_high = 0,
            .base_high = 0,
        };
    }
};

// TSS Entry is 16 bytes (two GDT entries)
const TSSEntry = packed struct {
    length: u16,
    base_low: u16,
    base_mid: u8,
    flags1: u8,
    flags2: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,

    pub fn init(base: u64, limit: u16) TSSEntry {
        return .{
            .length = limit,
            .base_low = @truncate(base),
            .base_mid = @truncate(base >> 16),
            .flags1 = 0x89, // Present, 64-bit TSS available
            .flags2 = 0x00,
            .base_high = @truncate(base >> 24),
            .base_upper = @truncate(base >> 32),
            .reserved = 0,
        };
    }
};

// Task State Segment (TSS)
pub const TSS = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0, // Stack for ring 0 (kernel)
    rsp1: u64 = 0, // Stack for ring 1 (unused)
    rsp2: u64 = 0, // Stack for ring 2 (unused)
    reserved1: u64 = 0,
    ist1: u64 = 0, // Interrupt Stack Table 1 (double fault)
    ist2: u64 = 0, // IST 2 (NMI)
    ist3: u64 = 0, // IST 3 (machine check)
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(TSS), // No I/O permission bitmap
};

// GDT structure
const GDT = extern struct {
    null_entry: GDTEntry, // 0x00
    kernel_code: GDTEntry, // 0x08
    kernel_data: GDTEntry, // 0x10
    user_code: GDTEntry, // 0x18
    user_data: GDTEntry, // 0x20
    tss_low: GDTEntry, // 0x28 (TSS lower 8 bytes)
    tss_high: GDTEntry, // 0x30 (TSS upper 8 bytes)
};

// GDTR structure
const GDTPointer = packed struct {
    limit: u16,
    base: u64,
};

// Global instances
var gdt: GDT align(16) = undefined;
var gdtr: GDTPointer align(16) = undefined;
pub var tss: TSS align(16) = TSS{};

// Interrupt stacks (4KB each)
const IST_STACK_SIZE: usize = 4096;
var ist1_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var ist2_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var ist3_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var kernel_stack: [IST_STACK_SIZE * 2]u8 align(16) = undefined;

var initialized: bool = false;

/// Initialize the GDT
pub fn init() void {
    // Set up GDT entries
    // Access byte: P(1) DPL(2) S(1) Type(4)
    // Flags: G(1) D/B(1) L(1) AVL(1)

    // Null descriptor
    gdt.null_entry = GDTEntry.null_entry();

    // Kernel code segment (0x08)
    // Access: Present=1, DPL=0, S=1 (code/data), Type=0xA (exec/read)
    // Flags: G=1 (4KB), L=1 (long mode), D=0
    gdt.kernel_code = GDTEntry.init(0, 0xFFFFF, 0x9A, 0xA);

    // Kernel data segment (0x10)
    // Access: Present=1, DPL=0, S=1, Type=0x2 (read/write)
    // Flags: G=1, L=0, D/B=1 (32-bit)
    gdt.kernel_data = GDTEntry.init(0, 0xFFFFF, 0x92, 0xC);

    // User code segment (0x18)
    // Access: Present=1, DPL=3, S=1, Type=0xA
    gdt.user_code = GDTEntry.init(0, 0xFFFFF, 0xFA, 0xA);

    // User data segment (0x20)
    // Access: Present=1, DPL=3, S=1, Type=0x2
    gdt.user_data = GDTEntry.init(0, 0xFFFFF, 0xF2, 0xC);

    // Set up TSS
    tss.rsp0 = @intFromPtr(&kernel_stack) + kernel_stack.len;
    tss.ist1 = @intFromPtr(&ist1_stack) + IST_STACK_SIZE; // Double fault
    tss.ist2 = @intFromPtr(&ist2_stack) + IST_STACK_SIZE; // NMI
    tss.ist3 = @intFromPtr(&ist3_stack) + IST_STACK_SIZE; // Machine check

    // TSS descriptor (16 bytes split into two entries)
    const tss_addr = @intFromPtr(&tss);
    const tss_entry = TSSEntry.init(tss_addr, @sizeOf(TSS) - 1);

    // Copy TSS entry bytes into GDT
    const tss_bytes: *const [16]u8 = @ptrCast(&tss_entry);
    const gdt_tss_low: *[8]u8 = @ptrCast(&gdt.tss_low);
    const gdt_tss_high: *[8]u8 = @ptrCast(&gdt.tss_high);

    for (0..8) |i| {
        gdt_tss_low[i] = tss_bytes[i];
        gdt_tss_high[i] = tss_bytes[i + 8];
    }

    // Set up GDTR
    gdtr = .{
        .limit = @sizeOf(GDT) - 1,
        .base = @intFromPtr(&gdt),
    };

    // Load GDT
    loadGDT();

    // Load TSS
    loadTSS();

    initialized = true;
    console.log(.info, "GDT initialized with TSS", .{});
}

/// Load the GDT register
fn loadGDT() void {
    asm volatile (
        \\lgdt (%[gdtr])
        \\
        // Reload CS with far return
        \\pushq %[kernel_cs]
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        // Reload data segments
        \\movw %[kernel_ds], %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\movw %%ax, %%ss
        :
        : [gdtr] "r" (&gdtr),
          [kernel_cs] "i" (@as(u64, KERNEL_CS)),
          [kernel_ds] "i" (KERNEL_DS),
        : .{ .rax = true, .memory = true }
    );
}

/// Load the Task Register with TSS selector
fn loadTSS() void {
    asm volatile ("ltr %[tss_sel]"
        :
        : [tss_sel] "r" (TSS_SEL),
    );
}

/// Set kernel stack for ring transitions
pub fn setKernelStack(stack: u64) void {
    tss.rsp0 = stack;
}

/// Get kernel stack
pub fn getKernelStack() u64 {
    return tss.rsp0;
}

/// Check if GDT is initialized
pub fn isInitialized() bool {
    return initialized;
}
