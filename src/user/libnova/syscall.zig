// Userspace Syscall Interface
//
// Inline assembly wrappers for system calls.
// Follows x86_64 syscall ABI: args in RDI, RSI, RDX, R10, R8, R9
// Syscall number in RAX, return value in RAX

// Syscall numbers (must match kernel)
pub const SYS_EXIT: u64 = 0;
pub const SYS_DEBUG_PRINT: u64 = 1;
pub const SYS_GETPID: u64 = 2;
pub const SYS_GETTID: u64 = 3;
pub const SYS_MMAP: u64 = 4;
pub const SYS_MUNMAP: u64 = 5;
pub const SYS_YIELD: u64 = 6;

/// Raw syscall with 0 arguments
pub inline fn syscall0(number: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
        : "rcx", "r11", "memory"
    );
}

/// Raw syscall with 1 argument
pub inline fn syscall1(number: u64, arg1: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
        : "rcx", "r11", "memory"
    );
}

/// Raw syscall with 2 arguments
pub inline fn syscall2(number: u64, arg1: u64, arg2: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
        : "rcx", "r11", "memory"
    );
}

/// Raw syscall with 3 arguments
pub inline fn syscall3(number: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
        : "rcx", "r11", "memory"
    );
}

/// Raw syscall with 4 arguments
pub inline fn syscall4(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
          [a4] "{r10}" (arg4),
        : "rcx", "r11", "memory"
    );
}

/// Raw syscall with 5 arguments
pub inline fn syscall5(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
          [a4] "{r10}" (arg4),
          [a5] "{r8}" (arg5),
        : "rcx", "r11", "memory"
    );
}

/// Raw syscall with 6 arguments
pub inline fn syscall6(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
          [a4] "{r10}" (arg4),
          [a5] "{r8}" (arg5),
          [a6] "{r9}" (arg6),
        : "rcx", "r11", "memory"
    );
}

// ============= High-level syscall wrappers =============

/// Exit the current process
pub fn exit(code: i32) noreturn {
    _ = syscall1(SYS_EXIT, @intCast(@as(u32, @bitCast(code))));
    unreachable;
}

/// Print a debug message
pub fn debug_print(msg: []const u8) isize {
    return @intCast(syscall2(SYS_DEBUG_PRINT, @intFromPtr(msg.ptr), msg.len));
}

/// Get current process ID
pub fn getpid() i32 {
    return @intCast(syscall0(SYS_GETPID));
}

/// Get current thread ID
pub fn gettid() i32 {
    return @intCast(syscall0(SYS_GETTID));
}

/// Allocate memory pages
pub fn mmap(addr: u64, length: u64, prot: u32, flags: u32) ?[*]u8 {
    const result = syscall4(SYS_MMAP, addr, length, prot, flags);
    if (result < 0) {
        return null;
    }
    return @ptrFromInt(@as(u64, @intCast(result)));
}

/// Free memory pages
pub fn munmap(addr: [*]u8, length: u64) i32 {
    return @intCast(syscall2(SYS_MUNMAP, @intFromPtr(addr), length));
}

/// Yield CPU to other threads
pub fn yield() void {
    _ = syscall0(SYS_YIELD);
}
