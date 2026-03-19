// Kernel Console Output
//
// Provides formatted output for kernel debugging and logging.
// Wraps the serial driver with higher-level formatting.

const serial = @import("../drivers/serial.zig");

/// Initialize console (initializes underlying serial port)
pub fn init() void {
    serial.init();
}

/// Print a formatted string (basic format support)
/// Supports: {} for any, {d} for decimal, {x} for hex, {s} for string
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const ArgsType = @TypeOf(args);
    const args_info = @typeInfo(ArgsType);

    comptime var arg_index: usize = 0;
    comptime var i: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                // {} - auto format
                if (args_info == .@"struct" and arg_index < args_info.@"struct".fields.len) {
                    printArg(args[arg_index]);
                    arg_index += 1;
                }
                i += 2;
            } else if (i + 2 < fmt.len and fmt[i + 2] == '}') {
                // {x}, {d}, {s} - specific format
                const spec = fmt[i + 1];
                if (args_info == .@"struct" and arg_index < args_info.@"struct".fields.len) {
                    printArgWithSpec(args[arg_index], spec);
                    arg_index += 1;
                }
                i += 3;
            } else {
                serial.writeByte(fmt[i]);
                i += 1;
            }
        } else {
            serial.writeByte(fmt[i]);
            i += 1;
        }
    }
}

/// Print with newline
pub fn println(comptime fmt: []const u8, args: anytype) void {
    print(fmt, args);
    serial.writeString("\n");
}

/// Print a single argument with auto format detection
fn printArg(arg: anytype) void {
    const T = @TypeOf(arg);
    const info = @typeInfo(T);

    switch (info) {
        .int, .comptime_int => serial.writeInt(@intCast(arg)),
        .pointer => |ptr| {
            if (ptr.size == .Slice and ptr.child == u8) {
                serial.writeString(arg);
            } else if (ptr.size == .One) {
                serial.writeString("0x");
                serial.writeHex(@intFromPtr(arg));
            } else {
                serial.writeString("(pointer)");
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                serial.writeString(&arg);
            } else {
                serial.writeString("(array)");
            }
        },
        .bool => {
            if (arg) {
                serial.writeString("true");
            } else {
                serial.writeString("false");
            }
        },
        .@"enum" => serial.writeString(@tagName(arg)),
        else => serial.writeString("(unknown)"),
    }
}

/// Print argument with specific format specifier
fn printArgWithSpec(arg: anytype, spec: u8) void {
    const T = @TypeOf(arg);
    const info = @typeInfo(T);

    switch (spec) {
        'd' => {
            if (info == .int or info == .comptime_int) {
                serial.writeInt(@intCast(arg));
            } else {
                printArg(arg);
            }
        },
        'x' => {
            if (info == .int or info == .comptime_int) {
                serial.writeHex(@intCast(arg));
            } else {
                printArg(arg);
            }
        },
        's' => {
            if (info == .pointer) {
                const ptr = info.pointer;
                if (ptr.size == .Slice and ptr.child == u8) {
                    serial.writeString(arg);
                } else {
                    printArg(arg);
                }
            } else {
                printArg(arg);
            }
        },
        else => printArg(arg),
    }
}

/// Log levels
pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

/// Log with level prefix
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    const prefix = switch (level) {
        .debug => "[DEBUG] ",
        .info => "[INFO]  ",
        .warn => "[WARN]  ",
        .err => "[ERROR] ",
    };
    serial.writeString(prefix);
    println(fmt, args);
}
