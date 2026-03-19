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
const GATE_USER: u8 = 0xEE; // Present, DPL=3, Interrupt Gate (for syscalls)

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
pub const EXCEPTION_X87_FP: u8 = 16;
pub const EXCEPTION_ALIGNMENT: u8 = 17;
pub const EXCEPTION_MACHINE_CHECK: u8 = 18;
pub const EXCEPTION_SIMD_FP: u8 = 19;

// IRQ vectors (remapped to 32-47)
pub const IRQ_BASE: u8 = 32;
pub const IRQ_TIMER: u8 = IRQ_BASE + 0;
pub const IRQ_KEYBOARD: u8 = IRQ_BASE + 1;

// IDT with 256 entries
var idt: [256]IDTEntry = [_]IDTEntry{.{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .type_attr = 0,
    .offset_mid = 0,
    .offset_high = 0,
}} ** 256;

var idtr: cpu.IDTPointer = undefined;

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
    // Set up exception handlers (0-31)
    setHandler(0, &isr0, GATE_TRAP); // Divide Error
    setHandler(1, &isr1, GATE_TRAP); // Debug
    setHandler(2, &isr2, GATE_INTERRUPT); // NMI
    setHandler(3, &isr3, GATE_TRAP); // Breakpoint
    setHandler(4, &isr4, GATE_TRAP); // Overflow
    setHandler(5, &isr5, GATE_TRAP); // Bound Range
    setHandler(6, &isr6, GATE_TRAP); // Invalid Opcode
    setHandler(7, &isr7, GATE_TRAP); // Device Not Available
    setHandler(8, &isr8, GATE_TRAP); // Double Fault (should use IST)
    setHandler(10, &isr10, GATE_TRAP); // Invalid TSS
    setHandler(11, &isr11, GATE_TRAP); // Segment Not Present
    setHandler(12, &isr12, GATE_TRAP); // Stack Fault
    setHandler(13, &isr13, GATE_TRAP); // General Protection Fault
    setHandler(14, &isr14, GATE_TRAP); // Page Fault

    // Set up IRQ handlers (32-47)
    setHandler(32, &irq0, GATE_INTERRUPT); // Timer
    setHandler(33, &irq1, GATE_INTERRUPT); // Keyboard

    // Load IDT
    idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    cpu.loadIDT(&idtr);
}

/// Set a handler in the IDT
fn setHandler(vector: u8, handler: *const fn () callconv(.naked) void, gate_type: u8) void {
    idt[vector] = createEntry(@intFromPtr(handler), 0x08, 0, gate_type);
}

/// Register a custom handler (for drivers)
pub fn registerHandler(vector: u8, handler: *const fn () callconv(.naked) void) void {
    setHandler(vector, handler, GATE_INTERRUPT);
}

