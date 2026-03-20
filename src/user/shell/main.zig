// Nova Shell
//
// Simple command shell for user interaction.
// Built-in commands: help, echo, exit, pid

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

// Command buffer
var cmd_buf: [256]u8 = undefined;
var cmd_len: usize = 0;

/// Main entry point for shell
export fn main() i32 {
    libnova.println("Nova Shell v0.1");
    libnova.println("Type 'help' for commands\n");

    while (true) {
        // Print prompt
        libnova.print("nova> ");

        // Read command
        // TODO: Actually read from stdin when we have console input
        // For now, just demonstrate built-in commands

        // Process built-in commands
        // In a real shell, we'd read input and parse it
        // For now, this is a placeholder that shows the shell works

        libnova.println("(waiting for input - not yet implemented)");

        // Yield and wait
        syscall.yield();

        // For testing, break after one iteration
        break;
    }

    return 0;
}

/// Process a command line
fn processCommand(line: []const u8) void {
    // Skip empty lines
    if (line.len == 0) return;

    // Built-in commands
    if (strEq(line, "help")) {
        showHelp();
    } else if (strEq(line, "exit")) {
        syscall.exit(0);
    } else if (strEq(line, "pid")) {
        showPid();
    } else if (startsWith(line, "echo ")) {
        libnova.println(line[5..]);
    } else {
        libnova.print("Unknown command: ");
        libnova.println(line);
    }
}

fn showHelp() void {
    libnova.println("Available commands:");
    libnova.println("  help  - Show this help");
    libnova.println("  echo  - Print text");
    libnova.println("  pid   - Show process ID");
    libnova.println("  exit  - Exit shell");
}

fn showPid() void {
    libnova.print("PID: ");
    printNumber(syscall.getpid());
    libnova.print(", TID: ");
    printNumber(syscall.gettid());
    libnova.print("\n");
}

/// Compare two strings
fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// Check if string starts with prefix
fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return strEq(s[0..prefix.len], prefix);
}

/// Print a number
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
