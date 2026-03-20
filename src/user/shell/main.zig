// Simple Shell
//
// Basic command shell for Nova microkernel.
// Handles command input and built-in commands.

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

// Input buffer
const INPUT_BUFFER_SIZE: usize = 128;
var input_buffer: [INPUT_BUFFER_SIZE]u8 = [_]u8{0} ** INPUT_BUFFER_SIZE;
var input_pos: usize = 0;

// Command history
const HISTORY_SIZE: usize = 8;
var history: [HISTORY_SIZE][INPUT_BUFFER_SIZE]u8 = [_][INPUT_BUFFER_SIZE]u8{[_]u8{0} ** INPUT_BUFFER_SIZE} ** HISTORY_SIZE;
var history_count: usize = 0;
var history_idx: usize = 0;

/// Main entry point for shell
pub export fn main() i32 {
    libnova.println("");
    libnova.println("Nova Shell v0.1.0");
    libnova.println("Type 'help' for available commands");
    libnova.println("");

    // Main command loop
    while (true) {
        // Print prompt
        libnova.print("nova> ");

        // Read command
        const len = readLine(&input_buffer);

        if (len > 0) {
            // Add to history
            addToHistory(input_buffer[0..len]);

            // Process command
            processCommand(input_buffer[0..len]);
        }
    }

    return 0;
}

/// Read a line of input
fn readLine(buf: []u8) usize {
    var pos: usize = 0;

    while (pos < buf.len - 1) {
        // In a full implementation, we'd receive characters via IPC from console server
        // For now, use a polling approach that yields between checks

        // Try to get keyboard input
        const c = getChar();

        if (c == 0) {
            // No input available, yield
            syscall.yield();
            continue;
        }

        if (c == '\n' or c == '\r') {
            buf[pos] = 0;
            libnova.println(""); // Echo newline
            return pos;
        } else if (c == 0x08 or c == 0x7F) {
            // Backspace
            if (pos > 0) {
                pos -= 1;
                // Echo backspace
                const bs = [_]u8{ 0x08, ' ', 0x08 };
                _ = syscall.debug_print(&bs);
            }
        } else if (c >= 0x20 and c < 0x7F) {
            // Printable character
            buf[pos] = c;
            pos += 1;
            // Echo character
            const echo = [1]u8{c};
            _ = syscall.debug_print(&echo);
        }
    }

    buf[pos] = 0;
    return pos;
}

/// Get a character from input (returns 0 if none available)
fn getChar() u8 {
    // In a full implementation:
    // 1. Send MSG_GETCHAR to console server
    // 2. Receive response with character
    // For now, return 0 (no input) and let readLine yield

    // Placeholder: This would be IPC to console server
    return 0;
}

/// Add command to history
fn addToHistory(cmd: []const u8) void {
    if (cmd.len == 0) return;

    const idx = history_count % HISTORY_SIZE;
    for (cmd, 0..) |c, i| {
        history[idx][i] = c;
    }
    history[idx][cmd.len] = 0;

    history_count += 1;
    history_idx = history_count;
}

/// Process a command
fn processCommand(cmd: []const u8) void {
    // Skip leading whitespace
    var start: usize = 0;
    while (start < cmd.len and cmd[start] == ' ') : (start += 1) {}

    if (start >= cmd.len) return; // Empty command

    const trimmed = cmd[start..];

    // Built-in commands
    if (strStartsWith(trimmed, "help")) {
        cmdHelp();
    } else if (strStartsWith(trimmed, "echo ")) {
        cmdEcho(trimmed[5..]);
    } else if (strEquals(trimmed, "echo")) {
        libnova.println("");
    } else if (strEquals(trimmed, "pid")) {
        cmdPid();
    } else if (strEquals(trimmed, "tid")) {
        cmdTid();
    } else if (strEquals(trimmed, "time")) {
        cmdTime();
    } else if (strEquals(trimmed, "mem")) {
        cmdMem();
    } else if (strEquals(trimmed, "clear")) {
        cmdClear();
    } else if (strEquals(trimmed, "exit")) {
        cmdExit();
    } else if (strEquals(trimmed, "history")) {
        cmdHistory();
    } else if (strEquals(trimmed, "uptime")) {
        cmdUptime();
    } else {
        libnova.print("Unknown command: ");
        for (trimmed) |c| {
            if (c == 0) break;
            const buf = [1]u8{c};
            libnova.print(&buf);
        }
        libnova.println("");
        libnova.println("Type 'help' for available commands");
    }
}

