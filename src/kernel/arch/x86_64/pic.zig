// Legacy 8259 PIC Driver
//
// Used only to disable the PIC when using APIC.
// The PIC is remapped to avoid conflicts with CPU exceptions,
// then masked to disable all legacy interrupts.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");

// PIC ports
const PIC1_COMMAND: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_COMMAND: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

// ICW commands
const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;

// End of interrupt command
const EOI: u8 = 0x20;

// Default vector offsets (remap to avoid collision with exceptions)
const PIC1_OFFSET: u8 = 0x20; // IRQ 0-7 -> 32-39
const PIC2_OFFSET: u8 = 0x28; // IRQ 8-15 -> 40-47

var initialized: bool = false;

/// Initialize and remap the PIC
/// This is called before disabling, to ensure clean state
pub fn init() void {
    // Save masks
    const mask1 = cpu.inb(PIC1_DATA);
    const mask2 = cpu.inb(PIC2_DATA);

    // ICW1: Start initialization sequence
    cpu.outb(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4);
    cpu.io_wait();
    cpu.outb(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4);
    cpu.io_wait();

    // ICW2: Vector offsets
    cpu.outb(PIC1_DATA, PIC1_OFFSET);
    cpu.io_wait();
    cpu.outb(PIC2_DATA, PIC2_OFFSET);
    cpu.io_wait();

    // ICW3: Master/slave configuration
    cpu.outb(PIC1_DATA, 4); // IRQ2 has slave
    cpu.io_wait();
    cpu.outb(PIC2_DATA, 2); // Slave ID 2
    cpu.io_wait();

    // ICW4: 8086 mode
    cpu.outb(PIC1_DATA, ICW4_8086);
    cpu.io_wait();
    cpu.outb(PIC2_DATA, ICW4_8086);
    cpu.io_wait();

    // Restore masks
    cpu.outb(PIC1_DATA, mask1);
    cpu.outb(PIC2_DATA, mask2);

    initialized = true;
    console.log(.debug, "PIC remapped: IRQ0-7 -> {}, IRQ8-15 -> {}", .{ PIC1_OFFSET, PIC2_OFFSET });
}

/// Disable the PIC by masking all interrupts
/// Call this when switching to APIC
pub fn disable() void {
    // Mask all interrupts on both PICs
    cpu.outb(PIC1_DATA, 0xFF);
    cpu.outb(PIC2_DATA, 0xFF);

    console.log(.debug, "PIC disabled (all interrupts masked)", .{});
}

/// Send End of Interrupt signal
pub fn eoi(irq: u8) void {
    if (irq >= 8) {
        // Send EOI to slave PIC
        cpu.outb(PIC2_COMMAND, EOI);
    }
    // Always send EOI to master PIC
    cpu.outb(PIC1_COMMAND, EOI);
}

/// Mask a specific IRQ
pub fn maskIRQ(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const line = irq % 8;
    const mask = cpu.inb(port) | (@as(u8, 1) << @intCast(line));
    cpu.outb(port, mask);
}

/// Unmask a specific IRQ
pub fn unmaskIRQ(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const line = irq % 8;
    const mask = cpu.inb(port) & ~(@as(u8, 1) << @intCast(line));
    cpu.outb(port, mask);
}

/// Check if PIC is initialized
pub fn isInitialized() bool {
    return initialized;
}
