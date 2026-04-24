// Generated Embedded Binaries
//
// This module provides access to embedded user program ELF binaries.
// The actual binaries are embedded via the build system.

// Embedded ELF binaries (imported anonymously from build output)
pub const init_binary: []const u8 = @embedFile("init_elf");
pub const shell_binary: []const u8 = @embedFile("shell_elf");
