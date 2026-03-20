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
    for (&notifications) |*n| {
        n.* = Notification.init();
    }
    for (&shared_regions) |*r| {
        r.* = SharedRegion.init();
    }
    console.log(.info, "IPC subsystem initialized", .{});
}

// ============= Last Caller Tracking (for reply) =============

var last_callers: [MAX_ENDPOINTS]?*Thread = [_]?*Thread{null} ** MAX_ENDPOINTS;

/// Get the last caller for a thread (used by reply syscall)
pub fn getLastCaller(thread: *Thread) ?*Thread {
    const idx = thread.tid % MAX_ENDPOINTS;
    return last_callers[idx];
}

/// Set the last caller for a thread
fn setLastCaller(receiver: *Thread, caller: *Thread) void {
    const idx = receiver.tid % MAX_ENDPOINTS;
    last_callers[idx] = caller;
}

// ============= Memory Grants =============

pub const MAX_GRANTS: usize = 4;

pub const MemoryGrant = struct {
    phys_addr: u64,
    length: u64,
    rights: GrantRights,
    valid: bool,

    pub fn init() MemoryGrant {
        return .{ .phys_addr = 0, .length = 0, .rights = .{}, .valid = false };
    }
};

pub const GrantRights = packed struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    _reserved: u5 = 0,
};

/// Extended message with memory grants
pub const ExtendedMessage = struct {
    base: Message,
    grants: [MAX_GRANTS]MemoryGrant,
    grant_count: u8,

    pub fn init(tag: u32) ExtendedMessage {
        return .{
            .base = Message.init(tag),
            .grants = [_]MemoryGrant{MemoryGrant.init()} ** MAX_GRANTS,
            .grant_count = 0,
        };
    }

    /// Add a memory grant
    pub fn addGrant(self: *ExtendedMessage, phys: u64, len: u64, rights: GrantRights) bool {
        if (self.grant_count >= MAX_GRANTS) return false;
        self.grants[self.grant_count] = .{
            .phys_addr = phys,
            .length = len,
            .rights = rights,
            .valid = true,
        };
        self.grant_count += 1;
        return true;
    }
};

// ============= Capabilities =============

pub const CapabilityType = enum(u8) {
    none = 0,
    port = 1,
    memory = 2,
    thread = 3,
    process = 4,
};

pub const Capability = struct {
    cap_type: CapabilityType,
    object_id: u32,
    rights: u8,
    valid: bool,

    pub fn init() Capability {
        return .{ .cap_type = .none, .object_id = 0, .rights = 0, .valid = false };
    }
};

pub const MAX_CAPS_PER_MSG: usize = 2;

/// Message with capability transfer
pub const CapMessage = struct {
    base: Message,
    caps: [MAX_CAPS_PER_MSG]Capability,
    cap_count: u8,

    pub fn init(tag: u32) CapMessage {
        return .{
            .base = Message.init(tag),
            .caps = [_]Capability{Capability.init()} ** MAX_CAPS_PER_MSG,
            .cap_count = 0,
        };
    }

    /// Add a capability
    pub fn addCapability(self: *CapMessage, cap_type: CapabilityType, obj_id: u32, rights: u8) bool {
        if (self.cap_count >= MAX_CAPS_PER_MSG) return false;
        self.caps[self.cap_count] = .{
            .cap_type = cap_type,
            .object_id = obj_id,
            .rights = rights,
            .valid = true,
        };
        self.cap_count += 1;
        return true;
    }
};

// ============= Notification Objects =============

pub const MAX_NOTIFICATIONS: usize = 64;

pub const Notification = struct {
    id: u32,
    word: u64, // Bitmap of pending signals
    waiting_thread: ?*Thread,
    owner: ?*Thread,
    active: bool,

    pub fn init() Notification {
        return .{
            .id = 0,
            .word = 0,
            .waiting_thread = null,
            .owner = null,
            .active = false,
        };
    }
};

var notifications: [MAX_NOTIFICATIONS]Notification = undefined;
var next_notification_id: u32 = 1;

/// Create a notification object
pub fn createNotification(owner: *Thread) ?*Notification {
    for (&notifications, 0..) |*n, i| {
        if (!n.active) {
            n.* = Notification.init();
            n.id = next_notification_id;
            next_notification_id += 1;
            n.owner = owner;
            n.active = true;
            _ = i;
            return n;
        }
    }
    return null;
}

