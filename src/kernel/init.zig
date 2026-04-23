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

// User address for init code
const INIT_CODE_ADDR: u64 = 0x400000;
const INIT_STACK_TOP: u64 = 0x7FFFFFFFE000;
const INIT_STACK_SIZE: u64 = 4 * 4096; // 16KB stack

// Embedded init program machine code
// This minimal program:
//   1. Prints "Init running" via debug_print syscall
//   2. Loops forever calling yield syscall
//
// Code layout at 0x400000:
//   0x00: mov rax, 50         ; SYS_DEBUG_PRINT
//   0x07: lea rdi, [rip+0x1a] ; pointer to message at 0x400028
//   0x0e: mov rsi, 13         ; length of "Init running\n"
//   0x15: syscall
//   0x17: mov rax, 23         ; SYS_YIELD
//   0x1e: syscall
//   0x20: jmp -0x0b           ; back to yield
//   0x22: padding
//   0x28: "Init running\n"
const init_code = [_]u8{
    // mov rax, 50 (SYS_DEBUG_PRINT)
    0x48, 0xC7, 0xC0, 0x32, 0x00, 0x00, 0x00,
    // lea rdi, [rip+0x1a] - points to message at offset 0x28
    0x48, 0x8D, 0x3D, 0x1A, 0x00, 0x00, 0x00,
    // mov rsi, 13
    0x48, 0xC7, 0xC6, 0x0D, 0x00, 0x00, 0x00,
    // syscall
    0x0F, 0x05,
    // Loop: mov rax, 23 (SYS_YIELD)
    0x48, 0xC7, 0xC0, 0x17, 0x00, 0x00, 0x00,
    // syscall
    0x0F, 0x05,
    // jmp -0x0b (back to yield mov instruction)
    0xEB, 0xF3,
    // Padding to align message
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // Message: "Init running\n" (13 bytes)
    'I', 'n', 'i', 't', ' ', 'r', 'u', 'n', 'n', 'i', 'n', 'g', '\n',
};

/// Spawn the init process
/// Returns true on success, false on failure
pub fn spawnInit() bool {
    console.log(.info, "Spawning init process...", .{});

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

    // Allocate and map code page
    const code_pages = (init_code.len + 4095) / 4096;
    const code_flags = vmm.MapFlags{ .user = true, .writable = false };
    if (!vmm.allocPages(space, INIT_CODE_ADDR, code_pages, code_flags)) {
        console.log(.err, "Failed to allocate init code pages", .{});
        return false;
    }

    // Copy init code to the mapped page
    const code_phys = space.translate(INIT_CODE_ADDR) orelse {
        console.log(.err, "Failed to translate init code address", .{});
        return false;
    };
    const code_ptr: [*]u8 = @ptrFromInt(pmm.physToVirt(code_phys));
    for (init_code, 0..) |byte, i| {
        code_ptr[i] = byte;
    }
    console.log(.debug, "Init code loaded at {x}", .{INIT_CODE_ADDR});

    // Allocate and map stack pages
    const stack_base = INIT_STACK_TOP - INIT_STACK_SIZE;
    const stack_pages = INIT_STACK_SIZE / 4096;
    const stack_flags = vmm.MapFlags{ .user = true, .writable = true, .no_execute = true };
    if (!vmm.allocPages(space, stack_base, stack_pages, stack_flags)) {
        console.log(.err, "Failed to allocate init stack pages", .{});
        return false;
    }
    console.log(.debug, "Init stack at {x}-{x}", .{ stack_base, INIT_STACK_TOP });

    // Create init's main thread
    const init_thread = thread.create(init_proc) orelse {
        console.log(.err, "Failed to create init thread", .{});
        return false;
    };

    // Set up userspace context
    const user_stack = INIT_STACK_TOP - 8; // Aligned, with space for return address
    context.initUserContext(init_thread, INIT_CODE_ADDR, user_stack);

    // Mark process as ready
    init_proc.state = .ready;

    // Add to scheduler
    scheduler.enqueue(init_thread);
    console.log(.info, "Init process spawned (PID {}, TID {})", .{ init_proc.pid, init_thread.tid });

    return true;
}
