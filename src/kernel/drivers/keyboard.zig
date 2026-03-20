// PS/2 Keyboard Driver
//
// Handles keyboard input via PS/2 controller.
// Translates scancodes to keycodes and buffers input.

const cpu = @import("../arch/x86_64/cpu.zig");
const console = @import("../lib/console.zig");
const scheduler = @import("../proc/scheduler.zig");
const Thread = @import("../proc/thread.zig").Thread;

// PS/2 controller ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;
const COMMAND_PORT: u16 = 0x64;

// Status register bits
const STATUS_OUTPUT_FULL: u8 = 1 << 0;
const STATUS_INPUT_FULL: u8 = 1 << 1;

// Keyboard commands
const CMD_SET_LEDS: u8 = 0xED;
const CMD_ECHO: u8 = 0xEE;
const CMD_GET_SET_SCANCODE: u8 = 0xF0;
const CMD_ENABLE_SCANNING: u8 = 0xF4;
const CMD_DISABLE_SCANNING: u8 = 0xF5;
const CMD_RESET: u8 = 0xFF;

// Key states
pub const KeyState = enum {
    pressed,
    released,
};

// Key event
pub const KeyEvent = struct {
    scancode: u8,
    keycode: u8,
    state: KeyState,
    shift: bool,
    ctrl: bool,
    alt: bool,
};

// Keyboard buffer
const BUFFER_SIZE: usize = 64;
var key_buffer: [BUFFER_SIZE]KeyEvent = undefined;
var buffer_head: usize = 0;
var buffer_tail: usize = 0;

// Modifier state
var shift_held: bool = false;
var ctrl_held: bool = false;
var alt_held: bool = false;
var caps_lock: bool = false;

// Waiting threads
var waiting_thread: ?*Thread = null;

// Scancode to ASCII mapping (US QWERTY, lowercase)
const scancode_to_ascii = [_]u8{
    0,    0x1B, '1',  '2',  '3',  '4',  '5',  '6', // 0x00-0x07
    '7',  '8',  '9',  '0',  '-',  '=',  0x08, '\t', // 0x08-0x0F
    'q',  'w',  'e',  'r',  't',  'y',  'u',  'i', // 0x10-0x17
    'o',  'p',  '[',  ']',  '\n', 0,    'a',  's', // 0x18-0x1F
    'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';', // 0x20-0x27
    '\'', '`',  0,    '\\', 'z',  'x',  'c',  'v', // 0x28-0x2F
    'b',  'n',  'm',  ',',  '.',  '/',  0,    '*', // 0x30-0x37
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F
    0,    0,    0,    0,    0,    0,    0,    '7', // 0x40-0x47
    '8',  '9',  '-',  '4',  '5',  '6',  '+',  '1', // 0x48-0x4F
    '2',  '3',  '0',  '.',  0,    0,    0,    0, // 0x50-0x57
};

// Shifted scancode to ASCII mapping
const scancode_to_ascii_shift = [_]u8{
    0,    0x1B, '!',  '@',  '#',  '$',  '%',  '^', // 0x00-0x07
    '&',  '*',  '(',  ')',  '_',  '+',  0x08, '\t', // 0x08-0x0F
    'Q',  'W',  'E',  'R',  'T',  'Y',  'U',  'I', // 0x10-0x17
    'O',  'P',  '{',  '}',  '\n', 0,    'A',  'S', // 0x18-0x1F
    'D',  'F',  'G',  'H',  'J',  'K',  'L',  ':', // 0x20-0x27
    '"',  '~',  0,    '|',  'Z',  'X',  'C',  'V', // 0x28-0x2F
    'B',  'N',  'M',  '<',  '>',  '?',  0,    '*', // 0x30-0x37
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F
};

// Special keycodes
pub const KEY_ESCAPE: u8 = 0x01;
pub const KEY_BACKSPACE: u8 = 0x0E;
pub const KEY_TAB: u8 = 0x0F;
pub const KEY_ENTER: u8 = 0x1C;
pub const KEY_LCTRL: u8 = 0x1D;
pub const KEY_LSHIFT: u8 = 0x2A;
pub const KEY_RSHIFT: u8 = 0x36;
pub const KEY_LALT: u8 = 0x38;
pub const KEY_CAPS_LOCK: u8 = 0x3A;
pub const KEY_F1: u8 = 0x3B;
pub const KEY_F12: u8 = 0x58;
pub const KEY_UP: u8 = 0x48;
pub const KEY_DOWN: u8 = 0x50;
pub const KEY_LEFT: u8 = 0x4B;
pub const KEY_RIGHT: u8 = 0x4D;