// Interrupt frame pushed by CPU
pub const InterruptFrame = extern struct {
    // Pushed by our stub
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // Interrupt number and error code
    int_no: u64,
    error_code: u64,
    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// Exception names for debugging
const exception_names = [_][]const u8{
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

/// Common exception handler
export fn exceptionHandler(frame: *InterruptFrame) void {
    const vec = frame.int_no;

    console.println("", .{});
    console.println("========================================", .{});
    console.println("        !!! CPU EXCEPTION !!!", .{});
    console.println("========================================", .{});

    if (vec < exception_names.len) {
        console.println("Exception: {} ({})", .{ exception_names[vec], vec });
    } else {
        console.println("Exception: Unknown ({})", .{vec});
    }

    console.println("Error Code: {x}", .{frame.error_code});
    console.println("", .{});
    console.println("Registers:", .{});
    console.println("  RIP: {x}  RSP: {x}", .{ frame.rip, frame.rsp });
    console.println("  RAX: {x}  RBX: {x}", .{ frame.rax, frame.rbx });
    console.println("  RCX: {x}  RDX: {x}", .{ frame.rcx, frame.rdx });
    console.println("  RSI: {x}  RDI: {x}", .{ frame.rsi, frame.rdi });
    console.println("  RBP: {x}", .{frame.rbp});
    console.println("  CS: {x}  SS: {x}  RFLAGS: {x}", .{ frame.cs, frame.ss, frame.rflags });

    // Page fault specific info
    if (vec == 14) {
        const cr2 = cpu.readCR2();
        console.println("  CR2 (fault addr): {x}", .{cr2});
    }

    panic.halt();
}

/// Common IRQ handler
export fn irqHandler(frame: *InterruptFrame) void {
    const irq = frame.int_no - IRQ_BASE;
    _ = irq;

    // TODO: Dispatch to registered handlers

    // Send EOI to APIC (will be implemented in apic.zig)
    // For now, just return
}

// ISR stubs - push interrupt number and jump to common handler
// Exceptions without error codes push a dummy 0
fn makeIsrStub(comptime n: u8, comptime has_error: bool) fn () callconv(.naked) void {
    return struct {
        fn handler() callconv(.naked) void {
            if (!has_error) {
                asm volatile ("push $0"); // Dummy error code
            }
            asm volatile ("push %[n]"
                :
                : [n] "i" (n),
            );
            asm volatile (
                \\push %%rax
                \\push %%rbx
                \\push %%rcx
                \\push %%rdx
                \\push %%rsi
                \\push %%rdi
                \\push %%rbp
                \\push %%r8
                \\push %%r9
                \\push %%r10
                \\push %%r11
                \\push %%r12
                \\push %%r13
                \\push %%r14
                \\push %%r15
                \\mov %%rsp, %%rdi
                \\call exceptionHandler
                \\pop %%r15
                \\pop %%r14
                \\pop %%r13
                \\pop %%r12
                \\pop %%r11
                \\pop %%r10
                \\pop %%r9
                \\pop %%r8
                \\pop %%rbp
                \\pop %%rdi
                \\pop %%rsi
                \\pop %%rdx
                \\pop %%rcx
                \\pop %%rbx
                \\pop %%rax
                \\add $16, %%rsp
                \\iretq
            );
        }
    }.handler;
}

fn makeIrqStub(comptime n: u8) fn () callconv(.naked) void {
    return struct {
        fn handler() callconv(.naked) void {
            asm volatile ("push $0"); // Dummy error code
            asm volatile ("push %[n]"
                :
                : [n] "i" (n),
            );
            asm volatile (
                \\push %%rax
                \\push %%rbx
                \\push %%rcx
                \\push %%rdx
                \\push %%rsi
                \\push %%rdi
                \\push %%rbp
                \\push %%r8
                \\push %%r9
                \\push %%r10
                \\push %%r11
                \\push %%r12
                \\push %%r13
                \\push %%r14
                \\push %%r15
                \\mov %%rsp, %%rdi
                \\call irqHandler
                \\pop %%r15
                \\pop %%r14
                \\pop %%r13
                \\pop %%r12
                \\pop %%r11
                \\pop %%r10
                \\pop %%r9
                \\pop %%r8
                \\pop %%rbp
                \\pop %%rdi
                \\pop %%rsi
                \\pop %%rdx
                \\pop %%rcx
                \\pop %%rbx
                \\pop %%rax
                \\add $16, %%rsp
                \\iretq
            );
        }
    }.handler;
}

// Exception stubs
const isr0 = makeIsrStub(0, false);
const isr1 = makeIsrStub(1, false);
const isr2 = makeIsrStub(2, false);
const isr3 = makeIsrStub(3, false);
const isr4 = makeIsrStub(4, false);
const isr5 = makeIsrStub(5, false);
const isr6 = makeIsrStub(6, false);
const isr7 = makeIsrStub(7, false);
const isr8 = makeIsrStub(8, true); // Double fault has error code
const isr10 = makeIsrStub(10, true); // Invalid TSS has error code
const isr11 = makeIsrStub(11, true); // Segment not present has error code
const isr12 = makeIsrStub(12, true); // Stack fault has error code
const isr13 = makeIsrStub(13, true); // GPF has error code
const isr14 = makeIsrStub(14, true); // Page fault has error code

// IRQ stubs
const irq0 = makeIrqStub(32);
const irq1 = makeIrqStub(33);
