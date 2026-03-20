// Device Manager
//
// Device enumeration and management server for Nova microkernel.
// Manages hardware devices and provides interfaces via IPC.

const libnova = @import("../libnova/start.zig");
const syscall = @import("../libnova/syscall.zig");

// Device types
pub const DeviceType = enum(u8) {
    unknown = 0,
    serial = 1,
    keyboard = 2,
    display = 3,
    storage = 4,
    network = 5,
    timer = 6,
};

// Device states
pub const DeviceState = enum(u8) {
    unknown = 0,
    detected = 1,
    initializing = 2,
    ready = 3,
    error = 4,
    removed = 5,
};

// Device message types
pub const MSG_ENUMERATE: u32 = 1;
pub const MSG_GET_INFO: u32 = 2;
pub const MSG_OPEN_DEVICE: u32 = 3;
pub const MSG_CLOSE_DEVICE: u32 = 4;
pub const MSG_DEVICE_IOCTL: u32 = 5;

// Maximum devices
const MAX_DEVICES: usize = 32;

const Device = struct {
    valid: bool,
    dev_type: DeviceType,
    state: DeviceState,
    name: [32]u8,
    name_len: usize,
    base_port: u16,
    irq: u8,
    driver_tid: u32, // TID of driver handling this device
};

var devices: [MAX_DEVICES]Device = [_]Device{.{
    .valid = false,
    .dev_type = .unknown,
    .state = .unknown,
    .name = [_]u8{0} ** 32,
    .name_len = 0,
    .base_port = 0,
    .irq = 0,
    .driver_tid = 0,
}} ** MAX_DEVICES;

var device_count: usize = 0;

/// Main entry point for device manager
export fn main() i32 {
    libnova.println("Device manager starting...");

    // Enumerate devices
    enumerateDevices();

    libnova.println("Device manager ready, waiting for requests...");

    // Main message loop
    while (true) {
        syscall.yield();
    }

    return 0;
}

/// Enumerate available devices
fn enumerateDevices() void {
    // Register built-in devices

    // Serial port (COM1)
    registerDevice(.serial, "serial0", 0x3F8, 4);

    // Keyboard (PS/2)
    registerDevice(.keyboard, "kbd0", 0x60, 1);

    // Timer (APIC)
    registerDevice(.timer, "timer0", 0, 0);

    libnova.print("  Enumerated ");
    printNumber(@intCast(device_count));
    libnova.println(" devices");
}

/// Register a device
fn registerDevice(dev_type: DeviceType, name: []const u8, port: u16, irq: u8) void {
    if (device_count >= MAX_DEVICES) return;

    var dev = &devices[device_count];
    dev.valid = true;
    dev.dev_type = dev_type;
    dev.state = .detected;
    dev.base_port = port;
    dev.irq = irq;
    dev.driver_tid = 0;

    const len = @min(name.len, 31);
    for (0..len) |i| {
        dev.name[i] = name[i];
    }
    dev.name_len = len;

    device_count += 1;
}

/// Get device by name
fn findDevice(name: []const u8) ?*Device {
    for (&devices) |*dev| {
        if (dev.valid and dev.name_len == name.len) {
            var match = true;
            for (0..name.len) |i| {
                if (dev.name[i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return dev;
        }
    }
    return null;
}

/// Get device by index
fn getDevice(idx: usize) ?*Device {
    if (idx >= MAX_DEVICES) return null;
    if (devices[idx].valid) return &devices[idx];
    return null;
}

/// Print device info
fn printDeviceInfo(dev: *const Device) void {
    libnova.print("  Device: ");
    for (dev.name[0..dev.name_len]) |c| {
        const buf = [1]u8{c};
        libnova.print(&buf);
    }
    libnova.print(" type=");
    printNumber(@intFromEnum(dev.dev_type));
    libnova.print(" port=");
    printNumber(dev.base_port);
    libnova.print(" irq=");
    printNumber(dev.irq);
    libnova.println("");
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
