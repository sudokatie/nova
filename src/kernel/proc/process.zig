// Process Management
//
// Process structure and lifecycle management.

const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const console = @import("../lib/console.zig");
const Thread = @import("thread.zig").Thread;

// Maximum number of processes
pub const MAX_PROCESSES: usize = 256;

// Process ID type
pub const Pid = u32;

/// Process state
pub const ProcessState = enum {
    created, // Just created, not yet runnable
    ready, // Ready to run
    running, // Currently running (has running thread)
    blocked, // Waiting for something
    zombie, // Terminated, waiting for parent
    terminated, // Fully terminated
};

/// Process structure
pub const Process = struct {
    pid: Pid,
    parent_pid: ?Pid,
    state: ProcessState,
    address_space: ?vmm.AddressSpace,
    threads: [MAX_THREADS_PER_PROCESS]?*Thread,
    thread_count: usize,
    exit_code: i32,
    name: [32]u8,
    name_len: usize,

    const MAX_THREADS_PER_PROCESS = 16;

    /// Initialize a new process
    pub fn init(pid: Pid, parent: ?Pid) Process {
        return .{
            .pid = pid,
            .parent_pid = parent,
            .state = .created,
            .address_space = null,
            .threads = [_]?*Thread{null} ** MAX_THREADS_PER_PROCESS,
            .thread_count = 0,
            .exit_code = 0,
            .name = [_]u8{0} ** 32,
            .name_len = 0,
        };
    }

    /// Set process name
    pub fn setName(self: *Process, name: []const u8) void {
        const len = @min(name.len, 31);
        for (0..len) |i| {
            self.name[i] = name[i];
        }
        self.name[len] = 0;
        self.name_len = len;
    }

    /// Get process name
    pub fn getName(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Create address space for this process
    pub fn createAddressSpace(self: *Process) bool {
        self.address_space = vmm.createUserSpace() orelse {
            console.log(.err, "Process {}: Failed to create address space", .{self.pid});
            return false;
        };
        return true;
    }

    /// Add a thread to this process
    pub fn addThread(self: *Process, thread: *Thread) bool {
        for (&self.threads) |*slot| {
            if (slot.* == null) {
                slot.* = thread;
                self.thread_count += 1;
                return true;
            }
        }
        return false; // No free thread slots
    }

    /// Remove a thread from this process
    pub fn removeThread(self: *Process, thread: *Thread) void {
        for (&self.threads) |*slot| {
            if (slot.* == thread) {
                slot.* = null;
                self.thread_count -= 1;
                break;
            }
        }
    }

    /// Terminate the process
    pub fn terminate(self: *Process, exit_code: i32) void {
        self.exit_code = exit_code;
        self.state = .zombie;
        // TODO: Notify parent, cleanup threads
    }
};

// Process table
var process_table: [MAX_PROCESSES]?Process = [_]?Process{null} ** MAX_PROCESSES;
var next_pid: Pid = 1; // PID 0 is reserved for kernel/idle
var initialized: bool = false;

/// Initialize the process subsystem
pub fn init() void {
    // Create kernel process (PID 0)
    var kernel_proc = Process.init(0, null);
    kernel_proc.setName("kernel");
    kernel_proc.state = .running;
    kernel_proc.address_space = vmm.getKernelSpace().*;
    process_table[0] = kernel_proc;

    initialized = true;
    console.log(.info, "Process subsystem initialized", .{});
}

/// Allocate a new PID
pub fn allocPid() ?Pid {
    // Simple linear search for now
    var pid = next_pid;
    var attempts: usize = 0;

    while (attempts < MAX_PROCESSES) {
        if (pid >= MAX_PROCESSES) {
            pid = 1; // Wrap around (skip 0)
        }
        if (process_table[pid] == null) {
            next_pid = pid + 1;
            return pid;
        }
        pid += 1;
        attempts += 1;
    }

    return null; // No free PIDs
}

/// Create a new process
pub fn create(parent: ?Pid) ?*Process {
    const pid = allocPid() orelse {
        console.log(.err, "Process: No free PIDs", .{});
        return null;
    };

    var proc = Process.init(pid, parent);
    if (!proc.createAddressSpace()) {
        return null;
    }
    proc.state = .created;

    process_table[pid] = proc;
    console.log(.debug, "Process {}: Created", .{pid});
    return &process_table[pid].?;
}

/// Get process by PID
pub fn get(pid: Pid) ?*Process {
    if (pid >= MAX_PROCESSES) return null;
    if (process_table[pid]) |*proc| {
        return proc;
    }
    return null;
}

/// Get kernel process
pub fn getKernel() *Process {
    return &process_table[0].?;
}

/// Free a process entry
pub fn free(pid: Pid) void {
    if (pid == 0) return; // Can't free kernel
    if (pid >= MAX_PROCESSES) return;

    if (process_table[pid]) |*proc| {
        // TODO: Free address space, cleanup threads
        _ = proc;
        process_table[pid] = null;
        console.log(.debug, "Process {}: Freed", .{pid});
    }
}

/// Get count of active processes
pub fn getCount() usize {
    var count: usize = 0;
    for (process_table) |proc| {
        if (proc != null) count += 1;
    }
    return count;
}
