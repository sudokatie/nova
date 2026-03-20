// Console Server
//
// Console input/output server for Nova microkernel.
// Handles keyboard input and screen output via IPC.

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

// Console message types
pub const MSG_PUTCHAR: u32 = 1;
pub const MSG_PUTS: u32 = 2;
pub const MSG_GETCHAR: u32 = 3;
pub const MSG_GETS: u32 = 4;
pub const MSG_CLEAR: u32 = 5;
pub const MSG_SET_COLOR: u32 = 6;

// Console colors
pub const Color = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

// Input buffer
const INPUT_BUFFER_SIZE: usize = 256;
var input_buffer: [INPUT_BUFFER_SIZE]u8 = [_]u8{0} ** INPUT_BUFFER_SIZE;
var input_head: usize = 0;
var input_tail: usize = 0;

// Line buffer for line editing
const LINE_BUFFER_SIZE: usize = 128;
var line_buffer: [LINE_BUFFER_SIZE]u8 = [_]u8{0} ** LINE_BUFFER_SIZE;
var line_pos: usize = 0;

// Console state
var current_fg: Color = .light_gray;
var current_bg: Color = .black;

/// Main entry point for console server
export fn main() i32 {
    libnova.println("Console server starting...");

    // Print welcome message
    libnova.println("Nova Console Server v0.1.0");
    libnova.println("Ready for input/output");

    // Main message loop
    while (true) {
        // Process input
        processInput();

        // Would handle IPC requests here
        syscall.yield();
    }

    return 0;
}

/// Process pending input
fn processInput() void {
    // In a full implementation, this would:
    // 1. Read from keyboard input queue (via device manager IPC)
    // 2. Handle line editing (backspace, etc.)
    // 3. Echo characters to screen
    // 4. Buffer completed lines for client reads
}

/// Add character to input buffer
fn bufferPut(c: u8) void {
    const next_head = (input_head + 1) % INPUT_BUFFER_SIZE;
    if (next_head != input_tail) {
        input_buffer[input_head] = c;
        input_head = next_head;
    }
}

/// Get character from input buffer
fn bufferGet() ?u8 {
    if (input_tail == input_head) return null;
    const c = input_buffer[input_tail];
    input_tail = (input_tail + 1) % INPUT_BUFFER_SIZE;
    return c;
}

/// Check if input available
fn inputAvailable() bool {
    return input_tail != input_head;
}

/// Handle line input
fn handleLineInput(c: u8) void {
    switch (c) {
        '\n', '\r' => {
            // Line complete
            line_buffer[line_pos] = 0;
            line_pos = 0;
            libnova.println(""); // Echo newline
        },
        0x08, 0x7F => {
            // Backspace
            if (line_pos > 0) {
                line_pos -= 1;
                // Echo backspace (move back, space, move back)
                const bs = [_]u8{ 0x08, ' ', 0x08 };
                _ = syscall.debug_print(&bs);
            }
        },
        else => {
            // Regular character
            if (line_pos < LINE_BUFFER_SIZE - 1 and c >= 0x20 and c < 0x7F) {
                line_buffer[line_pos] = c;
                line_pos += 1;
                // Echo character
                const buf = [1]u8{c};
                _ = syscall.debug_print(&buf);
            }
        },
    }
}

/// Set console colors
fn setColor(fg: Color, bg: Color) void {
    current_fg = fg;
    current_bg = bg;
}

/// Clear screen
fn clearScreen() void {
    // Would write to video memory or framebuffer
    // For serial console, send ANSI escape sequence
    const clear_seq = "\x1b[2J\x1b[H"; // Clear and home
    _ = syscall.debug_print(clear_seq);
}

/// Print with colors
fn printColored(s: []const u8, fg: Color, bg: Color) void {
    // For serial, use ANSI colors
    _ = fg;
    _ = bg;
    _ = syscall.debug_print(s);
}

/// Get current line
fn getCurrentLine() []const u8 {
    return line_buffer[0..line_pos];
}

/// Read a complete line (blocking)
fn readLine(buf: []u8) usize {
    var pos: usize = 0;

    while (pos < buf.len - 1) {
        // Wait for input
        while (!inputAvailable()) {
            syscall.yield();
        }

        if (bufferGet()) |c| {
            if (c == '\n' or c == '\r') {
                buf[pos] = 0;
                return pos;
            } else if (c == 0x08 or c == 0x7F) {
                if (pos > 0) pos -= 1;
            } else if (c >= 0x20 and c < 0x7F) {
                buf[pos] = c;
                pos += 1;
            }
        }
    }

    buf[pos] = 0;
    return pos;
}
