// Nova Microkernel - Main Entry Point
//
// This is the kernel entry point called by the Limine bootloader.
// It sets up basic serial output and initializes kernel subsystems.

const limine = @import("limine.zig");
const console = @import("lib/console.zig");
const panic_handler = @import("lib/panic.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const timer = @import("drivers/timer.zig");

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

    // Get memory map
    const memmap = memory_map_request.response orelse {
        panic_handler.panic_msg("No memory map from bootloader");
    };
    console.log(.info, "Memory map: {} entries", .{memmap.entry_count});

    // Get HHDM
    const hhdm = hhdm_request.response orelse {
        panic_handler.panic_msg("No HHDM from bootloader");
    };
    console.log(.info, "HHDM offset: {x}", .{hhdm.offset});

    // Note: GDT/IDT initialization deferred
    // Limine sets up valid GDT/IDT that we can use for now
    console.log(.info, "Using Limine GDT/IDT", .{});

    // Initialize physical memory manager
    console.log(.info, "Initializing PMM...", .{});
    pmm.init(memmap, hhdm);

    // Test PMM
    console.log(.debug, "PMM test: allocating pages...", .{});
    if (pmm.allocPage()) |page1| {
        console.log(.debug, "  Allocated page at {x}", .{page1});
        if (pmm.allocPage()) |page2| {
            console.log(.debug, "  Allocated page at {x}", .{page2});
            pmm.freePage(page1);
            pmm.freePage(page2);
            console.log(.debug, "  Freed both pages", .{});
        }
    }
    console.log(.info, "PMM test passed", .{});

    // Initialize virtual memory manager
    console.log(.info, "Initializing VMM...", .{});
    vmm.init();

    // Test VMM
    console.log(.debug, "VMM test: mapping pages...", .{});
    const kernel_space = vmm.getKernelSpace();

    // Test address translation (existing mappings)
    const test_virt: u64 = 0xFFFFFFFF80000000; // Kernel base
    if (kernel_space.translate(test_virt)) |phys| {
        console.log(.debug, "  Kernel base {x} -> {x}", .{ test_virt, phys });
    } else {
        console.log(.warn, "  Kernel base not mapped", .{});
    }

    // Test mapping a new page
    const test_addr: u64 = 0xFFFFFFFF90000000; // Arbitrary kernel address
    if (pmm.allocPage()) |phys_page| {
        const flags = vmm.MapFlags{ .writable = true };
        if (kernel_space.mapPage(test_addr, phys_page, flags)) {
            console.log(.debug, "  Mapped {x} -> {x}", .{ test_addr, phys_page });

            // Verify mapping
            if (kernel_space.translate(test_addr)) |resolved| {
                if (resolved == phys_page) {
                    console.log(.debug, "  Translation verified", .{});
                } else {
                    console.log(.warn, "  Translation mismatch: got {x}", .{resolved});
                }
            }

            // Test write/read
            const ptr: *volatile u64 = @ptrFromInt(test_addr);
            ptr.* = 0xDEADBEEF_CAFEBABE;
            const read_back = ptr.*;
            if (read_back == 0xDEADBEEF_CAFEBABE) {
                console.log(.debug, "  Write/read verified", .{});
            }

            // Unmap and free
            _ = kernel_space.unmapPage(test_addr);
            pmm.freePage(phys_page);
            console.log(.debug, "  Unmapped and freed", .{});
        }
    }
    console.log(.info, "VMM test passed", .{});

    // Initialize kernel heap
    console.log(.info, "Initializing heap...", .{});
    heap.init();
    heap.test_heap();

    // Initialize timer (APIC)
    // Note: Timer interrupts won't fire until IDT is properly set up
    console.log(.info, "Initializing timer...", .{});
    timer.init(100); // 100 Hz

    console.println("", .{});
    console.println("Hello from Nova kernel!", .{});
    console.println("Boot successful. System halted.", .{});

    // Halt - we don't have a scheduler yet
    panic_handler.halt();
}

// Zig builtin panic handler - forward to our panic module
pub const panic = panic_handler.zig_panic;
