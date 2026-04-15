// Kernel Panic Handler
//
// Handles unrecoverable errors by printing diagnostic info
// and halting the system.

const serial = @import("../drivers/serial.zig");
const std = @import("std");

/// Halt the CPU (disable interrupts and loop on HLT)
pub fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Kernel panic - print message and halt
pub fn panic_msg(msg: []const u8) noreturn {
    serial.writeString("\n");
    serial.writeString("========================================\n");
    serial.writeString("        !!! KERNEL PANIC !!!\n");
    serial.writeString("========================================\n");
    serial.writeString("\n");
    serial.writeString("Message: ");
    serial.writeString(msg);
    serial.writeString("\n\n");
    serial.writeString("System halted.\n");
    halt();
}

/// Panic with source location
pub fn panic_at(msg: []const u8, src: std.builtin.SourceLocation) noreturn {
    serial.writeString("\n");
    serial.writeString("========================================\n");
    serial.writeString("        !!! KERNEL PANIC !!!\n");
    serial.writeString("========================================\n");
    serial.writeString("\n");
    serial.writeString("Location: ");
    serial.writeString(src.file);
    serial.writeString(":");
    serial.writeInt(src.line);
    serial.writeString(":");
    serial.writeInt(src.column);
    serial.writeString("\n");
    serial.writeString("Function: ");
    serial.writeString(src.fn_name);
    serial.writeString("\n\n");
    serial.writeString("Message: ");
    serial.writeString(msg);
    serial.writeString("\n\n");
    serial.writeString("System halted.\n");
    halt();
}

/// Zig builtin panic handler
pub fn zig_panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial.writeString("\n");
    serial.writeString("========================================\n");
    serial.writeString("        !!! KERNEL PANIC !!!\n");
    serial.writeString("========================================\n");
    serial.writeString("\n");
    serial.writeString("Message: ");
    serial.writeString(msg);
    serial.writeString("\n");

    // Try to print stack trace if available
    if (stack_trace) |trace| {
        serial.writeString("\nStack trace:\n");
        var i: usize = 0;
        for (trace.instruction_addresses) |addr| {
            if (addr == 0) break;
            serial.writeString("  [");
            serial.writeInt(i);
            serial.writeString("] 0x");
            serial.writeHex(addr);
            serial.writeString("\n");
            i += 1;
        }
    }

    serial.writeString("\nSystem halted.\n");
    halt();
}

/// Assert helper
pub fn assert(condition: bool, msg: []const u8) void {
    if (!condition) {
        panic_msg(msg);
    }
}

/// Assert with source location
pub fn assert_at(condition: bool, msg: []const u8, src: std.builtin.SourceLocation) void {
    if (!condition) {
        panic_at(msg, src);
    }
}

/// Panic with formatted message
pub fn panicFmt(comptime fmt: []const u8, args: anytype) noreturn {
    serial.writeString("\n");
    serial.writeString("========================================\n");
    serial.writeString("        !!! KERNEL PANIC !!!\n");
    serial.writeString("========================================\n");
    serial.writeString("\n");
    serial.writeString("Message: ");
    
    // Format the message inline
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    serial.writeString(msg);
    
    serial.writeString("\n\n");
    serial.writeString("System halted.\n");
    halt();
}
