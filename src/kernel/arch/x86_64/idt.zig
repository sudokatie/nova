// Interrupt Descriptor Table (IDT)
//
// Sets up interrupt and exception handlers for x86-64.
// Uses naked handlers with manual register save/restore since Zig 0.15's
// stage2 backend doesn't support x86_64_interrupt calling convention.

const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const console = @import("../../lib/console.zig");
const panic = @import("../../lib/panic.zig");
const vmm = @import("../../mm/vmm.zig");
const scheduler = @import("../../proc/scheduler.zig");
const apic = @import("apic.zig");

// IDT Entry (16 bytes in long mode)
const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8, // Bits 0-2: IST index, bits 3-7: reserved
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

// Gate types
const GATE_INTERRUPT: u8 = 0x8E; // Present, DPL=0, Interrupt Gate
const GATE_TRAP: u8 = 0x8F; // Present, DPL=0, Trap Gate
const GATE_USER: u8 = 0xEE; // Present, DPL=3, Interrupt Gate (for syscall)

// IST indices (must match GDT TSS setup)
const IST_DOUBLE_FAULT: u8 = 1;
const IST_NMI: u8 = 2;
const IST_MACHINE_CHECK: u8 = 3;

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
pub const EXCEPTION_COPROC_SEG: u8 = 9;
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
fn createEntry(handler: u64, selector: u16, ist: u8, gate_type: u8) IDTEntry {
    return .{
        .offset_low = @truncate(handler),
        .selector = selector,
        .ist = ist,
        .type_attr = gate_type,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

/// Set a handler in the IDT
pub fn setHandler(vector: u8, handler: u64, gate_type: u8) void {
    setHandlerWithIST(vector, handler, 0, gate_type);
}

/// Set a handler with specific IST
pub fn setHandlerWithIST(vector: u8, handler: u64, ist: u8, gate_type: u8) void {
    idt[vector] = createEntry(handler, gdt.KERNEL_CS, ist, gate_type);
}

/// Initialize the IDT with handlers
pub fn init() void {
    // CPU exceptions (0-31)
    setHandler(EXCEPTION_DIVIDE, @intFromPtr(&isr0), GATE_TRAP);
    setHandler(EXCEPTION_DEBUG, @intFromPtr(&isr1), GATE_TRAP);
    setHandlerWithIST(EXCEPTION_NMI, @intFromPtr(&isr2), IST_NMI, GATE_INTERRUPT);
    setHandler(EXCEPTION_BREAKPOINT, @intFromPtr(&isr3), GATE_TRAP);
    setHandler(EXCEPTION_OVERFLOW, @intFromPtr(&isr4), GATE_TRAP);
    setHandler(EXCEPTION_BOUND, @intFromPtr(&isr5), GATE_TRAP);
    setHandler(EXCEPTION_INVALID_OP, @intFromPtr(&isr6), GATE_TRAP);
    setHandler(EXCEPTION_NO_DEVICE, @intFromPtr(&isr7), GATE_TRAP);
    setHandlerWithIST(EXCEPTION_DOUBLE_FAULT, @intFromPtr(&isr8), IST_DOUBLE_FAULT, GATE_TRAP);
    setHandler(EXCEPTION_COPROC_SEG, @intFromPtr(&isr9), GATE_TRAP);
    setHandler(EXCEPTION_INVALID_TSS, @intFromPtr(&isr10), GATE_TRAP);
    setHandler(EXCEPTION_NO_SEGMENT, @intFromPtr(&isr11), GATE_TRAP);
    setHandler(EXCEPTION_STACK_FAULT, @intFromPtr(&isr12), GATE_TRAP);
    setHandler(EXCEPTION_GPF, @intFromPtr(&isr13), GATE_TRAP);
    setHandler(EXCEPTION_PAGE_FAULT, @intFromPtr(&isr14), GATE_TRAP);
    // Vector 15 is reserved
    setHandler(EXCEPTION_X87_FP, @intFromPtr(&isr16), GATE_TRAP);
    setHandler(EXCEPTION_ALIGNMENT, @intFromPtr(&isr17), GATE_TRAP);
    setHandlerWithIST(EXCEPTION_MACHINE_CHECK, @intFromPtr(&isr18), IST_MACHINE_CHECK, GATE_TRAP);
    setHandler(EXCEPTION_SIMD_FP, @intFromPtr(&isr19), GATE_TRAP);

    // Hardware IRQs (32-47) - handled by I/O APIC
    setHandler(IRQ_TIMER, @intFromPtr(&irq0), GATE_INTERRUPT);
    setHandler(IRQ_KEYBOARD, @intFromPtr(&irq1), GATE_INTERRUPT);

    // Set up remaining IRQ vectors
    var i: u8 = 34;
    while (i < 48) : (i += 1) {
        setHandler(i, @intFromPtr(&irqSpurious), GATE_INTERRUPT);
    }

    // Spurious interrupt handler for APIC
    setHandler(0xFF, @intFromPtr(&irqSpurious), GATE_INTERRUPT);

    // Load IDT
    idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    cpu.loadIDT(&idtr);
    initialized = true;
    console.log(.info, "IDT initialized with {} entries", .{256});
}

// ============= ISR Stubs (Naked) =============

// Macro-like approach: create naked ISRs that push the vector number and jump to common handler

fn isr0() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0      // Error code (dummy)
        \\pushq $0      // Vector number
        \\jmp isrCommonStub
    );
}

