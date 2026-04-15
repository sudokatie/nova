// Userspace Keyboard Driver
//
// PS/2 keyboard driver running in userspace.
// Demonstrates the device capability system:
// - Requests I/O ports 0x60, 0x64
// - Requests IRQ 1
// - Receives IRQ notifications via IPC
// - Translates scancodes to key events

const syscall = @import("../../libnova/syscall.zig");

// PS/2 keyboard I/O ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;
const COMMAND_PORT: u16 = 0x64;

// Keyboard IRQ
const KEYBOARD_IRQ: u8 = 1;

// Status register bits
const STATUS_OUTPUT_FULL: u8 = 0x01;
const STATUS_INPUT_FULL: u8 = 0x02;

// Key event types
pub const KeyEventType = enum(u8) {
    key_down = 0,
    key_up = 1,
};

// Key event structure (sent to clients)
pub const KeyEvent = extern struct {
    event_type: KeyEventType,
    scancode: u8,
    keycode: u8,
    modifiers: u8,
};

// Modifier key state
const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    caps_lock: bool = false,

    fn toU8(self: Modifiers) u8 {
        var result: u8 = 0;
        if (self.shift) result |= 0x01;
        if (self.ctrl) result |= 0x02;
        if (self.alt) result |= 0x04;
        if (self.caps_lock) result |= 0x08;
        return result;
    }
};

// Driver state
var modifiers: Modifiers = .{};
var server_port: u32 = 0;
var irq_notify_port: u32 = 0;
var extended_scancode: bool = false;

// Message tags
const MSG_TAG_IRQ: u32 = 0x49525100; // "IRQ\0"
const MSG_TAG_KEY_EVENT: u32 = 0x4B455900; // "KEY\0"

// Simple scancode to ASCII mapping (US layout, lowercase only)
const scancode_to_ascii = [_]u8{
    0,    0,    '1', '2', '3', '4', '5', '6', // 0x00-0x07
    '7',  '8',  '9', '0', '-', '=', 0,   0,   // 0x08-0x0F (0x0E=backspace, 0x0F=tab)
    'q',  'w',  'e', 'r', 't', 'y', 'u', 'i', // 0x10-0x17
    'o',  'p',  '[', ']', 0,   0,   'a', 's', // 0x18-0x1F (0x1C=enter, 0x1D=lctrl)
    'd',  'f',  'g', 'h', 'j', 'k', 'l', ';', // 0x20-0x27
    '\'', '`',  0,   '\\','z', 'x', 'c', 'v', // 0x28-0x2F (0x2A=lshift)
    'b',  'n',  'm', ',', '.', '/', 0,   '*', // 0x30-0x37 (0x36=rshift)
    0,    ' ',  0,   0,   0,   0,   0,   0,   // 0x38-0x3F (0x38=lalt, 0x3A=caps)
    0,    0,    0,   0,   0,   0,   0,   0,   // 0x40-0x47
    0,    0,    0,   0,   0,   0,   0,   0,   // 0x48-0x4F
    0,    0,    0,   0,   0,   0,   0,   0,   // 0x50-0x57
    0,    0,    0,   0,   0,   0,   0,   0,   // 0x58-0x5F
};

// Special key scancodes
const SC_LSHIFT: u8 = 0x2A;
const SC_RSHIFT: u8 = 0x36;
const SC_LCTRL: u8 = 0x1D;
const SC_LALT: u8 = 0x38;
const SC_CAPS: u8 = 0x3A;
const SC_EXTENDED: u8 = 0xE0;
const SC_RELEASE: u8 = 0x80; // OR'd with scancode for release

/// Initialize the keyboard driver
fn init() !void {
    // Request I/O port access
    if (syscall.request_ioport(DATA_PORT, 1) < 0) {
        syscall.debug_print("kbd: failed to request data port\n");
        return error.PortRequestFailed;
    }

    if (syscall.request_ioport(STATUS_PORT, 1) < 0) {
        syscall.debug_print("kbd: failed to request status port\n");
        return error.PortRequestFailed;
    }

    // Create a port for receiving IRQ notifications
    // In a real implementation, we'd use port_create syscall
    // For now, use a fixed port ID that the kernel knows about
    irq_notify_port = 100; // Fixed port for keyboard driver

    // Request IRQ 1 with our notification port
    if (syscall.request_irq(KEYBOARD_IRQ, irq_notify_port) < 0) {
        syscall.debug_print("kbd: failed to request IRQ\n");
        return error.IrqRequestFailed;
    }

    // Create server port for clients to receive key events
    server_port = 101; // Fixed port for key events

    syscall.debug_print("kbd: userspace keyboard driver initialized\n");
}

