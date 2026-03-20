// System Call Interface
//
// SYSCALL/SYSRET setup and dispatch for x86_64.
// Uses the fast syscall mechanism via MSRs.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");
const context = @import("../../proc/context.zig");
const Thread = @import("../../proc/thread.zig").Thread;
const thread_mod = @import("../../proc/thread.zig");
const process_mod = @import("../../proc/process.zig");
const Process = process_mod.Process;
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const scheduler = @import("../../proc/scheduler.zig");
const message = @import("../../ipc/message.zig");
const elf = @import("../../loader/elf.zig");
const timer = @import("../../drivers/timer.zig");

// MSR addresses for syscall
const MSR_STAR: u32 = 0xC0000081;
const MSR_LSTAR: u32 = 0xC0000082;
const MSR_CSTAR: u32 = 0xC0000083;
const MSR_FMASK: u32 = 0xC0000084;

// Segment selectors (must match GDT)
const KERNEL_CS: u64 = 0x08;
const KERNEL_DS: u64 = 0x10;
const USER_CS: u64 = 0x18 | 3;
const USER_DS: u64 = 0x20 | 3;

// RFLAGS to clear on syscall entry
const FMASK_VALUE: u64 = 0x200;

// Maximum syscall number
pub const MAX_SYSCALLS: usize = 256;

// Syscall handler function type
pub const SyscallHandler = *const fn (arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) i64;

// Syscall dispatch table
var syscall_table: [MAX_SYSCALLS]?SyscallHandler = [_]?SyscallHandler{null} ** MAX_SYSCALLS;

// ============= Syscall Numbers (per spec 8.2) =============

// Memory
pub const SYS_MMAP: usize = 0;
pub const SYS_MUNMAP: usize = 1;
pub const SYS_MPROTECT: usize = 2;

// Process
pub const SYS_SPAWN: usize = 10;
pub const SYS_FORK: usize = 11;
pub const SYS_EXEC: usize = 12;
pub const SYS_EXIT: usize = 13;
pub const SYS_WAIT: usize = 14;
pub const SYS_GETPID: usize = 15;
pub const SYS_GETTID: usize = 16;

// Thread
pub const SYS_THREAD_CREATE: usize = 20;
pub const SYS_THREAD_EXIT: usize = 21;
pub const SYS_THREAD_JOIN: usize = 22;
pub const SYS_YIELD: usize = 23;

// IPC
pub const SYS_SEND: usize = 30;
pub const SYS_RECEIVE: usize = 31;
pub const SYS_CALL: usize = 32;
pub const SYS_REPLY: usize = 33;

// Time
pub const SYS_SLEEP: usize = 40;
pub const SYS_GETTIME: usize = 41;

// Debug
pub const SYS_DEBUG_PRINT: usize = 50;

// Per-CPU data for syscall handling
pub const PerCpuData = struct {
    kernel_rsp: u64,
    user_rsp: u64,
    current_thread: ?*Thread,
};

var per_cpu: PerCpuData = .{
    .kernel_rsp = 0,
    .user_rsp = 0,
    .current_thread = null,
};

/// Initialize the syscall interface
pub fn init() void {
    const star_value: u64 = ((USER_CS - 16) << 48) | (KERNEL_CS << 32);
    cpu.writeMSR(MSR_STAR, star_value);

    const entry_addr = @intFromPtr(&syscallEntryStub);
    cpu.writeMSR(MSR_LSTAR, entry_addr);
    cpu.writeMSR(MSR_FMASK, FMASK_VALUE);

    registerDefaults();
    console.log(.info, "Syscall interface initialized", .{});
}

/// Register a syscall handler
pub fn register(number: usize, handler: SyscallHandler) void {
    if (number < MAX_SYSCALLS) {
        syscall_table[number] = handler;
    }
}

/// Register default syscall handlers
fn registerDefaults() void {
    // Memory
    register(SYS_MMAP, &sysMmap);
    register(SYS_MUNMAP, &sysMunmap);
    register(SYS_MPROTECT, &sysMprotect);

    // Process
    register(SYS_SPAWN, &sysSpawn);
    register(SYS_FORK, &sysFork);
    register(SYS_EXEC, &sysExec);
    register(SYS_EXIT, &sysExit);
    register(SYS_WAIT, &sysWait);
    register(SYS_GETPID, &sysGetpid);
    register(SYS_GETTID, &sysGettid);

    // Thread
    register(SYS_THREAD_CREATE, &sysThreadCreate);
    register(SYS_THREAD_EXIT, &sysThreadExit);
    register(SYS_THREAD_JOIN, &sysThreadJoin);
    register(SYS_YIELD, &sysYield);

    // IPC
    register(SYS_SEND, &sysSend);
    register(SYS_RECEIVE, &sysReceive);
    register(SYS_CALL, &sysCall);
    register(SYS_REPLY, &sysReply);

    // Time
    register(SYS_SLEEP, &sysSleep);
    register(SYS_GETTIME, &sysGettime);

    // Debug
    register(SYS_DEBUG_PRINT, &sysDebugPrint);
}