fn isr1() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $1
        \\jmp isrCommonStub
    );
}

fn isr2() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $2
        \\jmp isrCommonStub
    );
}

fn isr3() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $3
        \\jmp isrCommonStub
    );
}

fn isr4() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $4
        \\jmp isrCommonStub
    );
}

fn isr5() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $5
        \\jmp isrCommonStub
    );
}

fn isr6() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $6
        \\jmp isrCommonStub
    );
}

fn isr7() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $7
        \\jmp isrCommonStub
    );
}

fn isr8() callconv(.naked) noreturn {
    // Double fault pushes error code
    asm volatile (
        \\pushq $8
        \\jmp isrCommonStub
    );
}

fn isr9() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $9
        \\jmp isrCommonStub
    );
}

fn isr10() callconv(.naked) noreturn {
    // Invalid TSS pushes error code
    asm volatile (
        \\pushq $10
        \\jmp isrCommonStub
    );
}

fn isr11() callconv(.naked) noreturn {
    // Segment not present pushes error code
    asm volatile (
        \\pushq $11
        \\jmp isrCommonStub
    );
}

fn isr12() callconv(.naked) noreturn {
    // Stack fault pushes error code
    asm volatile (
        \\pushq $12
        \\jmp isrCommonStub
    );
}

fn isr13() callconv(.naked) noreturn {
    // GPF pushes error code
    asm volatile (
        \\pushq $13
        \\jmp isrCommonStub
    );
}

fn isr14() callconv(.naked) noreturn {
    // Page fault pushes error code
    asm volatile (
        \\pushq $14
        \\jmp isrCommonStub
    );
}

fn isr16() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $16
        \\jmp isrCommonStub
    );
}

fn isr17() callconv(.naked) noreturn {
    // Alignment check pushes error code
    asm volatile (
        \\pushq $17
        \\jmp isrCommonStub
    );
}

fn isr18() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $18
        \\jmp isrCommonStub
    );
}

fn isr19() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $19
        \\jmp isrCommonStub
    );
}

// ============= IRQ Stubs =============

fn irq0() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0      // Error code (dummy)
        \\pushq $32     // Vector number
        \\jmp irqCommonStub
    );
}

fn irq1() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $33
        \\jmp irqCommonStub
    );
}

fn irqSpurious() callconv(.naked) noreturn {
    asm volatile (
        \\pushq $0
        \\pushq $255
        \\jmp irqCommonStub
    );
}

