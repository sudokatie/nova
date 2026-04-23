// Thread Management
//
// Thread structure and kernel stack management.

const pmm = @import("../mm/pmm.zig");
const console = @import("../lib/console.zig");
const Process = @import("process.zig").Process;
const Pid = @import("process.zig").Pid;

// Kernel stack size (8KB)
pub const KERNEL_STACK_SIZE: u64 = 8192;
pub const KERNEL_STACK_PAGES: u64 = 2;

// FPU/SSE state size for FXSAVE/FXRSTOR (512 bytes, 16-byte aligned)
pub const FPU_STATE_SIZE: usize = 512;

/// FPU/SSE state saved by FXSAVE instruction
/// 512 bytes, must be 16-byte aligned
pub const FpuState = extern struct {
    data: [FPU_STATE_SIZE]u8 align(16),

    pub fn init() FpuState {
        // Initialize to a clean FPU state
        // FXSAVE format: first 2 bytes are FCW (control word)
        // Default FCW: 0x037F (all exceptions masked, double precision)
        var state = FpuState{ .data = [_]u8{0} ** FPU_STATE_SIZE };
        state.data[0] = 0x7F;
        state.data[1] = 0x03;
        // MXCSR at offset 24: default 0x1F80 (all SSE exceptions masked)
        state.data[24] = 0x80;
        state.data[25] = 0x1F;
        return state;
    }
};

// Thread ID type
pub const Tid = u32;

/// Thread state
pub const ThreadState = enum {
    created, // Just created
    ready, // Ready to run
    running, // Currently running
    blocked, // Waiting for something
    sleeping, // Sleeping for time
    terminated, // Finished execution
};

/// CPU context saved on context switch
pub const Context = extern struct {
    // Callee-saved registers
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,

    // Caller-saved (saved for syscall entry)
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,

    // Interrupt frame
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    pub fn init() Context {
        return .{
            .r15 = 0,
            .r14 = 0,
            .r13 = 0,
            .r12 = 0,
            .rbp = 0,
            .rbx = 0,
            .r11 = 0,
            .r10 = 0,
            .r9 = 0,
            .r8 = 0,
            .rdi = 0,
            .rsi = 0,
            .rdx = 0,
            .rcx = 0,
            .rax = 0,
            .rip = 0,
            .cs = 0x08, // Kernel code segment
            .rflags = 0x202, // IF enabled
            .rsp = 0,
            .ss = 0x10, // Kernel data segment
        };
    }
};

/// Thread structure
pub const Thread = struct {
    tid: Tid,
    process: *Process,
    state: ThreadState,
    context: Context,
    kernel_stack_base: u64, // Bottom of kernel stack (lowest address)
    kernel_stack_top: u64, // Top of kernel stack (highest address)
    kernel_rsp: u64, // Current kernel stack pointer
    priority: u8,
    time_slice: u32, // Remaining time slice in ticks
    sleep_until: u64, // Wake up at this tick count (if sleeping)
    fpu_state: FpuState, // FPU/SSE state for context switches
    fpu_initialized: bool, // Whether FPU state has been initialized

    /// Initialize a new thread
    pub fn init(tid: Tid, process: *Process) Thread {
        return .{
            .tid = tid,
            .process = process,
            .state = .created,
            .context = Context.init(),
            .kernel_stack_base = 0,
            .kernel_stack_top = 0,
            .kernel_rsp = 0,
            .priority = 128, // Default priority
            .time_slice = 5, // Default time slice (50ms at 100Hz)
            .sleep_until = 0,
            .fpu_state = FpuState.init(),
            .fpu_initialized = false,
        };
    }

    /// Allocate kernel stack for this thread
    pub fn allocKernelStack(self: *Thread) bool {
        const phys = pmm.allocPages(KERNEL_STACK_PAGES) orelse {
            console.log(.err, "Thread {}: Failed to allocate kernel stack", .{self.tid});
            return false;
        };

        self.kernel_stack_base = pmm.physToVirt(phys);
        self.kernel_stack_top = self.kernel_stack_base + KERNEL_STACK_SIZE;
        self.kernel_rsp = self.kernel_stack_top; // Stack grows down

        return true;
    }

    /// Free kernel stack
    pub fn freeKernelStack(self: *Thread) void {
        if (self.kernel_stack_base != 0) {
            const phys = pmm.virtToPhys(self.kernel_stack_base);
            pmm.freePages(phys, KERNEL_STACK_PAGES);
            self.kernel_stack_base = 0;
            self.kernel_stack_top = 0;
            self.kernel_rsp = 0;
        }
    }

    /// Set entry point for this thread
    pub fn setEntry(self: *Thread, entry: u64, stack: u64) void {
        self.context.rip = entry;
        self.context.rsp = stack;
    }

    /// Set arguments (for function-like entry)
    pub fn setArgs(self: *Thread, arg1: u64, arg2: u64, arg3: u64) void {
        self.context.rdi = arg1;
        self.context.rsi = arg2;
        self.context.rdx = arg3;
    }

    /// Mark as ready to run
    pub fn makeReady(self: *Thread) void {
        self.state = .ready;
    }

    /// Block the thread
    pub fn block(self: *Thread) void {
        self.state = .blocked;
    }

    /// Unblock the thread
    pub fn unblock(self: *Thread) void {
        if (self.state == .blocked) {
            self.state = .ready;
        }
    }

    /// Terminate the thread
    pub fn terminate(self: *Thread) void {
        self.state = .terminated;
        self.process.removeThread(self);
    }
};

// Thread pool
const MAX_THREADS: usize = 512;
var thread_pool: [MAX_THREADS]?Thread = [_]?Thread{null} ** MAX_THREADS;
var next_tid: Tid = 1;
var initialized: bool = false;

/// Initialize thread subsystem
pub fn init() void {
    initialized = true;
    console.log(.info, "Thread subsystem initialized", .{});
}

/// Create a new thread for a process
pub fn create(process: *Process) ?*Thread {
    // Find free slot
    var slot_idx: ?usize = null;
    for (thread_pool, 0..) |t, i| {
        if (t == null) {
            slot_idx = i;
            break;
        }
    }

    const idx = slot_idx orelse {
        console.log(.err, "Thread: No free thread slots", .{});
        return null;
    };

    const tid = next_tid;
    next_tid += 1;

    var thread = Thread.init(tid, process);
    if (!thread.allocKernelStack()) {
        return null;
    }

    thread_pool[idx] = thread;
    const thread_ptr = &thread_pool[idx].?;

    if (!process.addThread(thread_ptr)) {
        thread.freeKernelStack();
        thread_pool[idx] = null;
        console.log(.err, "Thread {}: Process rejected thread", .{tid});
        return null;
    }

    console.log(.debug, "Thread {}: Created for process {}", .{ tid, process.pid });
    return thread_ptr;
}

/// Get thread by TID
pub fn get(tid: Tid) ?*Thread {
    for (&thread_pool) |*slot| {
        if (slot.*) |*t| {
            if (t.tid == tid) return t;
        }
    }
    return null;
}

/// Free a thread
pub fn free(thread: *Thread) void {
    thread.freeKernelStack();
    for (&thread_pool) |*slot| {
        if (slot.*) |*t| {
            if (t == thread) {
                slot.* = null;
                console.log(.debug, "Thread {}: Freed", .{thread.tid});
                return;
            }
        }
    }
}

/// Get count of active threads
pub fn getCount() usize {
    var count: usize = 0;
    for (thread_pool) |t| {
        if (t != null) count += 1;
    }
    return count;
}