/// Read a byte from the keyboard data port
fn readData() u8 {
    const result = syscall.inb(DATA_PORT);
    if (result < 0) {
        return 0;
    }
    return @truncate(@as(u32, @intCast(result)));
}

/// Check if data is available
fn dataAvailable() bool {
    const status = syscall.inb(STATUS_PORT);
    if (status < 0) return false;
    return (@as(u8, @truncate(@as(u32, @intCast(status)))) & STATUS_OUTPUT_FULL) != 0;
}

/// Process a scancode and generate key event
fn processScancode(scancode: u8) ?KeyEvent {
    // Handle extended scancode prefix
    if (scancode == SC_EXTENDED) {
        extended_scancode = true;
        return null;
    }

    const is_release = (scancode & SC_RELEASE) != 0;
    const code = scancode & 0x7F;

    // Update modifier state
    switch (code) {
        SC_LSHIFT, SC_RSHIFT => {
            modifiers.shift = !is_release;
            return null;
        },
        SC_LCTRL => {
            modifiers.ctrl = !is_release;
            return null;
        },
        SC_LALT => {
            modifiers.alt = !is_release;
            return null;
        },
        SC_CAPS => {
            if (!is_release) {
                modifiers.caps_lock = !modifiers.caps_lock;
            }
            return null;
        },
        else => {},
    }

    // Generate key event
    var keycode: u8 = 0;
    if (code < scancode_to_ascii.len) {
        keycode = scancode_to_ascii[code];
    }

    extended_scancode = false;

    return KeyEvent{
        .event_type = if (is_release) .key_up else .key_down,
        .scancode = scancode,
        .keycode = keycode,
        .modifiers = modifiers.toU8(),
    };
}

/// Handle an IRQ notification
fn handleIrq() void {
    // Read all available scancodes
    while (dataAvailable()) {
        const scancode = readData();

        if (processScancode(scancode)) |event| {
            // Send key event to any listening clients
            sendKeyEvent(&event);
        }
    }
}

/// Send a key event to clients
fn sendKeyEvent(event: *const KeyEvent) void {
    // Create message with key event data
    var msg: syscall.Message = .{
        .tag = MSG_TAG_KEY_EVENT,
        .len = @sizeOf(KeyEvent),
        .data = undefined,
    };

    // Copy event into message data
    const event_bytes = @as([*]const u8, @ptrCast(event))[0..@sizeOf(KeyEvent)];
    for (0..event_bytes.len) |i| {
        msg.data[i] = event_bytes[i];
    }

    // In a real implementation, we'd iterate over connected clients
    // For now, just log the event
    if (event.event_type == .key_down and event.keycode != 0) {
        var buf: [32]u8 = undefined;
        buf[0] = 'k';
        buf[1] = 'b';
        buf[2] = 'd';
        buf[3] = ':';
        buf[4] = ' ';
        buf[5] = event.keycode;
        buf[6] = '\n';
        _ = syscall.debug_print(buf[0..7]);
    }
}

/// Main driver loop
fn driverLoop() void {
    var msg: syscall.Message = undefined;

    while (true) {
        // Wait for IRQ notification
        const sender = syscall.receive(-1, &msg); // -1 = any sender
        _ = sender;

        if (msg.tag == MSG_TAG_IRQ) {
            handleIrq();
        }
    }
}

/// Driver entry point
pub fn main() void {
    syscall.debug_print("kbd: starting userspace keyboard driver\n");

    init() catch |err| {
        _ = err;
        syscall.debug_print("kbd: initialization failed\n");
        syscall.exit(1);
    };

    // Enter main loop
    driverLoop();
}

// Entry point for userspace
pub export fn _start() callconv(.Naked) noreturn {
    // Set up stack and call main
    asm volatile (
        \\call main
        \\mov $13, %%rax
        \\xor %%rdi, %%rdi
        \\syscall
        :
        :
        : "rax", "rdi"
    );
    unreachable;
}