// ============= Common Handlers =============

/// Common ISR stub - saves registers, calls handler, restores and irets
fn isrCommonStub() callconv(.naked) noreturn {
    asm volatile (
        // Save all general purpose registers
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rbx
        \\pushq %%rbp
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // Call Zig exception handler
        // Stack layout: [r15..rax, vector, error_code, rip, cs, rflags, rsp, ss]
        // Vector is at rsp + 15*8 = rsp + 120
        // Error code is at rsp + 16*8 = rsp + 128
        \\movq 120(%%rsp), %%rdi    // vector -> arg1
        \\movq 128(%%rsp), %%rsi    // error_code -> arg2
        \\call handleException
        \\
        // Restore registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rbp
        \\popq %%rbx
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\
        // Remove vector and error code
        \\addq $16, %%rsp
        \\
        // Return from interrupt
        \\iretq
    );
}

/// Common IRQ stub
fn irqCommonStub() callconv(.naked) noreturn {
    asm volatile (
        // Save all general purpose registers
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rbx
        \\pushq %%rbp
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // Call Zig IRQ handler
        \\movq 120(%%rsp), %%rdi    // vector -> arg1
        \\call handleIRQ
        \\
        // Restore registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rbp
        \\popq %%rbx
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\
        // Remove vector and error code
        \\addq $16, %%rsp
        \\
        // Return from interrupt
        \\iretq
    );
}

// ============= Zig Exception/IRQ Handlers =============

export fn handleException(vector: u64, error_code: u64) void {
    switch (vector) {
        0 => panic.panicFmt("Division by zero", .{}),
        1 => console.log(.debug, "Debug exception", .{}),
        2 => panic.panicFmt("Non-maskable interrupt", .{}),
        3 => console.log(.debug, "Breakpoint hit", .{}),
        4 => panic.panicFmt("Overflow exception", .{}),
        5 => panic.panicFmt("Bound range exceeded", .{}),
        6 => panic.panicFmt("Invalid opcode", .{}),
        7 => panic.panicFmt("Device not available", .{}),
        8 => panic.panicFmt("Double fault (error={x})", .{error_code}),
        10 => panic.panicFmt("Invalid TSS", .{}),
        11 => panic.panicFmt("Segment not present", .{}),
        12 => panic.panicFmt("Stack segment fault", .{}),
        13 => panic.panicFmt("General protection fault (error={x})", .{error_code}),
        14 => {
            // Page fault
            const fault_addr = cpu.readCR2();
            if (vmm.handlePageFault(fault_addr, error_code)) {
                return; // Handled
            }
            console.println("", .{});
            console.println("!!! PAGE FAULT !!!", .{});
            console.println("Address: {x}, Error: {x}", .{ fault_addr, error_code });
            panic.halt();
        },
        16 => panic.panicFmt("x87 floating-point exception", .{}),
        17 => panic.panicFmt("Alignment check", .{}),
        18 => panic.panicFmt("Machine check exception", .{}),
        19 => panic.panicFmt("SIMD floating-point exception", .{}),
        else => panic.panicFmt("Unknown exception {}", .{vector}),
    }
}

export fn handleIRQ(vector: u64) void {
    switch (vector) {
        32 => {
            // Timer
            scheduler.tick();
            wakeExpiredSleepers();
        },
        33 => {
            // Keyboard
            const keyboard = @import("../../drivers/keyboard.zig");
            keyboard.handleInterrupt();
        },
        else => {
            // Spurious or unhandled
        },
    }
    // EOI
    apic.sendEoi();
}

// ============= Sleep Support =============

const timer = @import("../../drivers/timer.zig");
const thread_mod = @import("../../proc/thread.zig");

fn wakeExpiredSleepers() void {
    const current_ticks = timer.getTicks();
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

pub fn isInitialized() bool {
    return initialized;
}

pub fn eoi() void {
    apic.sendEoi();
}
