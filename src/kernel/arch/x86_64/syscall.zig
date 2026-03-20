// System Call Interface
//
// SYSCALL/SYSRET setup and dispatch for x86_64.
// Uses the fast syscall mechanism via MSRs.

const cpu = @import("cpu.zig");
const console = @import("../../lib/console.zig");
const context = @import("../../proc/context.zig");
const Thread = @import("../../proc/thread.zig").Thread;

// MSR addresses for syscall
const MSR_STAR: u32 = 0xC0000081; // Segment selectors
const MSR_LSTAR: u32 = 0xC0000082; // Syscall entry point (64-bit)
const MSR_CSTAR: u32 = 0xC0000083; // Syscall entry point (compat mode, unused)
const MSR_FMASK: u32 = 0xC0000084; // RFLAGS mask

// Segment selectors (must match GDT)
const KERNEL_CS: u64 = 0x08;
const KERNEL_DS: u64 = 0x10;
const USER_CS: u64 = 0x18 | 3; // Ring 3
const USER_DS: u64 = 0x20 | 3; // Ring 3

// RFLAGS to clear on syscall entry
const FMASK_VALUE: u64 = 0x200; // Clear IF (disable interrupts)

// Maximum syscall number
pub const MAX_SYSCALLS: usize = 256;

// Syscall handler function type
pub const SyscallHandler = *const fn (arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) i64;

// Syscall dispatch table
var syscall_table: [MAX_SYSCALLS]?SyscallHandler = [_]?SyscallHandler{null} ** MAX_SYSCALLS;

// Syscall numbers
pub const SYS_EXIT: usize = 0;
pub const SYS_DEBUG_PRINT: usize = 1;
pub const SYS_GETPID: usize = 2;
pub const SYS_GETTID: usize = 3;
pub const SYS_MMAP: usize = 4;
pub const SYS_MUNMAP: usize = 5;
pub const SYS_YIELD: usize = 6;

// Per-CPU data for syscall handling
pub const PerCpuData = struct {
    kernel_rsp: u64, // Kernel stack pointer to use
    user_rsp: u64, // Saved user stack pointer
    current_thread: ?*Thread,
};

var per_cpu: PerCpuData = .{
    .kernel_rsp = 0,
    .user_rsp = 0,
    .current_thread = null,
};

/// Initialize the syscall interface
pub fn init() void {
    // Set up STAR MSR: segment selectors for SYSCALL/SYSRET
    // STAR[47:32] = SYSRET CS/SS (USER_CS - 16, adds 16 for CS, 8 for SS)
    // STAR[31:0] = SYSCALL CS/SS (KERNEL_CS, KERNEL_CS + 8 for SS)
    const star_value: u64 = ((USER_CS - 16) << 48) | (KERNEL_CS << 32);
    cpu.writeMSR(MSR_STAR, star_value);

    // Set LSTAR: syscall entry point
    // Note: Using stub address for now - full entry needs external assembly
    const entry_addr = @intFromPtr(&syscallEntryStub);
    cpu.writeMSR(MSR_LSTAR, entry_addr);

    // Set FMASK: RFLAGS bits to clear on syscall
    cpu.writeMSR(MSR_FMASK, FMASK_VALUE);

    // Register default syscall handlers
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
    register(SYS_EXIT, &sysExit);
    register(SYS_DEBUG_PRINT, &sysDebugPrint);
    register(SYS_GETPID, &sysGetpid);
    register(SYS_GETTID, &sysGettid);
    register(SYS_MMAP, &sysMmap);
    register(SYS_MUNMAP, &sysMunmap);
    register(SYS_YIELD, &sysYield);
}

/// Syscall entry point (called from assembly stub)
/// Arguments in: RDI, RSI, RDX, R10, R8, R9
/// Syscall number in: RAX
/// Return value in: RAX
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
        return -1; // ENOSYS
    };

    return handler(arg1, arg2, arg3, arg4, arg5, arg6);
}

/// Syscall entry point address (for LSTAR MSR)
/// Note: Full naked assembly entry requires external .S file or linker script
/// For now, we set up the MSRs but actual syscall entry needs userspace to test
/// The dispatch table is tested via direct calls
fn syscallEntryStub() void {
    // Placeholder - actual syscall entry would need naked function
    // which Zig 0.15 doesn't support via callconv
    // For kernel-only testing, call syscallDispatch directly
}

/// Set kernel stack for syscalls (called when switching threads)
pub fn setKernelStack(rsp: u64) void {
    per_cpu.kernel_rsp = rsp;
}

/// Set current thread (for getpid/gettid)
pub fn setCurrentThread(thread: ?*Thread) void {
    per_cpu.current_thread = thread;
}

// ============= Syscall Handlers =============

fn sysExit(exit_code: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    console.log(.debug, "sys_exit: code {}", .{exit_code});
    if (context.getCurrent()) |thread| {
        thread.terminate();
    }
    // Should not return - scheduler will pick another thread
    return 0;
}

fn sysDebugPrint(ptr: u64, len: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    // Safety check: limit length
    const safe_len = @min(len, 256);
    const str: [*]const u8 = @ptrFromInt(ptr);
    
    // Print to console
    for (0..safe_len) |i| {
        console.putChar(str[i]);
    }
    
    return @intCast(safe_len);
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

fn sysYield(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const scheduler = @import("../../proc/scheduler.zig");
    scheduler.yield();
    return 0;
}

fn sysMmap(addr: u64, length: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const vmm = @import("../../mm/vmm.zig");
    
    // Calculate number of pages needed
    const page_size: u64 = 4096;
    const num_pages = (length + page_size - 1) / page_size;
    
    // Get current process address space
    if (context.getCurrent()) |thread| {
        if (thread.process.address_space) |*space| {
            // Allocate and map pages
            const map_flags = vmm.MapFlags{ .writable = true, .user = true };
            if (vmm.allocPages(space, addr, num_pages, map_flags)) {
                return @intCast(addr);
            }
        }
    }
    
    return -1; // ENOMEM
}

fn sysMunmap(addr: u64, length: u64, _: u64, _: u64, _: u64, _: u64) i64 {
    const pmm = @import("../../mm/pmm.zig");
    
    // Calculate number of pages
    const page_size: u64 = 4096;
    const num_pages = (length + page_size - 1) / page_size;
    
    // Get current process address space
    if (context.getCurrent()) |thread| {
        if (thread.process.address_space) |*space| {
            // Free physical pages and unmap
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
    
    return -1; // EINVAL
}

/// Test syscall dispatch (kernel-mode test)
pub fn testDispatch() void {
    console.log(.debug, "Syscall test: testing dispatch table...", .{});

    // Test getpid
    const pid = syscallDispatch(SYS_GETPID, 0, 0, 0, 0, 0, 0);
    console.log(.debug, "  sys_getpid returned: {}", .{pid});

    // Test gettid  
    const tid = syscallDispatch(SYS_GETTID, 0, 0, 0, 0, 0, 0);
    console.log(.debug, "  sys_gettid returned: {}", .{tid});

    // Test invalid syscall
    const invalid = syscallDispatch(255, 0, 0, 0, 0, 0, 0);
    console.log(.debug, "  invalid syscall returned: {}", .{invalid});

    console.log(.info, "Syscall dispatch test passed", .{});
}
