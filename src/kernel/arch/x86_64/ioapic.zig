// I/O APIC Driver
//
// Handles routing of external interrupts (keyboard, etc.) to CPUs.
// The I/O APIC replaces the legacy 8259 PIC for interrupt routing.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");
const pmm = @import("../../mm/pmm.zig");
const apic = @import("apic.zig");

// Default I/O APIC base address (can be overridden by ACPI)
const IOAPIC_DEFAULT_BASE: u64 = 0xFEC00000;

// I/O APIC registers (accessed via index/data window)
const IOAPICID: u32 = 0x00;
const IOAPICVER: u32 = 0x01;
const IOAPICARB: u32 = 0x02;
const IOREDTBL_BASE: u32 = 0x10; // Redirection table starts here

// Redirection entry flags
pub const DeliveryMode = enum(u3) {
    fixed = 0b000,
    lowest_priority = 0b001,
    smi = 0b010,
    nmi = 0b100,
    init = 0b101,
    ext_int = 0b111,
};

pub const DestinationMode = enum(u1) {
    physical = 0,
    logical = 1,
};

pub const Polarity = enum(u1) {
    active_high = 0,
    active_low = 1,
};

pub const TriggerMode = enum(u1) {
    edge = 0,
    level = 1,
};

/// Redirection table entry (64 bits)
pub const RedirectionEntry = packed struct {
    vector: u8, // Interrupt vector (IDT index)
    delivery_mode: u3,
    dest_mode: u1, // 0 = physical, 1 = logical
    delivery_status: u1, // Read-only
    polarity: u1, // 0 = active high, 1 = active low
    remote_irr: u1, // Read-only (level-triggered)
    trigger_mode: u1, // 0 = edge, 1 = level
    mask: u1, // 1 = masked (disabled)
    reserved: u39,
    destination: u8, // APIC ID of target CPU

    pub fn init(vector: u8, dest: u8) RedirectionEntry {
        return .{
            .vector = vector,
            .delivery_mode = @intFromEnum(DeliveryMode.fixed),
            .dest_mode = @intFromEnum(DestinationMode.physical),
            .delivery_status = 0,
            .polarity = @intFromEnum(Polarity.active_high),
            .remote_irr = 0,
            .trigger_mode = @intFromEnum(TriggerMode.edge),
            .mask = 1, // Start masked
            .reserved = 0,
            .destination = dest,
        };
    }

    pub fn setMasked(self: *RedirectionEntry, masked: bool) void {
        self.mask = if (masked) 1 else 0;
    }

    pub fn setTriggerMode(self: *RedirectionEntry, mode: TriggerMode) void {
        self.trigger_mode = @intFromEnum(mode);
    }

    pub fn setPolarity(self: *RedirectionEntry, pol: Polarity) void {
        self.polarity = @intFromEnum(pol);
    }
};

// I/O APIC state
var ioapic_base: u64 = 0;
var ioapic_virt: u64 = 0;
var max_redirection_entries: u8 = 0;
var initialized: bool = false;

/// Read I/O APIC register
fn read(reg: u32) u32 {
    const index_ptr: *volatile u32 = @ptrFromInt(ioapic_virt);
    const data_ptr: *volatile u32 = @ptrFromInt(ioapic_virt + 0x10);

    index_ptr.* = reg;
    return data_ptr.*;
}

/// Write I/O APIC register
fn write(reg: u32, value: u32) void {
    const index_ptr: *volatile u32 = @ptrFromInt(ioapic_virt);
    const data_ptr: *volatile u32 = @ptrFromInt(ioapic_virt + 0x10);

    index_ptr.* = reg;
    data_ptr.* = value;
}

/// Read redirection entry
fn readRedirection(index: u8) RedirectionEntry {
    const reg_low = IOREDTBL_BASE + @as(u32, index) * 2;
    const reg_high = reg_low + 1;

    const low = read(reg_low);
    const high = read(reg_high);

    const value: u64 = (@as(u64, high) << 32) | low;
    return @bitCast(value);
}

/// Write redirection entry
fn writeRedirection(index: u8, entry: RedirectionEntry) void {
    const reg_low = IOREDTBL_BASE + @as(u32, index) * 2;
    const reg_high = reg_low + 1;

    const value: u64 = @bitCast(entry);
    write(reg_low, @truncate(value));
    write(reg_high, @truncate(value >> 32));
}

