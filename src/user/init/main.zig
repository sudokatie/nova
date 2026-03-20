// Init Process
//
// First userspace process (PID 1).
// Responsible for starting servers and the shell, and reaping orphans.

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

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

    // Fork to create shell process
    const child_pid = syscall.fork();

    if (child_pid < 0) {
        libnova.println("ERROR: Failed to fork for shell");
        return;
    }

    if (child_pid == 0) {
        // Child process - this is the shell
        // In a full implementation, we'd exec the shell binary
        // For now, just run the shell code directly

        libnova.println("Shell process started");
        runShellLoop();
        syscall.exit(0);
    } else {
        // Parent (init) - track the child
        trackChild(child_pid, "shell");
        libnova.print("Shell started with PID ");
        printNumber(child_pid);
        libnova.println("");
    }
}

/// Run the shell loop (for embedded shell)
fn runShellLoop() void {
    const shell = @import("../shell/main.zig");
    _ = shell.main();
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

            // If shell exited, restart it
            var was_shell = false;
            for (children) |maybe_child| {
                if (maybe_child) |child| {
                    _ = child;
                    // Check if this was the shell
                }
            }

            // Check if no children left
            if (child_count == 0) {
                libnova.println("All children exited, respawning shell...");
                startShell();
            }

            _ = was_shell;
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
