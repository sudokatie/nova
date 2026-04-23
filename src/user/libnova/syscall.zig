// Userspace Syscall Interface
//
// Inline assembly wrappers for system calls.
// Follows x86_64 syscall ABI: args in RDI, RSI, RDX, R10, R8, R9
// Syscall number in RAX, return value in RAX

// Syscall numbers (must match kernel - spec 8.2)
// Memory
pub const SYS_MMAP: u64 = 0;
pub const SYS_MUNMAP: u64 = 1;
pub const SYS_MPROTECT: u64 = 2;

// Process
pub const SYS_SPAWN: u64 = 10;
pub const SYS_FORK: u64 = 11;
pub const SYS_EXEC: u64 = 12;
pub const SYS_EXIT: u64 = 13;
pub const SYS_WAIT: u64 = 14;
pub const SYS_GETPID: u64 = 15;
pub const SYS_GETTID: u64 = 16;

// Thread
pub const SYS_THREAD_CREATE: u64 = 20;
pub const SYS_THREAD_EXIT: u64 = 21;
pub const SYS_THREAD_JOIN: u64 = 22;
pub const SYS_YIELD: u64 = 23;

// IPC
pub const SYS_SEND: u64 = 30;
pub const SYS_RECEIVE: u64 = 31;
pub const SYS_CALL: u64 = 32;
pub const SYS_REPLY: u64 = 33;

// Time
pub const SYS_SLEEP: u64 = 40;
pub const SYS_GETTIME: u64 = 41;

// Debug/Console
pub const SYS_DEBUG_PRINT: u64 = 50;
pub const SYS_READ_CHAR: u64 = 51;

// Device Capabilities
pub const SYS_REQUEST_IOPORT: u64 = 60;
pub const SYS_RELEASE_IOPORT: u64 = 61;
pub const SYS_REQUEST_IRQ: u64 = 62;
pub const SYS_RELEASE_IRQ: u64 = 63;
pub const SYS_INB: u64 = 64;
pub const SYS_OUTB: u64 = 65;
pub const SYS_INW: u64 = 66;
pub const SYS_OUTW: u64 = 67;

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

// ============= Memory Syscalls =============

/// Allocate memory pages
pub fn mmap(addr: u64, length: u64, prot: u32, flags: u32) ?[*]u8 {
    const result = syscall4(SYS_MMAP, addr, length, prot, flags);
    if (result < 0) return null;
    return @ptrFromInt(@as(u64, @intCast(result)));
}

/// Free memory pages
pub fn munmap(addr: [*]u8, length: u64) i32 {
    return @intCast(syscall2(SYS_MUNMAP, @intFromPtr(addr), length));
}

/// Change memory protection
pub fn mprotect(addr: [*]u8, length: u64, prot: u32) i32 {
    return @intCast(syscall3(SYS_MPROTECT, @intFromPtr(addr), length, prot));
}

// ============= Process Syscalls =============

/// Spawn a new process from path
pub fn spawn(path: []const u8, argv: ?[*]const ?[*]const u8, envp: ?[*]const ?[*]const u8) i32 {
    return @intCast(syscall3(
        SYS_SPAWN,
        @intFromPtr(path.ptr),
        if (argv) |a| @intFromPtr(a) else 0,
        if (envp) |e| @intFromPtr(e) else 0,
    ));
}

/// Fork the current process
pub fn fork() i32 {
    return @intCast(syscall0(SYS_FORK));
}

/// Replace process image with new binary
pub fn exec(path: []const u8, argv: ?[*]const ?[*]const u8, envp: ?[*]const ?[*]const u8) i32 {
    return @intCast(syscall3(
        SYS_EXEC,
        @intFromPtr(path.ptr),
        if (argv) |a| @intFromPtr(a) else 0,
        if (envp) |e| @intFromPtr(e) else 0,
    ));
}

/// Exit the current process
pub fn exit(code: i32) noreturn {
    _ = syscall1(SYS_EXIT, @intCast(@as(u32, @bitCast(code))));
    unreachable;
}

/// Wait for a child process
pub fn wait(pid: i32, status: ?*i32) i32 {
    return @intCast(syscall2(
        SYS_WAIT,
        @intCast(@as(u32, @bitCast(pid))),
        if (status) |s| @intFromPtr(s) else 0,
    ));
}

/// Get current process ID
pub fn getpid() i32 {
    return @intCast(syscall0(SYS_GETPID));
}

/// Get current thread ID
pub fn gettid() i32 {
    return @intCast(syscall0(SYS_GETTID));
}

