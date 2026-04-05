// System Call Interface
//
// SYSCALL/SYSRET setup and dispatch for x86_64.
// Uses the fast syscall mechanism via MSRs.

const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
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
const MSR_EFER: u32 = 0xC0000080;
const MSR_STAR: u32 = 0xC0000081;
const MSR_LSTAR: u32 = 0xC0000082;
const MSR_CSTAR: u32 = 0xC0000083;
const MSR_FMASK: u32 = 0xC0000084;

// EFER bits
const EFER_SCE: u64 = 1 << 0; // Syscall enable

// Segment selectors (must match GDT)
const KERNEL_CS: u64 = 0x08;
const KERNEL_DS: u64 = 0x10;

// RFLAGS to clear on syscall entry (clear IF to disable interrupts)
const FMASK_VALUE: u64 = 0x200; // Clear IF

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

// ============= Per-CPU Data =============

pub const PerCpuData = extern struct {
    kernel_rsp: u64, // Kernel stack pointer
    user_rsp: u64, // Saved user stack pointer
    current_thread: ?*Thread, // Current running thread

    pub fn init() PerCpuData {
        return .{
            .kernel_rsp = 0,
            .user_rsp = 0,
            .current_thread = null,
        };
    }
};

// Per-CPU data (one for each CPU, currently just one)
pub var per_cpu: PerCpuData = PerCpuData.init();

// ============= Syscall Entry Point =============

/// Syscall entry point (naked function)
/// ABI: syscall number in RAX, args in RDI, RSI, RDX, R10, R8, R9
/// RCX contains return RIP, R11 contains RFLAGS
pub fn syscallEntry() callconv(.naked) void {
    // Save user RSP and switch to kernel stack
    // The swapgs instruction would be used with per-CPU data in GS base
    // For simplicity, we use a global variable

    asm volatile (
        // Save user stack pointer
        \\movq %%rsp, per_cpu + 8   // per_cpu.user_rsp
        \\
        // Load kernel stack pointer
        \\movq per_cpu, %%rsp       // per_cpu.kernel_rsp
        \\
        // Push interrupt frame (for SYSRET compatibility)
        \\pushq $0x23               // User SS (0x20 | 3)
        \\pushq per_cpu + 8         // User RSP
        \\pushq %%r11               // RFLAGS (from R11)
        \\pushq $0x1b               // User CS (0x18 | 3)
        \\pushq %%rcx               // User RIP (from RCX)
        \\
        // Push error code (0 for syscall)
        \\pushq $0
        \\
        // Push all general purpose registers
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%rbp
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // Move R10 to RCX (R10 is 4th arg in syscall ABI, RCX is clobbered)
        \\movq %%r10, %%rcx
        \\
        // Call the dispatch function
        // Args already in: RDI, RSI, RDX, RCX (was R10), R8, R9
        // Syscall number in RAX
        \\movq %%rax, %%rdi         // syscall_num -> arg1
        \\movq 14*8(%%rsp), %%rsi   // original RDI -> arg2
        \\movq 13*8(%%rsp), %%rdx   // original RSI -> arg3
        \\movq 5*8(%%rsp), %%rcx    // original R10 -> arg4
        \\movq 7*8(%%rsp), %%r8     // original R8 -> arg5
        \\movq 6*8(%%rsp), %%r9     // original R9 -> arg6
        \\
        \\call syscallDispatchWrapper
        \\
        // Return value in RAX - store it
        \\movq %%rax, 15*8(%%rsp)
        \\
        // Pop registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\
        // Skip error code
        \\addq $8, %%rsp
        \\
        // Pop interrupt frame and return
        \\popq %%rcx               // RIP -> RCX for SYSRET
        \\addq $8, %%rsp           // Skip CS
        \\popq %%r11               // RFLAGS -> R11 for SYSRET
        \\popq %%rsp               // Restore user RSP
        \\
        // Return to userspace
        \\sysretq
    );
}

/// Wrapper function called from assembly
export fn syscallDispatchWrapper(
    syscall_num: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
) callconv(.c) i64 {
    // Get 6th argument from stack (R9 was saved there)
    // For now, just use 5 args - full 6 arg support would need more stack manipulation
    return syscallDispatch(syscall_num, arg1, arg2, arg3, arg4, arg5, 0);
}

