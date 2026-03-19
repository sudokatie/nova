// Legacy 8259 PIC Driver
//
// Used only to disable the PIC when switching to APIC.

const cpu = @import("cpu.zig");

// PIC I/O ports
const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

// ICW1: Initialization command
const ICW1_ICW4: u8 = 0x01; // ICW4 needed
const ICW1_INIT: u8 = 0x10; // Initialization

// ICW4: 8086 mode
const ICW4_8086: u8 = 0x01;

/// Disable the legacy 8259 PIC by masking all interrupts
pub fn disable() void {
    // Mask all interrupts on both PICs
    cpu.outb(PIC1_DATA, 0xFF);
    cpu.outb(PIC2_DATA, 0xFF);
}

/// Remap PIC interrupts to different vectors (used before APIC)
/// This moves IRQ 0-7 to offset1 and IRQ 8-15 to offset2
pub fn remap(offset1: u8, offset2: u8) void {
    // Save masks
    const mask1 = cpu.inb(PIC1_DATA);
    const mask2 = cpu.inb(PIC2_DATA);

    // Start initialization sequence (cascade mode)
    cpu.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    cpu.io_wait();
    cpu.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    cpu.io_wait();

    // ICW2: Vector offsets
    cpu.outb(PIC1_DATA, offset1);
    cpu.io_wait();
    cpu.outb(PIC2_DATA, offset2);
    cpu.io_wait();

    // ICW3: Cascade identity
    cpu.outb(PIC1_DATA, 4); // IRQ2 has slave
    cpu.io_wait();
    cpu.outb(PIC2_DATA, 2); // Slave identity
    cpu.io_wait();

    // ICW4: 8086 mode
    cpu.outb(PIC1_DATA, ICW4_8086);
    cpu.io_wait();
    cpu.outb(PIC2_DATA, ICW4_8086);
    cpu.io_wait();

    // Restore masks
    cpu.outb(PIC1_DATA, mask1);
    cpu.outb(PIC2_DATA, mask2);
}

/// Send End of Interrupt to PIC
pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        cpu.outb(PIC2_CMD, 0x20);
    }
    cpu.outb(PIC1_CMD, 0x20);
}
