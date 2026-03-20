// Scheduler
//
// Priority-based round-robin scheduler.
// Manages run queues and performs thread scheduling.

const Thread = @import("thread.zig").Thread;
const ThreadState = @import("thread.zig").ThreadState;
const context = @import("context.zig");
const process = @import("process.zig");
const thread_mod = @import("thread.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const console = @import("../lib/console.zig");

// Priority levels
pub const NUM_PRIORITIES: usize = 3;
pub const PRIORITY_HIGH: u8 = 0;
pub const PRIORITY_NORMAL: u8 = 1;
pub const PRIORITY_LOW: u8 = 2;

// Default time slice in ticks (50ms at 100Hz = 5 ticks)
pub const DEFAULT_TIME_SLICE: u32 = 5;

// Run queue entry (simple linked list)
const QueueNode = struct {
    thread: *Thread,
    next: ?*QueueNode,
};

// Static pool of queue nodes
const MAX_QUEUE_NODES: usize = 512;
var node_pool: [MAX_QUEUE_NODES]QueueNode = undefined;
var node_used: [MAX_QUEUE_NODES]bool = [_]bool{false} ** MAX_QUEUE_NODES;

// Run queues (one per priority)
var run_queues: [NUM_PRIORITIES]?*QueueNode = [_]?*QueueNode{null} ** NUM_PRIORITIES;
var queue_tails: [NUM_PRIORITIES]?*QueueNode = [_]?*QueueNode{null} ** NUM_PRIORITIES;

// Idle thread
var idle_thread: ?*Thread = null;

// Scheduler state
var initialized: bool = false;
var scheduler_enabled: bool = false;

/// Allocate a queue node
fn allocNode() ?*QueueNode {
    for (&node_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            return &node_pool[i];
        }
    }
    return null;
}

/// Free a queue node
fn freeNode(node: *QueueNode) void {
    const idx = (@intFromPtr(node) - @intFromPtr(&node_pool[0])) / @sizeOf(QueueNode);
    if (idx < MAX_QUEUE_NODES) {
        node_used[idx] = false;
    }
}

/// Initialize the scheduler
pub fn init() void {
    // Create idle thread in kernel process
    const kernel_proc = process.getKernel();
    idle_thread = thread_mod.create(kernel_proc);

    if (idle_thread) |t| {
        t.priority = PRIORITY_LOW;
        context.initContext(t, @intFromPtr(&idleLoop), 0);
        console.log(.debug, "Scheduler: Idle thread created (TID {})", .{t.tid});
    } else {
        console.log(.err, "Scheduler: Failed to create idle thread", .{});
    }

    initialized = true;
    console.log(.info, "Scheduler initialized", .{});
}

/// Idle loop - runs when no other threads are ready
fn idleLoop() noreturn {
    while (true) {
        cpu.enableInterrupts();
        asm volatile ("hlt");
    }
}

/// Add a thread to the run queue
pub fn enqueue(thread: *Thread) void {
    if (thread.state == .terminated) return;

    const priority = getPriorityIndex(thread.priority);

    const node = allocNode() orelse {
        console.log(.err, "Scheduler: Run queue full", .{});
        return;
    };

    node.thread = thread;
    node.next = null;

    // Add to tail of queue
    if (queue_tails[priority]) |tail| {
        tail.next = node;
        queue_tails[priority] = node;
    } else {
        run_queues[priority] = node;
        queue_tails[priority] = node;
    }

    thread.state = .ready;
}

/// Remove a thread from the run queue
pub fn dequeue(thread: *Thread) void {
    const priority = getPriorityIndex(thread.priority);

    var prev: ?*QueueNode = null;
    var curr = run_queues[priority];

    while (curr) |node| {
        if (node.thread == thread) {
            // Remove from list
            if (prev) |p| {
                p.next = node.next;
            } else {
                run_queues[priority] = node.next;
            }

            // Update tail if needed
            if (queue_tails[priority] == node) {
                queue_tails[priority] = prev;
            }

            freeNode(node);
            return;
        }
        prev = node;
        curr = node.next;
    }
}

/// Get priority index (0-2)
fn getPriorityIndex(priority: u8) usize {
    if (priority < 85) return PRIORITY_HIGH;
    if (priority < 170) return PRIORITY_NORMAL;
    return PRIORITY_LOW;
}

/// Pick the next thread to run
fn pickNext() ?*Thread {
    // Check queues in priority order
    for (0..NUM_PRIORITIES) |p| {
        if (run_queues[p]) |node| {
            // Remove from head
            run_queues[p] = node.next;
            if (run_queues[p] == null) {
                queue_tails[p] = null;
            }

            const thread = node.thread;
            freeNode(node);
            return thread;
        }
    }

    // No ready threads, return idle
    return idle_thread;
}

/// Main scheduling function
pub fn schedule() void {
    if (!initialized or !scheduler_enabled) return;

    const old = context.getCurrent();
    const new = pickNext() orelse return;

    if (old) |o| {
        // Re-enqueue old thread if still runnable
        if (o.state == .running) {
            o.time_slice = DEFAULT_TIME_SLICE;
            enqueue(o);
        }
    }

    // Reset time slice for new thread
    new.time_slice = DEFAULT_TIME_SLICE;

    // Perform the switch
    context.contextSwitch(old, new);
}

/// Called on timer tick
pub fn tick() void {
    if (!scheduler_enabled) return;

    if (context.getCurrent()) |current| {
        if (current.time_slice > 0) {
            current.time_slice -= 1;
        }

        // Preempt if time slice expired
        if (current.time_slice == 0) {
            schedule();
        }
    }
}

/// Yield current thread's remaining time slice
pub fn yield() void {
    if (context.getCurrent()) |current| {
        current.time_slice = 0;
        schedule();
    }
}

/// Block the current thread
pub fn blockCurrent() void {
    if (context.getCurrent()) |current| {
        current.state = .blocked;
        schedule();
    }
}

/// Unblock a thread
/// Preempts current thread if unblocked thread has higher priority
pub fn unblock(thread: *Thread) void {
    if (thread.state == .blocked or thread.state == .sleeping) {
        thread.state = .ready;
        enqueue(thread);

        // Check if we should preempt
        if (context.getCurrent()) |current| {
            if (shouldPreempt(current, thread)) {
                // Higher priority thread is now ready - preempt
                schedule();
            }
        }
    }
}

/// Check if new_thread should preempt current_thread
fn shouldPreempt(current_thread: *Thread, new_thread: *Thread) bool {
    const current_prio = getPriorityIndex(current_thread.priority);
    const new_prio = getPriorityIndex(new_thread.priority);

    // Lower index = higher priority
    return new_prio < current_prio;
}

/// Enable the scheduler
pub fn enable() void {
    scheduler_enabled = true;
    console.log(.info, "Scheduler enabled", .{});
}

/// Disable the scheduler
pub fn disable() void {
    scheduler_enabled = false;
}

/// Check if scheduler is enabled
pub fn isEnabled() bool {
    return scheduler_enabled;
}

/// Get count of threads in run queues
pub fn getReadyCount() usize {
    var count: usize = 0;
    for (0..NUM_PRIORITIES) |p| {
        var curr = run_queues[p];
        while (curr) |node| {
            count += 1;
            curr = node.next;
        }
    }
    return count;
}
