// Init Process
//
// First userspace process (PID 1).
// Responsible for starting servers and the shell, and reaping orphans.

const libnova = @import("libnova");
const syscall = libnova.syscall;

// Force _start to be included in the binary
comptime {
    _ = &libnova._start;
}

/// Child process info
const ChildInfo = struct {
    pid: i32,
    name: []const u8,
};

/// Tracked children
const MAX_CHILDREN: usize = 16;
var children: [MAX_CHILDREN]?ChildInfo = [_]?ChildInfo{null} ** MAX_CHILDREN;
var child_count: usize = 0;

/// Main entry point for init
export fn main() i32 {
    libnova.println("Nova init starting...");
    libnova.println("================================");

    // Print our PID
    const pid = syscall.getpid();
    libnova.print("Init PID: ");
    printNumber(pid);
    libnova.println("");

    // Start essential servers
    startServers();

    // Start the shell
    startShell();

    libnova.println("================================");
    libnova.println("Init entering main loop");

    // Main loop - wait for children and reap orphans
    mainLoop();

    // Init should never exit
    return 0;
}

/// Start essential userspace servers
fn startServers() void {
    libnova.println("");
    libnova.println("Starting servers...");

    // In a full implementation, we would fork and exec each server
    // For now, just log that we would start them

    // VFS Server
    libnova.println("  [*] VFS server (pending)");

    // Device Manager
    libnova.println("  [*] Device manager (pending)");

    // Console Server
    libnova.println("  [*] Console server (pending)");

    libnova.println("Servers started.");
    libnova.println("");
}

/// Start the shell process
fn startShell() void {
    libnova.println("Starting shell...");

    // Spawn the shell binary via syscall
    // The path is null-terminated for the kernel's vfs.lookup
    const shell_path = "/shell";
    const child_pid = syscall.spawn(shell_path, null, null);

    if (child_pid < 0) {
        libnova.println("ERROR: Failed to spawn shell");
        return;
    }

    // Track the child
    trackChild(child_pid, "shell");
    libnova.print("Shell started with PID ");
    printNumber(child_pid);
    libnova.println("");
}

/// Track a child process
fn trackChild(pid: i32, name: []const u8) void {
    if (child_count >= MAX_CHILDREN) return;

    for (&children) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .pid = pid, .name = name };
            child_count += 1;
            return;
        }
    }
}

/// Untrack a child process
fn untrackChild(pid: i32) void {
    for (&children) |*slot| {
        if (slot.*) |child| {
            if (child.pid == pid) {
                slot.* = null;
                child_count -= 1;
                return;
            }
        }
    }
}

/// Main loop - wait for children and handle orphans
fn mainLoop() void {
    while (true) {
        // Wait for any child to exit
        var status: i32 = 0;
        const exited_pid = syscall.wait(-1, &status);

        if (exited_pid > 0) {
            // A child exited
            libnova.print("Child ");
            printNumber(exited_pid);
            libnova.print(" exited with status ");
            printNumber(status);
            libnova.println("");

            untrackChild(exited_pid);

            // If no children left, respawn shell
            if (child_count == 0) {
                libnova.println("All children exited, respawning shell...");
                startShell();
            }
        } else {
            // No child to wait for, yield
            syscall.yield();
        }
    }
}

/// Adopt orphaned processes (called when a process's parent exits)
fn adoptOrphan(pid: i32) void {
    trackChild(pid, "orphan");
    libnova.print("Adopted orphan process ");
    printNumber(pid);
    libnova.println("");
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
