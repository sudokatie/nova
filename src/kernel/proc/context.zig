// Context Switching
//
// Save and restore thread CPU context for context switches.

const Thread = @import("thread.zig").Thread;
const Context = @import("thread.zig").Context;
const vmm = @import("../mm/vmm.zig");
const console = @import("../lib/console.zig");

// Current running thread
var current_thread: ?*Thread = null;

/// Get the current running thread
pub fn getCurrent() ?*Thread {
    return current_thread;
}

/// Set the current running thread
pub fn setCurrent(thread: ?*Thread) void {
    current_thread = thread;
}

/// Switch from one thread to another
/// This is the core context switch routine
pub fn switchTo(old: ?*Thread, new: *Thread) void {
    if (old == new) return;

    // Save old thread's kernel RSP if it exists
    if (old) |o| {
        o.state = .ready;
        // Save current RSP to old thread
        o.kernel_rsp = asm volatile (""
            : [rsp] "={rsp}" (-> u64),
        );
    }

    // Switch address space if different process
    if (old) |o| {
        if (o.process != new.process) {
            if (new.process.address_space) |*space| {
                space.activate();
            }
        }
    } else {
        // No old thread, just switch to new address space
        if (new.process.address_space) |*space| {
            space.activate();
        }
    }

    // Update current thread
    new.state = .running;
    current_thread = new;

    // Restore new thread's context
    // Load new RSP and continue execution
    const new_rsp = new.kernel_rsp;
    asm volatile (
        \\mov %[rsp], %%rsp
        :
        : [rsp] "r" (new_rsp),
    );
}

/// Initialize a thread's context for first run
/// Sets up the kernel stack so switchTo will jump to entry point
pub fn initContext(thread: *Thread, entry: u64, arg: u64) void {
    // Stack grows down, start at top
    var sp = thread.kernel_stack_top;

    // Push initial context frame onto kernel stack
    // This mimics what an interrupt would push
    sp -= @sizeOf(Context);

    const ctx: *Context = @ptrFromInt(sp);
    ctx.* = Context.init();
    ctx.rip = entry;
    ctx.rdi = arg; // First argument
    ctx.rsp = thread.kernel_stack_top - 8; // Stack for entry function
    ctx.rflags = 0x202; // IF enabled

    thread.kernel_rsp = sp;
    thread.context = ctx.*;
}

/// Save FPU/SSE state (for future use)
pub fn saveFpuState(thread: *Thread) void {
    _ = thread;
    // TODO: FXSAVE to thread's FPU buffer
}

/// Restore FPU/SSE state (for future use)
pub fn restoreFpuState(thread: *Thread) void {
    _ = thread;
    // TODO: FXRSTOR from thread's FPU buffer
}

/// Perform a full context switch with register save/restore
/// This is called from the timer interrupt handler
pub fn contextSwitch(old: ?*Thread, new: *Thread) void {
    if (old == new) return;

    // Save old context if exists
    if (old) |o| {
        saveContext(o);
    }

    // Switch address space if needed
    if (old) |o| {
        if (o.process != new.process) {
            if (new.process.address_space) |*space| {
                space.activate();
            }
        }
    }

    // Update state
    if (old) |o| {
        if (o.state == .running) {
            o.state = .ready;
        }
    }
    new.state = .running;
    current_thread = new;

    // Restore new context
    restoreContext(new);
}

/// Save current CPU registers to thread
fn saveContext(thread: *Thread) void {
    // In a real implementation, this would be done in assembly
    // by the interrupt handler pushing registers to stack
    _ = thread;
}

/// Restore CPU registers from thread
fn restoreContext(thread: *Thread) void {
    // In a real implementation, this would pop registers
    // and iret back to the thread
    _ = thread;
}
