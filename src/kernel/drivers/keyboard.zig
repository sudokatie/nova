// PS/2 Keyboard Driver
//
// Handles keyboard input via I/O APIC interrupt.
// Provides a character buffer for userspace to read from.

const cpu = @import("../arch/x86_64/cpu.zig");
const console = @import("../lib/console.zig");
const apic = @import("../arch/x86_64/apic.zig");

// PS/2 keyboard ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;
const COMMAND_PORT: u16 = 0x64;

// Status register bits
const STATUS_OUTPUT_FULL: u8 = 0x01;
const STATUS_INPUT_FULL: u8 = 0x02;

// Keyboard commands
const CMD_SET_LEDS: u8 = 0xED;
const CMD_ECHO: u8 = 0xEE;
const CMD_SCANCODE_SET: u8 = 0xF0;
const CMD_ENABLE: u8 = 0xF4;
const CMD_RESET: u8 = 0xFF;

// Circular buffer for keyboard input
const BUFFER_SIZE: usize = 256;
var key_buffer: [BUFFER_SIZE]u8 = [_]u8{0} ** BUFFER_SIZE;
var buffer_head: usize = 0;
var buffer_tail: usize = 0;

// Modifier key state
var shift_pressed: bool = false;
var ctrl_pressed: bool = false;
var alt_pressed: bool = false;
var caps_lock: bool = false;

// US keyboard scancode to ASCII (set 1, make codes)
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

// Special scancodes
const SCANCODE_LSHIFT: u8 = 0x2A;
const SCANCODE_RSHIFT: u8 = 0x36;
const SCANCODE_CTRL: u8 = 0x1D;
const SCANCODE_ALT: u8 = 0x38;
const SCANCODE_CAPS: u8 = 0x3A;
const SCANCODE_EXTENDED: u8 = 0xE0;

var initialized: bool = false;

/// Initialize the keyboard driver
pub fn init() void {
    // Wait for keyboard controller to be ready
    waitInput();

    // Enable keyboard
    cpu.outb(COMMAND_PORT, 0xAE); // Enable first PS/2 port
    waitInput();

    // Read and discard any pending data
    while ((cpu.inb(STATUS_PORT) & STATUS_OUTPUT_FULL) != 0) {
        _ = cpu.inb(DATA_PORT);
    }

    // Enable scanning
    waitInput();
    cpu.outb(DATA_PORT, CMD_ENABLE);

    // Wait for ACK
    waitOutput();
    _ = cpu.inb(DATA_PORT);

    initialized = true;
    console.log(.info, "Keyboard initialized", .{});
}

/// Wait for input buffer to be empty
fn waitInput() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if ((cpu.inb(STATUS_PORT) & STATUS_INPUT_FULL) == 0) {
            return;
        }
    }
}

/// Wait for output buffer to be full
fn waitOutput() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if ((cpu.inb(STATUS_PORT) & STATUS_OUTPUT_FULL) != 0) {
            return;
        }
    }
}

/// Handle keyboard interrupt
pub fn handleInterrupt() void {
    // Read scancode
    const scancode = cpu.inb(DATA_PORT);

    // Handle extended scancodes
    if (scancode == SCANCODE_EXTENDED) {
        // Next byte is the extended code - we'll handle it on next interrupt
        return;
    }

    // Check for key release (high bit set)
    const is_release = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;

    // Handle modifier keys
    if (code == SCANCODE_LSHIFT or code == SCANCODE_RSHIFT) {
        shift_pressed = !is_release;
        return;
    }
    if (code == SCANCODE_CTRL) {
        ctrl_pressed = !is_release;
        return;
    }
    if (code == SCANCODE_ALT) {
        alt_pressed = !is_release;
        return;
    }
    if (code == SCANCODE_CAPS and !is_release) {
        caps_lock = !caps_lock;
        return;
    }

    // Only process key presses, not releases
    if (is_release) return;

    // Convert scancode to ASCII
    var ascii: u8 = 0;
    if (code < scancode_to_ascii.len) {
        if (shift_pressed) {
            if (code < scancode_to_ascii_shift.len) {
                ascii = scancode_to_ascii_shift[code];
            }
        } else {
            ascii = scancode_to_ascii[code];
        }

        // Handle caps lock for letters
        if (caps_lock and ascii >= 'a' and ascii <= 'z') {
            ascii = ascii - 'a' + 'A';
        } else if (caps_lock and ascii >= 'A' and ascii <= 'Z') {
            ascii = ascii - 'A' + 'a';
        }
    }

    if (ascii != 0) {
        // Handle Ctrl+C
        if (ctrl_pressed and (ascii == 'c' or ascii == 'C')) {
            ascii = 0x03; // ETX (Ctrl+C)
        }

        // Add to buffer
        pushChar(ascii);

        // Echo to console for debugging
        // console.putChar(ascii);
    }
}

/// Push a character to the buffer
fn pushChar(c: u8) void {
    const next_head = (buffer_head + 1) % BUFFER_SIZE;

    // Don't overwrite unread data
    if (next_head != buffer_tail) {
        key_buffer[buffer_head] = c;
        buffer_head = next_head;
    }
}

/// Get a character from the buffer (non-blocking)
/// Returns 0 if buffer is empty
pub fn getChar() u8 {
    if (buffer_tail == buffer_head) {
        return 0; // Buffer empty
    }

    const c = key_buffer[buffer_tail];
    buffer_tail = (buffer_tail + 1) % BUFFER_SIZE;
    return c;
}

/// Check if there's data available
pub fn hasData() bool {
    return buffer_tail != buffer_head;
}

/// Get number of characters in buffer
pub fn available() usize {
    if (buffer_head >= buffer_tail) {
        return buffer_head - buffer_tail;
    } else {
        return BUFFER_SIZE - buffer_tail + buffer_head;
    }
}

/// Blocking read - waits for a character
/// Note: This should only be called from kernel context
pub fn readCharBlocking() u8 {
    while (!hasData()) {
        // Enable interrupts and wait
        cpu.enableInterrupts();
        asm volatile ("hlt");
    }
    return getChar();
}

/// Clear the input buffer
pub fn clearBuffer() void {
    buffer_head = 0;
    buffer_tail = 0;
}

/// Check if keyboard is initialized
pub fn isInitialized() bool {
    return initialized;
}