/// Help command
fn cmdHelp() void {
    libnova.println("Available commands:");
    libnova.println("  help     - Show this help message");
    libnova.println("  echo     - Echo text to console");
    libnova.println("  pid      - Show current process ID");
    libnova.println("  tid      - Show current thread ID");
    libnova.println("  time     - Show system time");
    libnova.println("  uptime   - Show system uptime");
    libnova.println("  mem      - Show memory info");
    libnova.println("  history  - Show command history");
    libnova.println("  clear    - Clear screen");
    libnova.println("  exit     - Exit shell");
}

/// Echo command
fn cmdEcho(text: []const u8) void {
    for (text) |c| {
        if (c == 0) break;
        const buf = [1]u8{c};
        libnova.print(&buf);
    }
    libnova.println("");
}

/// PID command
fn cmdPid() void {
    const pid = syscall.getpid();
    libnova.print("PID: ");
    printNumber(pid);
    libnova.println("");
}

/// TID command
fn cmdTid() void {
    const tid = syscall.gettid();
    libnova.print("TID: ");
    printNumber(tid);
    libnova.println("");
}

/// Time command
fn cmdTime() void {
    const ns = syscall.gettime();
    const ms = ns / 1_000_000;
    libnova.print("Time: ");
    printNumber64(ms);
    libnova.println("ms since boot");
}

/// Uptime command
fn cmdUptime() void {
    const ns = syscall.gettime();
    const secs = ns / 1_000_000_000;
    const mins = secs / 60;
    const hours = mins / 60;

    libnova.print("Uptime: ");
    if (hours > 0) {
        printNumber64(hours);
        libnova.print("h ");
    }
    printNumber64(mins % 60);
    libnova.print("m ");
    printNumber64(secs % 60);
    libnova.println("s");
}

/// Memory info command
fn cmdMem() void {
    libnova.println("Memory info:");
    libnova.println("  (detailed stats not implemented)");
}

/// History command
fn cmdHistory() void {
    libnova.println("Command history:");
    const start = if (history_count > HISTORY_SIZE) history_count - HISTORY_SIZE else 0;
    var i = start;
    while (i < history_count) : (i += 1) {
        const idx = i % HISTORY_SIZE;
        libnova.print("  ");
        printNumber(@intCast(i + 1));
        libnova.print(": ");
        for (history[idx]) |c| {
            if (c == 0) break;
            const buf = [1]u8{c};
            libnova.print(&buf);
        }
        libnova.println("");
    }
}

/// Clear screen command
fn cmdClear() void {
    // ANSI escape sequence to clear screen
    const clear_seq = "\x1b[2J\x1b[H";
    _ = syscall.debug_print(clear_seq);
}

/// Exit command
fn cmdExit() void {
    libnova.println("Exiting shell...");
    syscall.exit(0);
}

// ============= Utility Functions =============

fn strEquals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn strStartsWith(str: []const u8, prefix: []const u8) bool {
    if (str.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (str[i] != c) return false;
    }
    return true;
}

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

fn printNumber64(n: u64) void {
    if (n >= 10) {
        printNumber64(n / 10);
    }
    const digit: u8 = @intCast((n % 10) + '0');
    const buf = [1]u8{digit};
    libnova.print(&buf);
}