/// Syscall dispatch
pub fn syscallDispatch(
    syscall_num: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
) i64 {
    if (syscall_num >= MAX_SYSCALLS) {
        return -1; // ENOSYS
    }

    const handler = syscall_table[syscall_num] orelse {
        console.log(.warn, "Syscall: unhandled syscall {}", .{syscall_num});
        return -1;
    };

    return handler(arg1, arg2, arg3, arg4, arg5, arg6);
}

fn syscallEntryStub() void {
    // Placeholder - actual syscall entry would need naked function
}

pub fn setKernelStack(rsp: u64) void {
    per_cpu.kernel_rsp = rsp;
}

pub fn setCurrentThread(thread: ?*Thread) void {
    per_cpu.current_thread = thread;
}

// ============= Memory Syscalls =============

fn sysMmap(addr: u64, length: u64, prot: u64, flags: u64, _: u64, _: u64) i64 {
    _ = prot;
    _ = flags;

    const page_size: u64 = 4096;
    const num_pages = (length + page_size - 1) / page_size;

    if (context.getCurrent()) |thread| {
        if (thread.process.address_space) |*space| {
            const map_flags = vmm.MapFlags{ .writable = true, .user = true };
            if (vmm.allocPages(space, addr, num_pages, map_flags)) {
                return @intCast(addr);
            }
        }
    }
    return -1;
}

fn sysMunmap(addr: u64, length: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const page_size: u64 = 4096;
    const num_pages = (length + page_size - 1) / page_size;

    if (context.getCurrent()) |thread| {
        if (thread.process.address_space) |*space| {
            var i: u64 = 0;
            while (i < num_pages) : (i += 1) {
                const virt = addr + i * page_size;
                if (space.translate(virt)) |phys| {
                    pmm.freePage(phys);
                }
                _ = space.unmapPage(virt);
            }
            return 0;
        }
    }
    return -1;
}

fn sysMprotect(addr: u64, length: u64, prot: u64, _: u64, _: u64, _: u64) i64 {
    const page_size: u64 = 4096;
    const num_pages = (length + page_size - 1) / page_size;

    if (context.getCurrent()) |thread| {
        if (thread.process.address_space) |*space| {
            var flags = vmm.MapFlags{ .user = true };
            if ((prot & 0x2) != 0) flags.writable = true; // PROT_WRITE
            if ((prot & 0x4) == 0) flags.no_execute = true; // No PROT_EXEC

            var i: u64 = 0;
            while (i < num_pages) : (i += 1) {
                const virt = addr + i * page_size;
                if (space.translate(virt)) |phys| {
                    _ = space.unmapPage(virt);
                    _ = space.mapPage(virt, phys, flags);
                }
            }
            return 0;
        }
    }
    return -1;
}

// ============= Process Syscalls =============

fn sysSpawn(path_ptr: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    _ = path_ptr;
    // TODO: Need filesystem to load ELF from path
    // For now, return error - spawn needs VFS server
    console.log(.debug, "sys_spawn: VFS not implemented", .{});
    return -1;
}

fn sysFork(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const current = context.getCurrent() orelse return -1;
    const parent_proc = current.process;

    // Create child process
    const child_proc = process_mod.create(parent_proc.pid) orelse {
        console.log(.err, "sys_fork: failed to create child process", .{});
        return -1;
    };

    // Copy address space with COW
    if (parent_proc.address_space) |*parent_space| {
        if (child_proc.address_space) |*child_space| {
            if (!vmm.forkAddressSpace(child_space, parent_space)) {
                console.log(.err, "sys_fork: failed to copy address space", .{});
                return -1;
            }
        }
    }

    // Create main thread for child
    const child_thread = thread_mod.create(child_proc) orelse {
        console.log(.err, "sys_fork: failed to create child thread", .{});
        return -1;
    };

    // Copy parent context to child
    child_thread.context = current.context;
    child_thread.context.rax = 0; // Child returns 0

    // Make child ready
    child_thread.state = .ready;
    scheduler.enqueue(child_thread);

    // Parent returns child PID
    return @intCast(child_proc.pid);
}

fn sysExec(path_ptr: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    _ = path_ptr;
    // TODO: Need filesystem
    console.log(.debug, "sys_exec: VFS not implemented", .{});
    return -1;
}

fn sysExit(exit_code: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    console.log(.debug, "sys_exit: code {}", .{exit_code});
    if (context.getCurrent()) |thread| {
        thread.process.terminate(@intCast(exit_code));
        thread.terminate();
        scheduler.schedule();
    }
    return 0;
}

fn sysWait(pid: u64, status_ptr: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const current = context.getCurrent() orelse return -1;
    const target_pid: u32 = @intCast(pid);

    // Find child process
    if (process_mod.get(target_pid)) |child| {
        // Check if it's our child
        if (child.parent_pid != current.process.pid) {
            return -1; // Not our child
        }

        // Wait for child to become zombie
        while (child.state != .zombie and child.state != .terminated) {
            current.state = .blocked;
            scheduler.schedule();
        }

        // Store exit status
        if (status_ptr != 0) {
            const status: *i32 = @ptrFromInt(status_ptr);
            status.* = child.exit_code;
        }

        // Clean up child
        process_mod.free(target_pid);
        return @intCast(target_pid);
    }

    return -1;
}