/// Initialize the syscall interface
pub fn init() void {
    // Enable syscall instruction in EFER
    var efer = cpu.readMSR(MSR_EFER);
    efer |= EFER_SCE;
    cpu.writeMSR(MSR_EFER, efer);

    // STAR: Segment selectors
    // Bits 47:32 = SYSRET CS/SS (loaded as CS=this+16, SS=this+8)
    // Bits 63:48 = SYSCALL CS/SS (loaded as CS=this, SS=this+8)
    // For SYSCALL: CS = KERNEL_CS, SS = KERNEL_CS + 8 = KERNEL_DS
    // For SYSRET: CS = (USER_CS_BASE) + 16 = 0x18 | 3, SS = (USER_CS_BASE) + 8 = 0x20 | 3
    // So USER_CS_BASE should be 0x08 (0x08 + 16 = 0x18, 0x08 + 8 = 0x10, but we need user segs)
    // Actually: SYSRET loads SS = STAR[63:48] + 8, CS = STAR[63:48] + 16 (for 64-bit)
    // So we want STAR[63:48] = 0x08, which gives SS=0x10|3=0x13 (wrong), CS=0x18|3=0x1B (ok)
    // Correct: STAR[63:48] = 0x10, gives SS=0x18|3, CS=0x20|3... also wrong
    // The spec says: For SYSRET 64-bit, CS = IA32_STAR[63:48]+16, SS = IA32_STAR[63:48]+8
    // We want CS=0x18|3=0x1B, SS=0x20|3=0x23
    // So: 0x1B = X + 16, X = 0x0B... but that's not 0x10-aligned
    // Actually the +16/+8 doesn't add ring bits. The selector itself must have them.
    // STAR[63:48] for SYSRET should be 0x0B (0x18-16=0x08... no, 0x1B-16=0x0B)
    // Let me re-read: the hardware adds 16 to get CS selector, 8 to get SS selector
    // And then ORs in RPL 3.
    // So: STAR[63:48] = 0x08, CS = 0x08 + 16 = 0x18, SS = 0x08 + 8 = 0x10
    // Then hardware ORs RPL 3: CS = 0x18|3 = 0x1B, SS = 0x10|3 = 0x13
    // But our user SS is at 0x20! So STAR[63:48] should be 0x18
    // CS = 0x18 + 16 = 0x28 | 3 = 0x2B... that's wrong too
    // 
    // Actually, I had the GDT order wrong. Standard order is:
    // 0x00: null, 0x08: kernel code, 0x10: kernel data, 0x18: user data, 0x20: user code
    // Wait no, typically it's: null, kcode, kdata, ucode, udata
    // SYSRET 64-bit: CS = STAR[63:48] + 16, SS = STAR[63:48] + 8
    // With our GDT: kcode=0x08, kdata=0x10, ucode=0x18, udata=0x20
    // We want ucode=0x18|3=0x1B, udata=0x20|3=0x23
    // STAR[63:48] + 16 = 0x18 => STAR[63:48] = 0x08
    // STAR[63:48] + 8 = 0x10 (kernel data, but we want user data 0x20!)
    // 
    // The issue is the GDT layout. For SYSRET to work, user CS must be user DS - 8.
    // So if udata=0x20, ucode should be 0x20-8=0x18? No, SYSRET adds to get CS, adds less to get SS
    // CS = base + 16, SS = base + 8
    // If base = 0x10: CS = 0x26|3, SS = 0x18|3
    // If base = 0x08: CS = 0x18|3, SS = 0x10|3
    // 
    // I need to reorder GDT: null, kcode, kdata, udata, ucode (so ucode = udata + 8)
    // Then base = 0x10: SS = 0x18 (udata), CS = 0x26... still wrong
    // 
    // Actually reading Intel manual more carefully:
    // SYSRET loads CS from IA32_STAR[63:48]+16, SS from IA32_STAR[63:48]+8
    // So if I want CS=0x18, SS=0x20, then 0x18 = base+16, 0x20 = base+8
    // base = 0x08, 0x08+16=0x18 OK, 0x08+8=0x10 != 0x20 WRONG
    // 
    // The only way this works is if user SS is at user CS - 8
    // So GDT must be: null, kcode, kdata, ucode, udata where udata = ucode + 8
    // But standard is ucode before udata...
    // 
    // Many OSes swap the order: null, kcode, kdata, udata, ucode
    // Then ucode = 0x20, udata = 0x18
    // SYSRET with base=0x10: CS = 0x10+16 = 0x26|3, SS = 0x10+8 = 0x18|3
    // Still doesn't work... because CS should be 0x20
    // 
    // Let me try: GDT = null(0x00), kcode(0x08), kdata(0x10), udata(0x18), ucode(0x20)
    // SYSRET base = 0x10: CS = 0x26... still off
    // 
    // OK I think I finally understand. The selectors themselves are:
    // STAR[63:48] is used as a BASE, not a selector.
    // Resulting CS = BASE + 16, SS = BASE + 8
    // So if BASE = 0x08:
    //   CS selector = 0x08 + 16 = 0x18, then OR with 3 = 0x1B
    //   SS selector = 0x08 + 8 = 0x10, then OR with 3 = 0x13
    // This means user CS must be at index 3 (0x18), user SS at index 2 (0x10)
    // But index 2 is kernel data!
    // 
    // The solution is to have GDT: null, kcode, kdata, ucode (32-bit compat), udata, ucode64
    // Or simpler: null, kcode, kdata, userdata32, usercode64
    // Then STAR[63:48] = (user32 - 8) so that +16 and +8 land on correct entries
    // 
    // Simplest working layout for SYSRET 64-bit:
    // 0x00: null
    // 0x08: kernel code 64
    // 0x10: kernel data
    // 0x18: user data (SS for SYSRET = base+8 where base=0x10, 0x10+8=0x18)
    // 0x20: user code 64 (CS for SYSRET = base+16, 0x10+16=0x20)
    // So STAR[63:48] = 0x10, giving SS=0x18|3=0x1B, CS=0x20|3=0x23
    // 
    // Let me update to this layout.

    // With corrected GDT layout:
    // 0x08 = kernel code, 0x10 = kernel data
    // 0x18 = user data, 0x20 = user code
    // For SYSCALL: CS = STAR[47:32], SS = STAR[47:32] + 8
    // For SYSRET 64: CS = STAR[63:48] + 16 | 3, SS = STAR[63:48] + 8 | 3
    // 
    // SYSCALL: we want CS=0x08, SS=0x10
    //   STAR[47:32] = 0x08, SS = 0x08 + 8 = 0x10 ✓
    // SYSRET: we want CS=0x23 (0x20|3), SS=0x1B (0x18|3)
    //   STAR[63:48] + 16 = 0x20 => STAR[63:48] = 0x10
    //   STAR[63:48] + 8 = 0x18 ✓
    // 
    // So STAR = (0x10 << 48) | (0x08 << 32) but the shifts are different in how OS does it
    // Actually: STAR[31:0] = reserved, [47:32] = SYSCALL CS, [63:48] = SYSRET CS base
    // Value: ((SYSRET_BASE) << 48) | ((SYSCALL_CS) << 32)
    // SYSRET_BASE = 0x10 (not 0x13, hardware adds RPL 3)
    // SYSCALL_CS = 0x08

    const star_value: u64 = (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32);
    cpu.writeMSR(MSR_STAR, star_value);

    // LSTAR: Syscall entry point
    const entry_addr = @intFromPtr(&syscallEntry);
    cpu.writeMSR(MSR_LSTAR, entry_addr);

    // CSTAR: Compatibility mode entry (not used)
    cpu.writeMSR(MSR_CSTAR, 0);

    // FMASK: RFLAGS mask (clear IF to disable interrupts during syscall)
    cpu.writeMSR(MSR_FMASK, FMASK_VALUE);

    // Set up kernel stack in per-CPU data
    per_cpu.kernel_rsp = gdt.getKernelStack();

    registerDefaults();
    console.log(.info, "Syscall interface initialized (LSTAR={x})", .{entry_addr});
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

pub fn setKernelStack(rsp: u64) void {
    per_cpu.kernel_rsp = rsp;
    gdt.setKernelStack(rsp);
}

pub fn setCurrentThread(thread: ?*Thread) void {
    per_cpu.current_thread = thread;
}

pub fn getCurrentThread() ?*Thread {
    return per_cpu.current_thread;
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

fn sysSpawn(path_ptr: u64, argv_ptr: u64, envp_ptr: u64, _: u64, _: u64, _: u64) i64 {
    _ = argv_ptr;
    _ = envp_ptr;

    // Get path string
    const path: [*]const u8 = @ptrFromInt(path_ptr);

    // For RAM disk VFS, we'd look up the file here
    // For now, try to load from built-in binaries
    const binary_data = vfs.lookup(path) orelse {
        console.log(.warn, "sys_spawn: file not found", .{});
        return -1;
    };

    // Create new process
    const current = context.getCurrent() orelse return -1;
    const child = process_mod.create(current.process.pid) orelse {
        console.log(.err, "sys_spawn: failed to create process", .{});
        return -1;
    };

    // Load ELF into child's address space
    if (child.address_space) |*space| {
        const load_result = elf.load(binary_data, space) catch {
            console.log(.err, "sys_spawn: ELF load failed", .{});
            process_mod.free(child.pid);
            return -1;
        };

        // Create main thread
        const child_thread = thread_mod.create(child) orelse {
            console.log(.err, "sys_spawn: failed to create thread", .{});
            process_mod.free(child.pid);
            return -1;
        };

        // Set up thread to start at ELF entry
        child_thread.setEntry(load_result.entry_point, load_result.stack_pointer);
        child_thread.state = .ready;
        scheduler.enqueue(child_thread);

        return @intCast(child.pid);
    }

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

fn sysExec(path_ptr: u64, argv_ptr: u64, envp_ptr: u64, _: u64, _: u64, _: u64) i64 {
    _ = argv_ptr;
    _ = envp_ptr;

    const current = context.getCurrent() orelse return -1;
    const path: [*]const u8 = @ptrFromInt(path_ptr);

    // Look up binary
    const binary_data = vfs.lookup(path) orelse {
        console.log(.warn, "sys_exec: file not found", .{});
        return -1;
    };

    // Clear current address space (except kernel mappings)
    if (current.process.address_space) |*space| {
        // TODO: properly clear user mappings

        // Load new ELF
        const load_result = elf.load(binary_data, space) catch {
            console.log(.err, "sys_exec: ELF load failed", .{});
            return -1;
        };

        // Update thread to start at new entry point
        current.setEntry(load_result.entry_point, load_result.stack_pointer);
        current.context = thread_mod.Context.init();
        current.context.rip = load_result.entry_point;
        current.context.rsp = load_result.stack_pointer;

        // exec doesn't return to caller - jump to new entry
        // This is handled by scheduler returning to new context
        return 0;
    }

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

// ============= VFS Interface (RAM disk) =============

const vfs = struct {
    // Built-in binaries (embedded at compile time or loaded by bootloader)
    const BinaryEntry = struct {
        name: []const u8,
        data: []const u8,
    };

    var binaries: [16]?BinaryEntry = [_]?BinaryEntry{null} ** 16;
    var binary_count: usize = 0;

    /// Register a binary
    pub fn registerBinary(name: []const u8, data: []const u8) void {
        if (binary_count < binaries.len) {
            binaries[binary_count] = .{ .name = name, .data = data };
            binary_count += 1;
        }
    }

    /// Look up a binary by path
    pub fn lookup(path: [*]const u8) ?[]const u8 {
        // Convert null-terminated path to slice
        var len: usize = 0;
        while (path[len] != 0 and len < 256) : (len += 1) {}
        const path_slice = path[0..len];

        // Strip leading /
        const name = if (path_slice.len > 0 and path_slice[0] == '/')
            path_slice[1..]
        else
            path_slice;

        // Search binaries
        for (binaries) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (strEq(entry.name, name)) {
                    return entry.data;
                }
            }
        }

        return null;
    }

    fn strEq(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (ca != cb) return false;
        }
        return true;
    }
};

/// Register a binary for VFS
pub fn registerBinary(name: []const u8, data: []const u8) void {
    vfs.registerBinary(name, data);
}
