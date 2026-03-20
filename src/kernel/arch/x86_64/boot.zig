// Early Boot Code
//
// Low-level boot initialization before main kernel code runs.
// Sets up GDT, IDT, and prepares the CPU for kernel operation.

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const cpu = @import("cpu.zig");
const apic = @import("apic.zig");
const pic = @import("pic.zig");
const console = @import("../../lib/console.zig");

// Boot state
var boot_complete: bool = false;

/// Early boot initialization
/// Called before most kernel subsystems are available
pub fn earlyInit() void {
    // Disable legacy PIC (we'll use APIC)
    pic.disable();

    // Enable essential CPU features
    enableCpuFeatures();

    console.log(.debug, "Boot: Early initialization complete", .{});
}

/// Full boot initialization
/// Called after memory management is available
pub fn init() void {
    // Load our own GDT (replace Limine's)
    gdt.init();

    // Load our own IDT
    idt.init();

    // Enable interrupts
    cpu.enableInterrupts();

    boot_complete = true;
    console.log(.info, "Boot: CPU initialized with custom GDT/IDT", .{});
}

/// Enable essential CPU features
fn enableCpuFeatures() void {
    // Enable SSE if available (needed for some operations)
    enableSse();

    // Enable FSGSBASE if available
    enableFsGsBase();
}

/// Enable SSE/SSE2 (required for 64-bit mode anyway, but ensure FPU is set up)
fn enableSse() void {
    var cr0 = cpu.readCr0();

    // Clear EM (emulation), set MP (monitor coprocessor)
    cr0 &= ~@as(u64, 1 << 2); // Clear EM
    cr0 |= (1 << 1); // Set MP

    cpu.writeCr0(cr0);

    var cr4 = cpu.readCr4();

    // Enable OSFXSR and OSXMMEXCPT
    cr4 |= (1 << 9); // OSFXSR
    cr4 |= (1 << 10); // OSXMMEXCPT

    cpu.writeCr4(cr4);
}

/// Enable FSGSBASE instructions if supported
fn enableFsGsBase() void {
    // Check CPUID for FSGSBASE support
    const cpuid = cpu.cpuid(7, 0);
    if ((cpuid.ebx & (1 << 0)) != 0) {
        var cr4 = cpu.readCr4();
        cr4 |= (1 << 16); // FSGSBASE enable
        cpu.writeCr4(cr4);
        console.log(.debug, "Boot: FSGSBASE enabled", .{});
    }
}

/// Check if boot is complete
pub fn isComplete() bool {
    return boot_complete;
}

/// Get boot info string
pub fn getBootInfo() []const u8 {
    return "Nova Microkernel v0.1.0";
}

/// Halt the system (for fatal errors during boot)
pub fn halt() noreturn {
    cpu.disableInterrupts();
    while (true) {
        asm volatile ("hlt");
    }
}

/// Reboot the system
pub fn reboot() noreturn {
    cpu.disableInterrupts();

    // Try keyboard controller reset
    cpu.outb(0x64, 0xFE);

    // If that didn't work, triple fault
    // Load a null IDT and trigger an interrupt
    const null_idt = cpu.IdtPtr{ .limit = 0, .base = 0 };
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&null_idt),
    );
    asm volatile ("int $0");

    unreachable;
}
