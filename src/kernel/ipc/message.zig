// Inter-Process Communication
//
// Synchronous message passing between threads.
// Messages are small (64 bytes max) for fast inline copy.

const Thread = @import("../proc/thread.zig").Thread;
const ThreadState = @import("../proc/thread.zig").ThreadState;
const scheduler = @import("../proc/scheduler.zig");
const context = @import("../proc/context.zig");
const console = @import("../lib/console.zig");

// Maximum inline message data
pub const MAX_MSG_DATA: usize = 56;

// Message header size
pub const MSG_HEADER_SIZE: usize = 8;

/// Message structure
pub const Message = struct {
    /// Message type/tag (user-defined)
    tag: u32,
    /// Data length (0-56 bytes)
    len: u32,
    /// Inline data
    data: [MAX_MSG_DATA]u8,

    pub fn init(tag: u32) Message {
        return .{
            .tag = tag,
            .len = 0,
            .data = [_]u8{0} ** MAX_MSG_DATA,
        };
    }

    /// Set message data
    pub fn setData(self: *Message, src: []const u8) void {
        const copy_len = @min(src.len, MAX_MSG_DATA);
        for (0..copy_len) |i| {
            self.data[i] = src[i];
        }
        self.len = @intCast(copy_len);
    }

    /// Get message data
    pub fn getData(self: *const Message) []const u8 {
        return self.data[0..self.len];
    }
};

// IPC endpoint states
pub const EndpointState = enum {
    idle,
    sending,
    receiving,
};

/// IPC endpoint for a thread
pub const Endpoint = struct {
    state: EndpointState,
    partner: ?*Thread, // Thread we're waiting for / communicating with
    message: ?*Message, // Message buffer pointer
    any_sender: bool, // Accept message from any sender

    pub fn init() Endpoint {
        return .{
            .state = .idle,
            .partner = null,
            .message = null,
            .any_sender = false,
        };
    }
};

// Endpoint storage (one per thread)
const MAX_ENDPOINTS: usize = 512;
var endpoints: [MAX_ENDPOINTS]Endpoint = [_]Endpoint{Endpoint.init()} ** MAX_ENDPOINTS;

/// Get endpoint for a thread
fn getEndpoint(thread: *Thread) *Endpoint {
    // Use TID as index (simple approach)
    const idx = thread.tid % MAX_ENDPOINTS;
    return &endpoints[idx];
}

/// Send a message to a thread (blocking)
pub fn send(dest: *Thread, msg: *const Message) i32 {
    const current = context.getCurrent() orelse return -1;
    const src_ep = getEndpoint(current);
    const dst_ep = getEndpoint(dest);

    // Check if destination is waiting to receive from us (or any)
    if (dst_ep.state == .receiving) {
        if (dst_ep.any_sender or dst_ep.partner == current) {
            // Direct transfer - destination is ready
            if (dst_ep.message) |dst_msg| {
                copyMessage(dst_msg, msg);
            }

            // Wake up destination
            dst_ep.state = .idle;
            dst_ep.partner = current;
            dest.state = .ready;
            scheduler.enqueue(dest);

            return 0;
        }
    }

    // Destination not ready - block sender
    src_ep.state = .sending;
    src_ep.partner = dest;
    src_ep.message = @constCast(msg);

    current.state = .blocked;
    scheduler.schedule();

    // When we wake up, message was delivered
    src_ep.state = .idle;
    return 0;
}

/// Receive a message (blocking)
/// If from is null, receive from any sender
pub fn receive(from: ?*Thread, msg: *Message) ?*Thread {
    const current = context.getCurrent() orelse return null;
    const my_ep = getEndpoint(current);

    // Check if specified sender (or any) is waiting to send to us
    if (from) |sender| {
        const sender_ep = getEndpoint(sender);
        if (sender_ep.state == .sending and sender_ep.partner == current) {
            // Sender is waiting for us
            if (sender_ep.message) |src_msg| {
                copyMessage(msg, src_msg);
            }

            // Wake up sender
            sender_ep.state = .idle;
            sender.state = .ready;
            scheduler.enqueue(sender);

            return sender;
        }
    } else {
        // Check for any waiting sender
        for (&endpoints) |*ep| {
            if (ep.state == .sending and ep.partner == current) {
                // Found a waiting sender
                if (ep.message) |src_msg| {
                    copyMessage(msg, src_msg);
                }

                // Find the thread for this endpoint
                // This is inefficient but works for now
                const sender = findThreadForEndpoint(ep);
                if (sender) |s| {
                    ep.state = .idle;
                    s.state = .ready;
                    scheduler.enqueue(s);
                    return s;
                }
            }
        }
    }

    // No sender ready - block receiver
    my_ep.state = .receiving;
    my_ep.partner = from;
    my_ep.message = msg;
    my_ep.any_sender = (from == null);

    current.state = .blocked;
    scheduler.schedule();

    // When we wake up, message was received
    my_ep.state = .idle;
    return my_ep.partner;
}

/// Copy message data
fn copyMessage(dst: *Message, src: *const Message) void {
    dst.tag = src.tag;
    dst.len = src.len;
    for (0..src.len) |i| {
        dst.data[i] = src.data[i];
    }
}

/// Find thread that owns an endpoint (inefficient, for now)
fn findThreadForEndpoint(ep: *Endpoint) ?*Thread {
    const thread_mod = @import("../proc/thread.zig");
    // This would need access to thread pool - simplified for now
    _ = ep;
    _ = thread_mod;
    return null;
}

/// Non-blocking send (returns immediately if can't send)
pub fn trySend(dest: *Thread, msg: *const Message) bool {
    const dst_ep = getEndpoint(dest);

    if (dst_ep.state == .receiving) {
        const current = context.getCurrent() orelse return false;
        if (dst_ep.any_sender or dst_ep.partner == current) {
            if (dst_ep.message) |dst_msg| {
                copyMessage(dst_msg, msg);
            }
            dst_ep.state = .idle;
            dst_ep.partner = current;
            dest.state = .ready;
            scheduler.enqueue(dest);
            return true;
        }
    }
    return false;
}

/// Non-blocking receive
pub fn tryReceive(msg: *Message) ?*Thread {
    const current = context.getCurrent() orelse return null;

    for (&endpoints) |*ep| {
        if (ep.state == .sending and ep.partner == current) {
            if (ep.message) |src_msg| {
                copyMessage(msg, src_msg);
            }
            const sender = findThreadForEndpoint(ep);
            if (sender) |s| {
                ep.state = .idle;
                s.state = .ready;
                scheduler.enqueue(s);
                return s;
            }
        }
    }
    return null;
}

/// Initialize IPC subsystem
pub fn init() void {
    for (&endpoints) |*ep| {
        ep.* = Endpoint.init();
    }
    console.log(.info, "IPC subsystem initialized", .{});
}
