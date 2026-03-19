// Nova Microkernel - Main Entry Point
//
// This is the kernel entry point called by the Limine bootloader.
// It sets up basic serial output and initializes kernel subsystems.

const limine = @import("limine.zig");
const console = @import("lib/console.zig");
const panic_handler = @import("lib/panic.zig");

// Limine requests - these are filled in by the bootloader
pub export var base_revision: limine.BaseRevision linksection(".limine_reqs") = .{ .revision = 2 };
pub export var memory_map_request: limine.MemoryMapRequest linksection(".limine_reqs") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_reqs") = .{};
pub export var kernel_address_request: limine.KernelAddressRequest linksection(".limine_reqs") = .{};

// Kernel entry point
export fn kmain() noreturn {
    // Initialize console for debug output
    console.init();

    // Print boot message
    console.println("", .{});
    console.println("=====================================", .{});
    console.println("  Nova Microkernel v0.1.0", .{});
    console.println("=====================================", .{});
    console.println("", .{});

    // Verify Limine protocol
    if (!base_revision.is_supported()) {
        panic_handler.panic_msg("Limine base revision not supported");
    }
    console.log(.info, "Limine protocol verified", .{});

    // Check memory map
    if (memory_map_request.response) |memmap| {
        console.log(.info, "Memory map: {} entries", .{memmap.entry_count});

        // Print memory summary
        var total_usable: u64 = 0;
        for (memmap.entries()[0..memmap.entry_count]) |entry| {
            if (entry.kind == .usable) {
                total_usable += entry.length;
            }
        }
        console.log(.info, "Usable memory: {} MB", .{total_usable / 1024 / 1024});
    } else {
        panic_handler.panic_msg("No memory map from bootloader");
    }

    // Check HHDM (Higher Half Direct Map)
    if (hhdm_request.response) |hhdm| {
        console.log(.info, "HHDM offset: {x}", .{hhdm.offset});
    } else {
        panic_handler.panic_msg("No HHDM from bootloader");
    }

    console.println("", .{});
    console.println("Hello from Nova kernel!", .{});
    console.println("Boot successful. System halted.", .{});

    // Halt - we don't have a scheduler yet
    panic_handler.halt();
}

// Zig builtin panic handler - forward to our panic module
pub const panic = panic_handler.zig_panic;