// ============= Thread Syscalls =============

/// Create a new thread
pub fn thread_create(entry: *const fn (?*anyopaque) callconv(.C) void, stack: [*]u8, arg: ?*anyopaque) i32 {
    return @intCast(syscall3(
        SYS_THREAD_CREATE,
        @intFromPtr(entry),
        @intFromPtr(stack),
        if (arg) |a| @intFromPtr(a) else 0,
    ));
}

/// Exit current thread
pub fn thread_exit(status: i32) noreturn {
    _ = syscall1(SYS_THREAD_EXIT, @intCast(@as(u32, @bitCast(status))));
    unreachable;
}

/// Wait for thread to exit
pub fn thread_join(tid: i32) i32 {
    return @intCast(syscall1(SYS_THREAD_JOIN, @intCast(@as(u32, @bitCast(tid)))));
}

/// Yield CPU to other threads
pub fn yield() void {
    _ = syscall0(SYS_YIELD);
}

// ============= IPC Syscalls =============

/// Message structure (must match kernel)
pub const Message = extern struct {
    tag: u32,
    len: u32,
    data: [56]u8,
};

/// Send a message to thread
pub fn send(dest_tid: i32, msg: *const Message) i32 {
    return @intCast(syscall2(
        SYS_SEND,
        @intCast(@as(u32, @bitCast(dest_tid))),
        @intFromPtr(msg),
    ));
}

/// Receive a message (0 = from any)
pub fn receive(src_tid: i32, buf: *Message) i32 {
    return @intCast(syscall2(
        SYS_RECEIVE,
        @intCast(@as(u32, @bitCast(src_tid))),
        @intFromPtr(buf),
    ));
}

/// Send and receive atomically
pub fn call(dest_tid: i32, msg: *const Message, reply: *Message) i32 {
    return @intCast(syscall3(
        SYS_CALL,
        @intCast(@as(u32, @bitCast(dest_tid))),
        @intFromPtr(msg),
        @intFromPtr(reply),
    ));
}

/// Reply to caller
pub fn reply(msg: *const Message) i32 {
    return @intCast(syscall1(SYS_REPLY, @intFromPtr(msg)));
}

// ============= Time Syscalls =============

/// Sleep for nanoseconds
pub fn sleep(nanoseconds: u64) i32 {
    return @intCast(syscall1(SYS_SLEEP, nanoseconds));
}

/// Get current time in nanoseconds
pub fn gettime() u64 {
    const result = syscall0(SYS_GETTIME);
    return @intCast(result);
}

// ============= Debug Syscalls =============

/// Print a debug message
pub fn debug_print(msg: []const u8) isize {
    return @intCast(syscall2(SYS_DEBUG_PRINT, @intFromPtr(msg.ptr), msg.len));
}

/// Read a character from keyboard (non-blocking)
/// Returns the character value (0-255), or -1 if no input available
pub fn read_char() i32 {
    return @intCast(syscall0(SYS_READ_CHAR));
}

// ============= Device Capability Syscalls =============

/// Request access to I/O port range
/// Returns 0 on success, -1 on error
pub fn request_ioport(base: u16, count: u16) i32 {
    return @intCast(syscall2(SYS_REQUEST_IOPORT, base, count));
}

/// Release I/O port access
pub fn release_ioport(base: u16) i32 {
    return @intCast(syscall1(SYS_RELEASE_IOPORT, base));
}

/// Request an IRQ
/// notify_port: port ID to receive IRQ notifications on
pub fn request_irq(irq: u8, notify_port: u32) i32 {
    return @intCast(syscall2(SYS_REQUEST_IRQ, irq, notify_port));
}

/// Release an IRQ
pub fn release_irq(irq: u8) i32 {
    return @intCast(syscall1(SYS_RELEASE_IRQ, irq));
}

/// Read a byte from an I/O port
/// Returns the byte value, or -1 if permission denied
pub fn inb(port: u16) i32 {
    return @intCast(syscall1(SYS_INB, port));
}

/// Write a byte to an I/O port
/// Returns 0 on success, -1 if permission denied
pub fn outb(port: u16, value: u8) i32 {
    return @intCast(syscall2(SYS_OUTB, port, value));
}

/// Read a word from an I/O port
pub fn inw(port: u16) i32 {
    return @intCast(syscall1(SYS_INW, port));
}

/// Write a word to an I/O port
pub fn outw(port: u16, value: u16) i32 {
    return @intCast(syscall2(SYS_OUTW, port, value));
}