var initialized: bool = false;

/// Initialize the keyboard driver
pub fn init() void {
    // Wait for controller to be ready
    waitInputEmpty();

    // Enable keyboard scanning
    cpu.outb(DATA_PORT, CMD_ENABLE_SCANNING);
    waitAck();

    // Clear any pending data
    while ((cpu.inb(STATUS_PORT) & STATUS_OUTPUT_FULL) != 0) {
        _ = cpu.inb(DATA_PORT);
    }

    initialized = true;
    console.log(.info, "PS/2 keyboard initialized", .{});
}

/// Wait for input buffer to be empty
fn waitInputEmpty() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if ((cpu.inb(STATUS_PORT) & STATUS_INPUT_FULL) == 0) {
            return;
        }
    }
}

/// Wait for ACK from keyboard
fn waitAck() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if ((cpu.inb(STATUS_PORT) & STATUS_OUTPUT_FULL) != 0) {
            const data = cpu.inb(DATA_PORT);
            if (data == 0xFA) return; // ACK
        }
    }
}

/// Handle keyboard interrupt (IRQ 1)
pub fn handleInterrupt() void {
    const scancode = cpu.inb(DATA_PORT);

    // Check for key release (bit 7 set)
    const released = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;

    // Update modifier state
    switch (code) {
        KEY_LSHIFT, KEY_RSHIFT => {
            shift_held = !released;
            return;
        },
        KEY_LCTRL => {
            ctrl_held = !released;
            return;
        },
        KEY_LALT => {
            alt_held = !released;
            return;
        },
        KEY_CAPS_LOCK => {
            if (!released) {
                caps_lock = !caps_lock;
            }
            return;
        },
        else => {},
    }

    // Get ASCII value
    var ascii: u8 = 0;
    if (code < scancode_to_ascii.len) {
        const use_shift = shift_held != caps_lock; // XOR for caps lock effect
        if (use_shift and code < scancode_to_ascii_shift.len) {
            ascii = scancode_to_ascii_shift[code];
        } else {
            ascii = scancode_to_ascii[code];
        }
    }

    // Create key event
    const event = KeyEvent{
        .scancode = scancode,
        .keycode = ascii,
        .state = if (released) .released else .pressed,
        .shift = shift_held,
        .ctrl = ctrl_held,
        .alt = alt_held,
    };

    // Add to buffer
    bufferPut(event);

    // Wake waiting thread
    if (waiting_thread) |t| {
        waiting_thread = null;
        scheduler.unblock(t);
    }
}

/// Put a key event in the buffer
fn bufferPut(event: KeyEvent) void {
    const next_head = (buffer_head + 1) % BUFFER_SIZE;
    if (next_head != buffer_tail) {
        key_buffer[buffer_head] = event;
        buffer_head = next_head;
    }
    // Buffer full - drop the event
}

/// Get a key event from the buffer (non-blocking)
pub fn getKey() ?KeyEvent {
    if (buffer_tail == buffer_head) {
        return null;
    }
    const event = key_buffer[buffer_tail];
    buffer_tail = (buffer_tail + 1) % BUFFER_SIZE;
    return event;
}

/// Read a character (blocking)
pub fn readChar() u8 {
    while (true) {
        if (getKey()) |event| {
            if (event.state == .pressed and event.keycode != 0) {
                return event.keycode;
            }
        }
        // Would block here in real implementation
        asm volatile ("pause");
    }
}

/// Read a line into buffer (blocking)
pub fn readLine(buf: []u8) usize {
    var pos: usize = 0;
    while (pos < buf.len - 1) {
        const c = readChar();

        if (c == '\n') {
            buf[pos] = 0;
            return pos;
        } else if (c == 0x08) { // Backspace
            if (pos > 0) {
                pos -= 1;
            }
        } else if (c >= 0x20) { // Printable
            buf[pos] = c;
            pos += 1;
        }
    }
    buf[pos] = 0;
    return pos;
}

/// Check if keyboard input is available
pub fn hasInput() bool {
    return buffer_tail != buffer_head;
}

/// Set LED state (caps, num, scroll lock)
pub fn setLeds(caps: bool, num: bool, scroll: bool) void {
    var leds: u8 = 0;
    if (scroll) leds |= 1;
    if (num) leds |= 2;
    if (caps) leds |= 4;

    waitInputEmpty();
    cpu.outb(DATA_PORT, CMD_SET_LEDS);
    waitAck();
    waitInputEmpty();
    cpu.outb(DATA_PORT, leds);
    waitAck();
}

/// Check if keyboard is initialized
pub fn isInitialized() bool {
    return initialized;
}
