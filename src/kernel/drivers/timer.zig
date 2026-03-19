// System Timer Driver
//
// High-level timer interface built on APIC timer.
// Provides tick counting and time measurement.

const apic = @import("../arch/x86_64/apic.zig");
const console = @import("../lib/console.zig");

// Timer state
var initialized: bool = false;

/// Initialize the system timer
pub fn init(hz: u32) void {
    if (!apic.init()) {
        console.log(.err, "Timer: Failed to initialize APIC", .{});
        return;
    }

    apic.initTimer(hz);
    initialized = true;

    console.log(.info, "Timer initialized: {}Hz", .{hz});
}

/// Get current tick count
pub fn getTicks() u64 {
    return apic.getTicks();
}

/// Get uptime in milliseconds
pub fn getUptimeMs() u64 {
    const ticks = getTicks();
    const hz = apic.getFrequency();
    return (ticks * 1000) / hz;
}

/// Get uptime in seconds
pub fn getUptimeSecs() u64 {
    const ticks = getTicks();
    const hz = apic.getFrequency();
    return ticks / hz;
}

/// Timer tick handler (called from interrupt)
pub fn tick() void {
    apic.timerHandler();
}

/// Check if timer is running
pub fn isRunning() bool {
    return initialized and apic.isEnabled();
}

/// Stop the timer
pub fn stop() void {
    apic.stopTimer();
    initialized = false;
}

/// Simple busy-wait delay (not recommended for long delays)
pub fn delayTicks(count: u64) void {
    const start = getTicks();
    while (getTicks() - start < count) {
        asm volatile ("pause");
    }
}

/// Delay in milliseconds
pub fn delayMs(ms: u64) void {
    const hz = apic.getFrequency();
    const tick_count = (ms * hz) / 1000;
    delayTicks(tick_count);
}
