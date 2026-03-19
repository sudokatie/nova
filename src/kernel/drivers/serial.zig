// Serial Console Driver (COM1)
//
// Provides early debug output via the serial port.
// COM1 is at I/O port 0x3F8.

const COM1: u16 = 0x3F8;

// Port offsets
const DATA: u16 = 0; // Data register (read/write)
const IER: u16 = 1; // Interrupt enable register
const FCR: u16 = 2; // FIFO control register
const LCR: u16 = 3; // Line control register
const MCR: u16 = 4; // Modem control register
const LSR: u16 = 5; // Line status register

// Line status bits
const LSR_THRE: u8 = 0x20; // Transmit holding register empty

/// Initialize the serial port
pub fn init() void {
    // Disable interrupts
    outb(COM1 + IER, 0x00);

    // Enable DLAB to set baud rate
    outb(COM1 + LCR, 0x80);

    // Set baud rate to 115200 (divisor = 1)
    outb(COM1 + DATA, 0x01); // Low byte
    outb(COM1 + IER, 0x00); // High byte

    // 8 bits, no parity, one stop bit (8N1)
    outb(COM1 + LCR, 0x03);

    // Enable FIFO, clear them, 14-byte threshold
    outb(COM1 + FCR, 0xC7);

    // Enable IRQs, RTS/DSR set
    outb(COM1 + MCR, 0x0B);

    // Set loopback mode to test serial chip
    outb(COM1 + MCR, 0x1E);

    // Send test byte
    outb(COM1 + DATA, 0xAE);

    // Check if we got it back
    if (inb(COM1 + DATA) != 0xAE) {
        // Serial port failed, but continue anyway
        return;
    }

    // Disable loopback, enable OUT1 and OUT2
    outb(COM1 + MCR, 0x0F);
}

/// Write a single byte to serial
pub fn writeByte(byte: u8) void {
    // Wait for transmit buffer to be empty
    while ((inb(COM1 + LSR) & LSR_THRE) == 0) {}
    outb(COM1 + DATA, byte);
}

/// Write a string to serial
pub fn writeString(str: []const u8) void {
    for (str) |byte| {
        if (byte == '\n') {
            writeByte('\r');
        }
        writeByte(byte);
    }
}

/// Write an integer (decimal)
pub fn writeInt(value: u64) void {
    if (value == 0) {
        writeByte('0');
        return;
    }

    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var v = value;

    while (v > 0) {
        buf[i] = @intCast((v % 10) + '0');
        v /= 10;
        i += 1;
    }

    // Print in reverse order
    while (i > 0) {
        i -= 1;
        writeByte(buf[i]);
    }
}

/// Write a hex value
pub fn writeHex(value: u64) void {
    const hex_chars = "0123456789ABCDEF";
    var printed = false;

    var i: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(value >> i);
        if (nibble != 0 or printed or i == 0) {
            writeByte(hex_chars[nibble]);
            printed = true;
        }
        if (i == 0) break;
        i -= 4;
    }
}

// Port I/O functions
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}
