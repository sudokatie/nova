// Init Process
//
// First userspace process (PID 1).
// Responsible for starting the shell and reaping orphans.

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

/// Main entry point for init
export fn main() i32 {
    libnova.println("Nova init starting...");

    // Print our PID
    const pid = syscall.getpid();
    libnova.print("Init PID: ");
    printNumber(pid);
    libnova.print("\n");

    // TODO: Spawn shell
    libnova.println("Shell not yet implemented");

    // Main loop - wait for children
    libnova.println("Init entering main loop");
    while (true) {
        // Yield to other processes
        syscall.yield();

        // TODO: Wait for child processes
        // TODO: Reap zombies
    }

    // Init should never exit
    return 0;
}

/// Simple number printing (no printf)
fn printNumber(n: i32) void {
    if (n < 0) {
        libnova.print("-");
        printNumber(-n);
        return;
    }

    if (n >= 10) {
        printNumber(@divTrunc(n, 10));
    }

    const digit: u8 = @intCast(@mod(n, 10) + '0');
    const buf = [1]u8{digit};
    libnova.print(&buf);
}
