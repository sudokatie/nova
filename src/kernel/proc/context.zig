// Context Switching
//
// Save and restore thread CPU context for context switches.
// Uses assembly for proper register manipulation.

const Thread = @import("thread.zig").Thread;
const Context = @import("thread.zig").Context;
const ThreadState = @import("thread.zig").ThreadState;
const vmm = @import("../mm/vmm.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const console = @import("../lib/console.zig");

// Current running thread (per-CPU, but we only have one CPU)
var current_thread: ?*Thread = null;

/// Get the current running thread
pub fn getCurrent() ?*Thread {
    return current_thread;
}

/// Set the current running thread
pub fn setCurrent(thread: ?*Thread) void {
    current_thread = thread;
}

/// Initialize a thread's context for first run
/// Sets up the kernel stack so context switch will start execution at entry point
pub fn initContext(thread: *Thread, entry: u64, arg: u64) void {
    // Stack grows down, start at top
    var sp = thread.kernel_stack_top;

    // We need to set up the stack so that when we "restore" this context,
    // execution begins at the entry point.
    //
    // Stack layout (from top to bottom):
    // - SS (for iret to userspace, or dummy for kernel)
    // - RSP (user stack or kernel stack)
    // - RFLAGS
    // - CS
    // - RIP (entry point)
    // - Error code (0)
    // - Callee-saved registers (r15, r14, r13, r12, rbp, rbx)
    // - Caller-saved registers (r11, r10, r9, r8, rdi, rsi, rdx, rcx, rax)

    // Align stack to 16 bytes
    sp = sp & ~@as(u64, 0xF);

    // Push interrupt frame
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0x10; // SS (kernel data)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = thread.kernel_stack_top - 8; // RSP
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0x202; // RFLAGS (IF enabled)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0x08; // CS (kernel code)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = entry; // RIP

    // Push error code
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    // Push general purpose registers (in order they'll be popped)
    // RAX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // RCX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // RDX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // RSI
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // RDI - first argument
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = arg;
    // R8
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R9
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R10
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R11
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // RBX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // RBP
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R12
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R13
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R14
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    // R15
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    thread.kernel_rsp = sp;

    // Also set up the context struct for debugging
    thread.context.rip = entry;
    thread.context.rdi = arg;
    thread.context.rsp = thread.kernel_stack_top - 8;
    thread.context.rflags = 0x202;
}

/// Perform a context switch from old thread to new thread
/// This saves the current context and restores the new one
pub fn contextSwitch(old: ?*Thread, new: *Thread) void {
    if (old) |o| {
        if (o == new) return;
    }

    // Update thread states
    if (old) |o| {
        if (o.state == .running) {
            o.state = .ready;
        }
    }
    new.state = .running;

    // Switch address space if different process
    const need_space_switch = if (old) |o|
        o.process != new.process
    else
        true;

    if (need_space_switch) {
        if (new.process.address_space) |*space| {
            space.activate();
        }
    }

    // Update kernel stack in TSS for syscalls/interrupts
    gdt.setKernelStack(new.kernel_stack_top);

    // Update current thread
    current_thread = new;

    // Perform the actual context switch
    if (old) |o| {
        switchContexts(&o.kernel_rsp, new.kernel_rsp);
    } else {
        // No old context to save, just load new
        loadContext(new.kernel_rsp);
    }
}

// External assembly function from asm_stubs.s
extern fn asm_switch_contexts(old_rsp_ptr: *u64, new_rsp: u64) void;

/// Assembly routine to switch between two contexts
/// Saves callee-saved registers to old stack, loads new stack, restores registers
fn switchContexts(old_rsp_ptr: *u64, new_rsp: u64) void {
    asm_switch_contexts(old_rsp_ptr, new_rsp);
}

/// Load a new context without saving old one (for first switch)
fn loadContext(new_rsp: u64) void {
    asm volatile (
    // Load new stack pointer
        \\movq %[new_rsp], %%rsp
        \\
        // Pop all registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbp
        \\popq %%rbx
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\
        // Skip error code
        \\addq $8, %%rsp
        \\
        // Return via iret
        \\iretq
        :
        : [new_rsp] "r" (new_rsp),
        : .{ .memory = true });
}

/// Switch from kernel to user mode (used when starting a userspace thread)
pub fn switchToUser(entry: u64, user_stack: u64, arg: u64) noreturn {
    asm volatile (
    // Set up stack for iret to user mode
        \\pushq $0x23          // User SS (0x20 | 3)
        \\pushq %[user_stack]  // User RSP
        \\pushq $0x202         // RFLAGS (IF enabled)
        \\pushq $0x1B          // User CS (0x18 | 3)
        \\pushq %[entry]       // User RIP
        \\
        // Set up argument in RDI
        \\movq %[arg], %%rdi
        \\
        // Clear other registers for security
        \\xorq %%rax, %%rax
        \\xorq %%rbx, %%rbx
        \\xorq %%rcx, %%rcx
        \\xorq %%rdx, %%rdx
        \\xorq %%rsi, %%rsi
        \\xorq %%rbp, %%rbp
        \\xorq %%r8, %%r8
        \\xorq %%r9, %%r9
        \\xorq %%r10, %%r10
        \\xorq %%r11, %%r11
        \\xorq %%r12, %%r12
        \\xorq %%r13, %%r13
        \\xorq %%r14, %%r14
        \\xorq %%r15, %%r15
        \\
        // Return to user mode
        \\iretq
        :
        : [entry] "r" (entry),
          [user_stack] "r" (user_stack),
          [arg] "r" (arg),
        : .{ .memory = true });
    unreachable;
}

/// Save FPU/SSE state
pub fn saveFpuState(thread: *Thread) void {
    _ = thread;
    // TODO: FXSAVE to thread's FPU buffer when we support FPU
}

/// Restore FPU/SSE state
pub fn restoreFpuState(thread: *Thread) void {
    _ = thread;
    // TODO: FXRSTOR from thread's FPU buffer when we support FPU
}

/// Yield the current thread's remaining time slice
pub fn yield() void {
    const scheduler = @import("scheduler.zig");
    scheduler.yield();
}

/// Simple switch without full context frame (for cooperative switching)
pub fn switchTo(old: ?*Thread, new: *Thread) void {
    contextSwitch(old, new);
}

/// Initialize a thread's context for first run in userspace
/// Sets up the kernel stack so context switch will iret to user mode
pub fn initUserContext(thread: *Thread, entry: u64, user_stack: u64) void {
    const gdt_mod = @import("../arch/x86_64/gdt.zig");

    // Stack grows down, start at top
    var sp = thread.kernel_stack_top;

    // Align stack to 16 bytes
    sp = sp & ~@as(u64, 0xF);

    // Push interrupt frame for iret to user mode
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = gdt_mod.USER_DS; // SS (user data, ring 3)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = user_stack; // User RSP
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0x202; // RFLAGS (IF enabled)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = gdt_mod.USER_CS; // CS (user code, ring 3)
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = entry; // User RIP

    // Push error code
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    // Push general purpose registers (zeroed for clean start)
    // RAX through R15 in the order loadContext expects
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RAX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RCX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RDX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RSI
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RDI
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R8
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R9
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R10
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R11
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RBX
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // RBP
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R12
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R13
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R14
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0; // R15

    thread.kernel_rsp = sp;

    // Also set up the context struct for debugging
    thread.context.rip = entry;
    thread.context.rsp = user_stack;
    thread.context.rflags = 0x202;
    thread.context.cs = gdt_mod.USER_CS;
    thread.context.ss = gdt_mod.USER_DS;
}
