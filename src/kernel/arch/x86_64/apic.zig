// Local APIC Driver
//
// Manages the Local Advanced Programmable Interrupt Controller.
// Provides timer and inter-processor interrupts.

const cpu = @import("cpu.zig");
const pic = @import("pic.zig");
const paging = @import("paging.zig");
const pmm = @import("../../mm/pmm.zig");
const console = @import("../../lib/console.zig");

// APIC register offsets (relative to APIC base)
const APIC_ID: u32 = 0x020; // Local APIC ID
const APIC_VERSION: u32 = 0x030; // Version
const APIC_TPR: u32 = 0x080; // Task Priority
const APIC_EOI: u32 = 0x0B0; // End of Interrupt
const APIC_SVR: u32 = 0x0F0; // Spurious Interrupt Vector
const APIC_ICR_LOW: u32 = 0x300; // Interrupt Command (low)
const APIC_ICR_HIGH: u32 = 0x310; // Interrupt Command (high)
const APIC_LVT_TIMER: u32 = 0x320; // LVT Timer
const APIC_LVT_LINT0: u32 = 0x350; // LVT LINT0
const APIC_LVT_LINT1: u32 = 0x360; // LVT LINT1
const APIC_LVT_ERROR: u32 = 0x370; // LVT Error
const APIC_TIMER_INIT: u32 = 0x380; // Timer Initial Count
const APIC_TIMER_CURRENT: u32 = 0x390; // Timer Current Count
const APIC_TIMER_DIV: u32 = 0x3E0; // Timer Divide Config

// SVR flags
const SVR_ENABLE: u32 = 0x100; // APIC Software Enable
const SPURIOUS_VECTOR: u32 = 0xFF; // Spurious interrupt vector

// Timer modes
const TIMER_PERIODIC: u32 = 0x20000; // Periodic mode
const TIMER_MASKED: u32 = 0x10000; // Masked (disabled)

// MSRs
const IA32_APIC_BASE: u32 = 0x1B;
const APIC_BASE_ENABLE: u64 = 1 << 11;

// Default APIC base address
const DEFAULT_APIC_BASE: u64 = 0xFEE00000;

// Timer configuration
pub const TIMER_VECTOR: u8 = 32; // IRQ0 equivalent
const TIMER_DIVIDER: u32 = 3; // Divide by 16

// Global state
var apic_base: u64 = 0;
var ticks: u64 = 0;
var timer_frequency: u32 = 100; // Target Hz

/// Check if APIC is available via CPUID
pub fn isAvailable() bool {
    const result = paging.cpuid(1);
    return (result.edx & (1 << 9)) != 0;
}

/// Get the APIC base address from MSR
fn getBase() u64 {
    const msr = cpu.readMSR(IA32_APIC_BASE);
    return msr & 0xFFFFF000;
}

/// Read APIC register
fn read(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(pmm.physToVirt(apic_base) + offset);
    return addr.*;
}

/// Write APIC register
fn write(offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(pmm.physToVirt(apic_base) + offset);
    addr.* = value;
}

/// Initialize the Local APIC
pub fn init() bool {
    if (!isAvailable()) {
        console.log(.err, "APIC: Not available on this CPU", .{});
        return false;
    }

    // Get APIC base address
    apic_base = getBase();
    console.log(.debug, "APIC: Base address {x}", .{apic_base});

    // Enable APIC in MSR
    const msr = cpu.readMSR(IA32_APIC_BASE);
    cpu.writeMSR(IA32_APIC_BASE, msr | APIC_BASE_ENABLE);

    // Disable legacy PIC
    pic.disable();
    console.log(.debug, "APIC: Legacy PIC disabled", .{});

    // Set spurious interrupt vector and enable APIC
    write(APIC_SVR, SVR_ENABLE | SPURIOUS_VECTOR);

    // Set task priority to 0 (accept all interrupts)
    write(APIC_TPR, 0);

    // Mask LINT0 and LINT1
    write(APIC_LVT_LINT0, TIMER_MASKED);
    write(APIC_LVT_LINT1, TIMER_MASKED);

    // Mask error interrupt
    write(APIC_LVT_ERROR, TIMER_MASKED);

    // Clear any pending interrupts
    sendEoi();

    const version = read(APIC_VERSION);
    const id = read(APIC_ID) >> 24;
    console.log(.info, "APIC initialized: ID={}, version={x}", .{ id, version & 0xFF });

    return true;
}

/// Initialize the APIC timer
pub fn initTimer(hz: u32) void {
    timer_frequency = hz;

    // Set divider
    write(APIC_TIMER_DIV, TIMER_DIVIDER);

    // Calibrate timer by measuring against PIT
    // For simplicity, use a rough estimate (will be calibrated properly later)
    // Assume ~1GHz CPU, divider 16 -> ~62.5MHz timer
    // For 100Hz: initial count = 625000
    const initial_count: u32 = 625000;

    // Configure timer: periodic mode, vector TIMER_VECTOR
    write(APIC_LVT_TIMER, TIMER_PERIODIC | TIMER_VECTOR);

    // Set initial count (starts timer)
    write(APIC_TIMER_INIT, initial_count);

    console.log(.info, "APIC timer: {}Hz (initial count {})", .{ hz, initial_count });
}

/// Send End of Interrupt
pub fn sendEoi() void {
    write(APIC_EOI, 0);
}

/// Timer interrupt handler (called from ISR)
pub fn timerHandler() void {
    ticks += 1;
    sendEoi();
}

/// Get current tick count
pub fn getTicks() u64 {
    return ticks;
}

/// Get timer frequency in Hz
pub fn getFrequency() u32 {
    return timer_frequency;
}

/// Stop the timer
pub fn stopTimer() void {
    write(APIC_LVT_TIMER, TIMER_MASKED);
    write(APIC_TIMER_INIT, 0);
}

/// Check if APIC is enabled
pub fn isEnabled() bool {
    return (read(APIC_SVR) & SVR_ENABLE) != 0;
}
