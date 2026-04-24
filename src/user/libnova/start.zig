// Userspace Entry Point
//
// Minimal C runtime for Nova user programs.
// Provides _start which calls main and exits.

pub const syscall = @import("syscall.zig");

/// User program's main function (provided by the application)
extern fn main() i32;

/// Entry point - called by kernel when process starts
pub export fn _start() noreturn {
    // Call user's main function
    const exit_code = main();

    // Exit with the return value
    syscall.exit(exit_code);
}

/// Print a message to console (wrapper for debug_print)
pub fn print(msg: []const u8) void {
    _ = syscall.debug_print(msg);
}

/// Print a message with newline
pub fn println(msg: []const u8) void {
    _ = syscall.debug_print(msg);
    _ = syscall.debug_print("\n");
}

/// Allocate memory (simple wrapper)
pub fn alloc(size: usize) ?[*]u8 {
    // Round up to page size
    const page_size: usize = 4096;
    const aligned_size = (size + page_size - 1) & ~(page_size - 1);
    return syscall.mmap(0, aligned_size, 0, 0);
}

/// Free memory
pub fn free(ptr: [*]u8, size: usize) void {
    const page_size: usize = 4096;
    const aligned_size = (size + page_size - 1) & ~(page_size - 1);
    _ = syscall.munmap(ptr, aligned_size);
}
