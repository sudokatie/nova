// Embedded User Binaries
//
// Contains compiled user programs embedded at compile time.
// These are registered with the VFS at boot for spawn/exec.

const console = @import("lib/console.zig");
const syscall = @import("arch/x86_64/syscall.zig");
const embedded = @import("embedded");

// Embedded binaries from build system
pub const init_binary = embedded.init_binary;
pub const shell_binary = embedded.shell_binary;

/// Register all embedded binaries with the VFS
pub fn registerAll() void {
    console.log(.info, "Registering embedded binaries...", .{});

    syscall.registerBinary("init", init_binary);
    console.log(.debug, "  Registered /init ({} bytes)", .{init_binary.len});

    syscall.registerBinary("shell", shell_binary);
    console.log(.debug, "  Registered /shell ({} bytes)", .{shell_binary.len});

    console.log(.info, "Embedded binaries registered", .{});
}