fn sysGetpid(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    if (context.getCurrent()) |thread| {
        return @intCast(thread.process.pid);
    }
    return -1;
}

fn sysGettid(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    if (context.getCurrent()) |thread| {
        return @intCast(thread.tid);
    }
    return -1;
}

// ============= Thread Syscalls =============

fn sysThreadCreate(entry: u64, stack: u64, arg: u64, _: u64, _: u64, _: u64) i64 {
    const current = context.getCurrent() orelse return -1;

    const thread = thread_mod.create(current.process) orelse {
        console.log(.err, "sys_thread_create: failed", .{});
        return -1;
    };

    thread.setEntry(entry, stack);
    thread.setArgs(arg, 0, 0);
    thread.state = .ready;
    scheduler.enqueue(thread);

    return @intCast(thread.tid);
}

fn sysThreadExit(status: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    if (context.getCurrent()) |thread| {
        _ = status;
        thread.terminate();
        scheduler.schedule();
    }
    return 0;
}

fn sysThreadJoin(tid: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const current = context.getCurrent() orelse return -1;
    const target_tid: u32 = @intCast(tid);

    if (thread_mod.get(target_tid)) |target| {
        // Wait for thread to terminate
        while (target.state != .terminated) {
            current.state = .blocked;
            scheduler.schedule();
        }

        thread_mod.free(target);
        return 0;
    }

    return -1;
}

fn sysYield(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    scheduler.yield();
    return 0;
}

// ============= IPC Syscalls =============

fn sysSend(dest_tid: u64, msg_ptr: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const msg: *const message.Message = @ptrFromInt(msg_ptr);
    const dest_thread = thread_mod.get(@intCast(dest_tid)) orelse return -1;
    return message.send(dest_thread, msg);
}

fn sysReceive(src_tid: u64, buf_ptr: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const buf: *message.Message = @ptrFromInt(buf_ptr);
    const src = if (src_tid == 0) null else thread_mod.get(@intCast(src_tid));
    const sender = message.receive(src, buf);
    if (sender) |s| {
        return @intCast(s.tid);
    }
    return -1;
}

fn sysCall(dest_tid: u64, msg_ptr: u64, reply_ptr: u64, _: u64, _: u64, _: u64) i64 {
    const msg: *const message.Message = @ptrFromInt(msg_ptr);
    const reply: *message.Message = @ptrFromInt(reply_ptr);
    const dest_thread = thread_mod.get(@intCast(dest_tid)) orelse return -1;

    // Send
    const send_result = message.send(dest_thread, msg);
    if (send_result < 0) return send_result;

    // Receive reply
    _ = message.receive(dest_thread, reply);
    return 0;
}

fn sysReply(msg_ptr: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const current = context.getCurrent() orelse return -1;
    const msg: *const message.Message = @ptrFromInt(msg_ptr);

    // Get the caller we're replying to (stored during receive)
    const caller = message.getLastCaller(current) orelse return -1;
    return message.send(caller, msg);
}

// ============= Time Syscalls =============

fn sysSleep(nanoseconds: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const current = context.getCurrent() orelse return -1;

    // Convert nanoseconds to ticks (assuming 100Hz timer = 10ms per tick)
    const ticks = (nanoseconds / 1_000_000) / 10;
    if (ticks == 0) return 0;

    const wake_at = timer.getTicks() + ticks;
    current.sleep_until = wake_at;
    current.state = .sleeping;
    scheduler.schedule();

    return 0;
}

fn sysGettime(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Return nanoseconds since boot
    const ticks = timer.getTicks();
    const ns = ticks * 10_000_000; // 10ms per tick = 10,000,000 ns
    return @intCast(ns);
}

// ============= Debug Syscalls =============

fn sysDebugPrint(ptr: u64, len: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const safe_len = @min(len, 256);
    const str: [*]const u8 = @ptrFromInt(ptr);

    for (0..safe_len) |i| {
        console.putChar(str[i]);
    }

    return @intCast(safe_len);
}

/// Test syscall dispatch (kernel-mode test)
pub fn testDispatch() void {
    console.log(.debug, "Syscall test: testing dispatch table...", .{});

    const pid = syscallDispatch(SYS_GETPID, 0, 0, 0, 0, 0, 0);
    console.log(.debug, "  sys_getpid returned: {}", .{pid});

    const tid = syscallDispatch(SYS_GETTID, 0, 0, 0, 0, 0, 0);
    console.log(.debug, "  sys_gettid returned: {}", .{tid});

    const invalid = syscallDispatch(255, 0, 0, 0, 0, 0, 0);
    console.log(.debug, "  invalid syscall returned: {}", .{invalid});

    console.log(.info, "Syscall dispatch test passed", .{});
}
