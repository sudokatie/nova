// Interrupt Descriptor Table (IDT)
//
// Sets up interrupt and exception handlers for x86-64.
// 256 entries covering CPU exceptions, IRQs, and software interrupts.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");
const panic = @import("../../lib/panic.zig");

// IDT Entry (16 bytes in long mode)
const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8, // bits 0-2 = IST index, bits 3-7 = reserved
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

// Gate types
const GATE_INTERRUPT: u8 = 0x8E; // Present, DPL=0, Interrupt Gate
const GATE_TRAP: u8 = 0x8F; // Present, DPL=0, Trap Gate

// Exception vectors
pub const EXCEPTION_DIVIDE: u8 = 0;
pub const EXCEPTION_DEBUG: u8 = 1;
pub const EXCEPTION_NMI: u8 = 2;
pub const EXCEPTION_BREAKPOINT: u8 = 3;
pub const EXCEPTION_OVERFLOW: u8 = 4;
pub const EXCEPTION_BOUND: u8 = 5;
pub const EXCEPTION_INVALID_OP: u8 = 6;
pub const EXCEPTION_NO_DEVICE: u8 = 7;
pub const EXCEPTION_DOUBLE_FAULT: u8 = 8;
pub const EXCEPTION_INVALID_TSS: u8 = 10;
pub const EXCEPTION_NO_SEGMENT: u8 = 11;
pub const EXCEPTION_STACK_FAULT: u8 = 12;
pub const EXCEPTION_GPF: u8 = 13;
pub const EXCEPTION_PAGE_FAULT: u8 = 14;

// IRQ vectors (remapped to 32-47)
pub const IRQ_BASE: u8 = 32;
pub const IRQ_TIMER: u8 = IRQ_BASE + 0;
pub const IRQ_KEYBOARD: u8 = IRQ_BASE + 1;

// IDT with 256 entries
var idt: [256]IDTEntry align(16) = [_]IDTEntry{.{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .type_attr = 0,
    .offset_mid = 0,
    .offset_high = 0,
}} ** 256;

var idtr: cpu.IDTPointer align(16) = undefined;

/// Create an IDT entry
fn createEntry(handler: u64, selector: u16, ist: u3, gate_type: u8) IDTEntry {
    return .{
        .offset_low = @truncate(handler),
        .selector = selector,
        .ist = ist,
        .type_attr = gate_type,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

/// Initialize the IDT
pub fn init() void {
    // For now, we don't set up actual interrupt handlers
    // The Limine bootloader has set up basic IDT that will triple-fault on exceptions
    // This is fine for early boot - we just need to not trigger exceptions

    // Load our IDT structure (empty for now)
    idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    // Don't load IDT yet - keep using Limine's
    // cpu.loadIDT(@intFromPtr(&idtr));
}

/// Set a handler in the IDT (for future use)
pub fn setHandler(vector: u8, handler: u64, gate_type: u8) void {
    idt[vector] = createEntry(handler, 0x08, 0, gate_type);
}

// Exception names for debugging
pub const exception_names = [_][]const u8{
    "Divide Error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound Range",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment",
    "Invalid TSS",
    "Segment Not Present",
    "Stack Fault",
    "General Protection",
    "Page Fault",
    "Reserved",
    "x87 FP Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD FP Exception",
};

/// Print exception info (called from assembly stubs)
pub fn printException(vector: u64, error_code: u64, rip: u64, rsp: u64) void {
    console.println("", .{});
    console.println("========================================", .{});
    console.println("        !!! CPU EXCEPTION !!!", .{});
    console.println("========================================", .{});

    if (vector < exception_names.len) {
        console.println("Exception: {} ({})", .{ exception_names[vector], vector });
    } else {
        console.println("Exception: Unknown ({})", .{vector});
    }

    console.println("Error Code: {x}", .{error_code});
    console.println("RIP: {x}", .{rip});
    console.println("RSP: {x}", .{rsp});

    // Page fault specific info
    if (vector == 14) {
        const cr2 = cpu.readCR2();
        console.println("CR2 (fault addr): {x}", .{cr2});
    }

    panic.halt();
}
