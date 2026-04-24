// Init Process Spawning
//
// Creates and spawns the init process (PID 1) at kernel boot.
// Init is the first userspace process and ancestor of all other processes.

const process = @import("proc/process.zig");
const thread = @import("proc/thread.zig");
const context = @import("proc/context.zig");
const scheduler = @import("proc/scheduler.zig");
const vmm = @import("mm/vmm.zig");
const pmm = @import("mm/pmm.zig");
const console = @import("lib/console.zig");
const elf = @import("loader/elf.zig");
const binaries = @import("binaries.zig");

/// Spawn the init process
/// Returns true on success, false on failure
pub fn spawnInit() bool {
    console.log(.info, "Spawning init process...", .{});

    // Register embedded binaries with VFS first
    binaries.registerAll();

    // Create init process (should be PID 1)
    const init_proc = process.create(null) orelse {
        console.log(.err, "Failed to create init process", .{});
        return false;
    };

    if (init_proc.pid != 1) {
        console.log(.warn, "Init got PID {} instead of 1", .{init_proc.pid});
    }

    init_proc.setName("init");
    console.log(.debug, "Init process created with PID {}", .{init_proc.pid});

    // Get init's address space
    const space = &init_proc.address_space.?;

    // Load the init ELF binary
    const load_result = elf.load(binaries.init_binary, space) catch |err| {
        console.log(.err, "Failed to load init ELF: {}", .{err});
        return false;
    };

    console.log(.debug, "Init ELF loaded: entry={x}, stack={x}", .{
        load_result.entry_point,
        load_result.stack_pointer,
    });

    // Create init's main thread
    const init_thread = thread.create(init_proc) orelse {
        console.log(.err, "Failed to create init thread", .{});
        return false;
    };

    // Set up userspace context with ELF entry point
    context.initUserContext(init_thread, load_result.entry_point, load_result.stack_pointer);

    // Mark process as ready
    init_proc.state = .ready;

    // Add to scheduler
    scheduler.enqueue(init_thread);
    console.log(.info, "Init process spawned (PID {}, TID {})", .{ init_proc.pid, init_thread.tid });

    return true;
}