/// Initialize the I/O APIC
pub fn init() void {
    initWithBase(IOAPIC_DEFAULT_BASE);
}

/// Initialize with specific base address (from ACPI)
pub fn initWithBase(base: u64) void {
    ioapic_base = base;

    // Map I/O APIC to virtual address
    ioapic_virt = pmm.physToVirt(base);

    // Read version to get max redirection entries
    const version = read(IOAPICVER);
    max_redirection_entries = @truncate((version >> 16) & 0xFF);
    max_redirection_entries += 1; // It's 0-indexed

    const ioapic_id = read(IOAPICID) >> 24;

    console.log(.info, "I/O APIC initialized: ID={}, {} IRQs, base={x}", .{
        ioapic_id,
        max_redirection_entries,
        base,
    });

    // Mask all interrupts initially
    var i: u8 = 0;
    while (i < max_redirection_entries) : (i += 1) {
        var entry = RedirectionEntry.init(0, 0);
        entry.mask = 1;
        writeRedirection(i, entry);
    }

    initialized = true;
}

/// Configure an IRQ
pub fn configureIRQ(irq: u8, vector: u8, dest_apic_id: u8) void {
    if (!initialized or irq >= max_redirection_entries) return;

    var entry = RedirectionEntry.init(vector, dest_apic_id);
    entry.mask = 0; // Unmask

    // Some IRQs need special handling
    switch (irq) {
        1 => {
            // Keyboard - edge triggered, active high
            entry.trigger_mode = @intFromEnum(TriggerMode.edge);
            entry.polarity = @intFromEnum(Polarity.active_high);
        },
        12 => {
            // PS/2 Mouse - edge triggered, active high
            entry.trigger_mode = @intFromEnum(TriggerMode.edge);
            entry.polarity = @intFromEnum(Polarity.active_high);
        },
        else => {
            // Default: edge triggered, active high
            entry.trigger_mode = @intFromEnum(TriggerMode.edge);
            entry.polarity = @intFromEnum(Polarity.active_high);
        },
    }

    writeRedirection(irq, entry);
    console.log(.debug, "I/O APIC: IRQ {} -> vector {}, CPU {}", .{ irq, vector, dest_apic_id });
}

/// Mask (disable) an IRQ
pub fn maskIRQ(irq: u8) void {
    if (!initialized or irq >= max_redirection_entries) return;

    var entry = readRedirection(irq);
    entry.mask = 1;
    writeRedirection(irq, entry);
}

/// Unmask (enable) an IRQ
pub fn unmaskIRQ(irq: u8) void {
    if (!initialized or irq >= max_redirection_entries) return;

    var entry = readRedirection(irq);
    entry.mask = 0;
    writeRedirection(irq, entry);
}

/// Check if I/O APIC is initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Get max IRQs supported
pub fn getMaxIRQs() u8 {
    return max_redirection_entries;
}

/// Set up standard PC IRQ mappings
pub fn setupStandardIRQs() void {
    if (!initialized) return;

    const bsp_apic_id = apic.getLocalApicId();

    // Timer (IRQ 0) - usually handled by Local APIC timer instead
    // configureIRQ(0, 32, bsp_apic_id);

    // Keyboard (IRQ 1)
    configureIRQ(1, 33, bsp_apic_id);

    // Cascade (IRQ 2) - not used with I/O APIC

    // COM2 (IRQ 3)
    configureIRQ(3, 35, bsp_apic_id);

    // COM1 (IRQ 4)
    configureIRQ(4, 36, bsp_apic_id);

    // LPT2 (IRQ 5)
    // configureIRQ(5, 37, bsp_apic_id);

    // Floppy (IRQ 6)
    // configureIRQ(6, 38, bsp_apic_id);

    // LPT1 (IRQ 7)
    // configureIRQ(7, 39, bsp_apic_id);

    // RTC (IRQ 8)
    configureIRQ(8, 40, bsp_apic_id);

    // PS/2 Mouse (IRQ 12)
    configureIRQ(12, 44, bsp_apic_id);

    // FPU (IRQ 13)
    // configureIRQ(13, 45, bsp_apic_id);

    // Primary ATA (IRQ 14)
    configureIRQ(14, 46, bsp_apic_id);

    // Secondary ATA (IRQ 15)
    configureIRQ(15, 47, bsp_apic_id);

    console.log(.info, "I/O APIC: Standard PC IRQs configured", .{});
}
