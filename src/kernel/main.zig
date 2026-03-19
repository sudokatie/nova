// Nova Microkernel - Main Entry Point
//
// This is the kernel entry point called by the Limine bootloader.
// It sets up basic serial output and initializes kernel subsystems.

const limine = @import("limine.zig");
const serial = @import("drivers/serial.zig");

// Limine requests - these are filled in by the bootloader
pub export var base_revision: limine.BaseRevision linksection(".limine_reqs") = .{ .revision = 2 };
pub export var memory_map_request: limine.MemoryMapRequest linksection(".limine_reqs") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_reqs") = .{};
pub export var kernel_address_request: limine.KernelAddressRequest linksection(".limine_reqs") = .{};

// Kernel entry point
export fn kmain() noreturn {
    // Initialize serial console for debug output
    serial.init();

    // Print boot message
    serial.writeString("\n");
    serial.writeString("=====================================\n");
    serial.writeString("  Nova Microkernel v0.1.0\n");
    serial.writeString("=====================================\n");
    serial.writeString("\n");

    // Verify Limine protocol
    if (!base_revision.is_supported()) {
        serial.writeString("ERROR: Limine base revision not supported\n");
        halt();
    }
    serial.writeString("[OK] Limine protocol verified\n");

    // Check memory map
    if (memory_map_request.response) |memmap| {
        serial.writeString("[OK] Memory map received: ");
        serial.writeInt(memmap.entry_count);
        serial.writeString(" entries\n");

        // Print memory summary
        var total_usable: u64 = 0;
        for (memmap.entries()[0..memmap.entry_count]) |entry| {
            if (entry.kind == .usable) {
                total_usable += entry.length;
            }
        }
        serial.writeString("     Usable memory: ");
        serial.writeInt(total_usable / 1024 / 1024);
        serial.writeString(" MB\n");
    } else {
        serial.writeString("ERROR: No memory map from bootloader\n");
        halt();
    }

    // Check HHDM (Higher Half Direct Map)
    if (hhdm_request.response) |hhdm| {
        serial.writeString("[OK] HHDM offset: 0x");
        serial.writeHex(hhdm.offset);
        serial.writeString("\n");
    } else {
        serial.writeString("ERROR: No HHDM from bootloader\n");
        halt();
    }

    serial.writeString("\n");
    serial.writeString("Hello from Nova kernel!\n");
    serial.writeString("Boot successful. System halted.\n");

    // Halt - we don't have a scheduler yet
    halt();
}

fn halt() noreturn {
    // Disable interrupts and halt
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

// Panic handler for Zig runtime
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    serial.writeString("\n!!! KERNEL PANIC !!!\n");
    serial.writeString(msg);
    serial.writeString("\n");
    halt();
}
