// Interrupt Descriptor Table (IDT)
//
// Sets up interrupt and exception handlers for x86-64.
// 256 entries covering CPU exceptions, IRQs, and software interrupts.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");
const panic = @import("../../lib/panic.zig");
const vmm = @import("../../mm/vmm.zig");
const scheduler = @import("../../proc/scheduler.zig");
const apic = @import("apic.zig");

// IDT Entry (16 bytes in long mode)
const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

// Gate types
const GATE_INTERRUPT: u8 = 0x8E; // Present, DPL=0, Interrupt Gate
const GATE_TRAP: u8 = 0x8F; // Present, DPL=0, Trap Gate
const GATE_USER: u8 = 0xEE; // Present, DPL=3, Interrupt Gate

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
var initialized: bool = false;

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

/// Initialize the IDT with handlers
pub fn init() void {
    // Set up exception handlers
    setHandler(EXCEPTION_DIVIDE, @intFromPtr(&handleDivideError), GATE_TRAP);
    setHandler(EXCEPTION_DEBUG, @intFromPtr(&handleDebug), GATE_TRAP);
    setHandler(EXCEPTION_NMI, @intFromPtr(&handleNMI), GATE_INTERRUPT);
    setHandler(EXCEPTION_BREAKPOINT, @intFromPtr(&handleBreakpoint), GATE_TRAP);
    setHandler(EXCEPTION_OVERFLOW, @intFromPtr(&handleOverflow), GATE_TRAP);
    setHandler(EXCEPTION_BOUND, @intFromPtr(&handleBound), GATE_TRAP);
    setHandler(EXCEPTION_INVALID_OP, @intFromPtr(&handleInvalidOp), GATE_TRAP);
    setHandler(EXCEPTION_NO_DEVICE, @intFromPtr(&handleNoDevice), GATE_TRAP);
    setHandler(EXCEPTION_DOUBLE_FAULT, @intFromPtr(&handleDoubleFault), GATE_TRAP);
    setHandler(EXCEPTION_INVALID_TSS, @intFromPtr(&handleInvalidTSS), GATE_TRAP);
    setHandler(EXCEPTION_NO_SEGMENT, @intFromPtr(&handleNoSegment), GATE_TRAP);
    setHandler(EXCEPTION_STACK_FAULT, @intFromPtr(&handleStackFault), GATE_TRAP);
    setHandler(EXCEPTION_GPF, @intFromPtr(&handleGPF), GATE_TRAP);
    setHandler(EXCEPTION_PAGE_FAULT, @intFromPtr(&handlePageFault), GATE_TRAP);

    // Set up IRQ handlers
    setHandler(IRQ_TIMER, @intFromPtr(&handleTimer), GATE_INTERRUPT);
    setHandler(IRQ_KEYBOARD, @intFromPtr(&handleKeyboard), GATE_INTERRUPT);

    // Load IDT
    idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    cpu.loadIDT(&idtr);
    initialized = true;
    console.log(.info, "IDT initialized with {} entries", .{256});
}

/// Set a handler in the IDT
pub fn setHandler(vector: u8, handler: u64, gate_type: u8) void {
    idt[vector] = createEntry(handler, 0x08, 0, gate_type);
}

// ============= Exception Handlers =============

fn handleDivideError() callconv(.C) void {
    panic.panicFmt("Division by zero", .{});
}

fn handleDebug() callconv(.C) void {
    console.log(.debug, "Debug exception", .{});
}

fn handleNMI() callconv(.C) void {
    panic.panicFmt("Non-maskable interrupt", .{});
}

fn handleBreakpoint() callconv(.C) void {
    console.log(.debug, "Breakpoint hit", .{});
}

fn handleOverflow() callconv(.C) void {
    panic.panicFmt("Overflow exception", .{});
}

fn handleBound() callconv(.C) void {
    panic.panicFmt("Bound range exceeded", .{});
}

fn handleInvalidOp() callconv(.C) void {
    panic.panicFmt("Invalid opcode", .{});
}

fn handleNoDevice() callconv(.C) void {
    panic.panicFmt("Device not available", .{});
}

fn handleDoubleFault() callconv(.C) void {
    panic.panicFmt("Double fault", .{});
}

fn handleInvalidTSS() callconv(.C) void {
    panic.panicFmt("Invalid TSS", .{});
}

fn handleNoSegment() callconv(.C) void {
    panic.panicFmt("Segment not present", .{});
}

fn handleStackFault() callconv(.C) void {
    panic.panicFmt("Stack segment fault", .{});
}

fn handleGPF() callconv(.C) void {
    panic.panicFmt("General protection fault", .{});
}

/// Page fault handler - handles COW and demand paging
fn handlePageFault() callconv(.C) void {
    const fault_addr = cpu.readCR2();
    // Error code would be on stack - simplified for now
    const error_code: u64 = 0;

    // Try to handle via VMM (COW or demand paging)
    if (vmm.handlePageFault(fault_addr, error_code)) {
        // Successfully handled
        return;
    }

    // Unhandled page fault
    console.println("", .{});
    console.println("========================================", .{});
    console.println("        !!! PAGE FAULT !!!", .{});
    console.println("========================================", .{});
    console.println("Fault address: {x}", .{fault_addr});
    console.println("Error code: {x}", .{error_code});
    panic.halt();
}

// ============= IRQ Handlers =============

/// Timer interrupt handler
fn handleTimer() callconv(.C) void {
    // Acknowledge interrupt
    apic.eoi();

    // Tick the scheduler
    scheduler.tick();

    // Wake sleeping threads
    wakeExpiredSleepers();
}

/// Keyboard interrupt handler
fn handleKeyboard() callconv(.C) void {
    const keyboard = @import("../../drivers/keyboard.zig");
    keyboard.handleInterrupt();
    apic.eoi();
}

// ============= Sleep Support =============

const timer = @import("../../drivers/timer.zig");
const thread_mod = @import("../../proc/thread.zig");

/// Wake threads whose sleep timer has expired
fn wakeExpiredSleepers() void {
    const current_ticks = timer.getTicks();

    // Check all threads for expired sleep timers
    var tid: u32 = 0;
    while (tid < 512) : (tid += 1) {
        if (thread_mod.get(tid)) |thread| {
            if (thread.state == .sleeping and thread.sleep_until <= current_ticks) {
                scheduler.unblock(thread);
            }
        }
    }
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

/// Print exception info (for debugging)
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

    if (vector == 14) {
        const cr2 = cpu.readCR2();
        console.println("CR2 (fault addr): {x}", .{cr2});
    }

    panic.halt();
}

/// Check if IDT is initialized
pub fn isInitialized() bool {
    return initialized;
}