/// Signal a notification (set bits in word)
pub fn signal(notif: *Notification, bits: u64) void {
    notif.word |= bits;

    // Wake waiting thread if any
    if (notif.waiting_thread) |t| {
        notif.waiting_thread = null;
        t.state = .ready;
        scheduler.enqueue(t);
    }
}

/// Wait for notification (blocks until bits set)
pub fn waitNotification(notif: *Notification) u64 {
    const current = context.getCurrent() orelse return 0;

    if (notif.word != 0) {
        // Already signaled
        const result = notif.word;
        notif.word = 0;
        return result;
    }

    // Block and wait
    notif.waiting_thread = current;
    current.state = .blocked;
    scheduler.schedule();

    // Woken up - read and clear
    const result = notif.word;
    notif.word = 0;
    return result;
}

/// Poll notification (non-blocking)
pub fn pollNotification(notif: *Notification) u64 {
    const result = notif.word;
    notif.word = 0;
    return result;
}

/// Destroy notification
pub fn destroyNotification(notif: *Notification) void {
    if (notif.waiting_thread) |t| {
        t.state = .ready;
        scheduler.enqueue(t);
    }
    notif.* = Notification.init();
}

// ============= Shared Memory Regions =============

pub const MAX_SHARED_REGIONS: usize = 32;

pub const SharedRegion = struct {
    id: u32,
    phys_base: u64,
    size: u64,
    owner: ?*Thread,
    mappings: [8]?*Thread, // Threads that have this mapped
    mapping_count: usize,
    active: bool,

    pub fn init() SharedRegion {
        return .{
            .id = 0,
            .phys_base = 0,
            .size = 0,
            .owner = null,
            .mappings = [_]?*Thread{null} ** 8,
            .mapping_count = 0,
            .active = false,
        };
    }
};

var shared_regions: [MAX_SHARED_REGIONS]SharedRegion = undefined;
var next_region_id: u32 = 1;

/// Create a shared memory region
pub fn createSharedRegion(owner: *Thread, size: u64) ?*SharedRegion {
    const pmm = @import("../mm/pmm.zig");

    // Allocate physical pages
    const num_pages = (size + 4095) / 4096;
    const phys = pmm.allocPages(num_pages) orelse return null;

    for (&shared_regions) |*r| {
        if (!r.active) {
            r.* = SharedRegion.init();
            r.id = next_region_id;
            next_region_id += 1;
            r.phys_base = phys;
            r.size = num_pages * 4096;
            r.owner = owner;
            r.active = true;
            return r;
        }
    }

    // No free slot - free allocated pages
    pmm.freePages(phys, num_pages);
    return null;
}

/// Map shared region into thread's address space
pub fn mapSharedRegion(region: *SharedRegion, thread: *Thread, virt_addr: u64) bool {
    const vmm = @import("../mm/vmm.zig");

    // Check if already mapped
    for (region.mappings) |m| {
        if (m == thread) return true; // Already mapped
    }

    // Find free slot
    for (&region.mappings) |*m| {
        if (m.* == null) {
            // Map into thread's address space
            if (thread.process.address_space) |*space| {
                const num_pages = region.size / 4096;
                const flags = vmm.MapFlags{ .writable = true, .user = true };
                if (!vmm.mapRange(space, virt_addr, region.phys_base, num_pages, flags)) {
                    return false;
                }
                m.* = thread;
                region.mapping_count += 1;
                return true;
            }
        }
    }

    return false;
}

/// Unmap shared region from thread
pub fn unmapSharedRegion(region: *SharedRegion, thread: *Thread, virt_addr: u64) void {
    const vmm = @import("../mm/vmm.zig");

    for (&region.mappings) |*m| {
        if (m.* == thread) {
            if (thread.process.address_space) |*space| {
                vmm.unmapRange(space, virt_addr, region.size / 4096);
            }
            m.* = null;
            region.mapping_count -= 1;
            return;
        }
    }
}

/// Destroy shared region
pub fn destroySharedRegion(region: *SharedRegion) void {
    const pmm = @import("../mm/pmm.zig");

    // Unmap from all threads first (caller's responsibility to handle this)
    // Free physical memory
    pmm.freePages(region.phys_base, region.size / 4096);

    region.* = SharedRegion.init();
}
