// IPC Ports
//
// Named endpoints for inter-process communication.
// Allows processes to register services and clients to connect.

const console = @import("../lib/console.zig");
const Thread = @import("../proc/thread.zig").Thread;
const Process = @import("../proc/process.zig").Process;
const message = @import("message.zig");
const scheduler = @import("../proc/scheduler.zig");
const context = @import("../proc/context.zig");
const heap = @import("../mm/heap.zig");

// Maximum port name length
pub const MAX_PORT_NAME: usize = 32;

// Maximum ports
pub const MAX_PORTS: usize = 256;

// Maximum connections per port
pub const MAX_CONNECTIONS: usize = 16;

// Port rights
pub const PortRights = packed struct {
    send: bool = false,
    receive: bool = false,
    transfer: bool = false,
    _reserved: u5 = 0,
};

/// Port state
pub const PortState = enum {
    free,
    active,
    closed,
};

/// Connection to a port
pub const Connection = struct {
    client_thread: ?*Thread,
    rights: PortRights,
    active: bool,

    pub fn init() Connection {
        return .{
            .client_thread = null,
            .rights = .{},
            .active = false,
        };
    }
};

/// IPC Port
pub const Port = struct {
    id: u32,
    name: [MAX_PORT_NAME]u8,
    name_len: usize,
    state: PortState,
    owner: ?*Process,
    server_thread: ?*Thread,
    connections: [MAX_CONNECTIONS]Connection,
    connection_count: usize,

    // Message queue for pending messages
    pending_messages: [16]message.Message,
    pending_senders: [16]?*Thread,
    pending_count: usize,

    // Waiting threads
    waiting_receivers: [8]?*Thread,
    waiting_receiver_count: usize,

    pub fn init(id: u32) Port {
        return .{
            .id = id,
            .name = [_]u8{0} ** MAX_PORT_NAME,
            .name_len = 0,
            .state = .free,
            .owner = null,
            .server_thread = null,
            .connections = [_]Connection{Connection.init()} ** MAX_CONNECTIONS,
            .connection_count = 0,
            .pending_messages = undefined,
            .pending_senders = [_]?*Thread{null} ** 16,
            .pending_count = 0,
            .waiting_receivers = [_]?*Thread{null} ** 8,
            .waiting_receiver_count = 0,
        };
    }

    /// Set port name
    pub fn setName(self: *Port, name: []const u8) void {
        const len = @min(name.len, MAX_PORT_NAME - 1);
        for (0..len) |i| {
            self.name[i] = name[i];
        }
        self.name[len] = 0;
        self.name_len = len;
    }

    /// Get port name
    pub fn getName(self: *const Port) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Add a connection
    pub fn addConnection(self: *Port, client: *Thread, rights: PortRights) ?usize {
        for (&self.connections, 0..) |*conn, i| {
            if (!conn.active) {
                conn.client_thread = client;
                conn.rights = rights;
                conn.active = true;
                self.connection_count += 1;
                return i;
            }
        }
        return null;
    }

    /// Remove a connection
    pub fn removeConnection(self: *Port, client: *Thread) void {
        for (&self.connections) |*conn| {
            if (conn.active and conn.client_thread == client) {
                conn.active = false;
                conn.client_thread = null;
                self.connection_count -= 1;
                return;
            }
        }
    }

    /// Check if thread has send rights
    pub fn canSend(self: *Port, thread: *Thread) bool {
        for (self.connections) |conn| {
            if (conn.active and conn.client_thread == thread and conn.rights.send) {
                return true;
            }
        }
        return false;
    }

    /// Queue a message
    pub fn queueMessage(self: *Port, msg: *const message.Message, sender: *Thread) bool {
        if (self.pending_count >= 16) return false;

        self.pending_messages[self.pending_count] = msg.*;
        self.pending_senders[self.pending_count] = sender;
        self.pending_count += 1;
        return true;
    }

    /// Dequeue a message
    pub fn dequeueMessage(self: *Port, msg: *message.Message) ?*Thread {
        if (self.pending_count == 0) return null;

        msg.* = self.pending_messages[0];
        const sender = self.pending_senders[0];

        // Shift remaining messages
        for (0..self.pending_count - 1) |i| {
            self.pending_messages[i] = self.pending_messages[i + 1];
            self.pending_senders[i] = self.pending_senders[i + 1];
        }
        self.pending_count -= 1;

        return sender;
    }
};

// Port registry
var ports: [MAX_PORTS]Port = undefined;
var initialized: bool = false;

/// Initialize port subsystem
pub fn init() void {
    for (&ports, 0..) |*p, i| {
        p.* = Port.init(@intCast(i));
    }
    initialized = true;
    console.log(.info, "IPC port subsystem initialized", .{});
}

/// Create a new port
pub fn create(name: []const u8, owner: *Process) ?*Port {
    // Check for duplicate name
    if (findByName(name) != null) {
        console.log(.warn, "Port: Name already exists: {s}", .{name});
        return null;
    }

    // Find free slot
    for (&ports) |*p| {
        if (p.state == .free) {
            p.state = .active;
            p.owner = owner;
            p.setName(name);
            console.log(.debug, "Port: Created '{s}' (id={})", .{ name, p.id });
            return p;
        }
    }

    console.log(.err, "Port: No free ports", .{});
    return null;
}

/// Find port by name
pub fn findByName(name: []const u8) ?*Port {
    for (&ports) |*p| {
        if (p.state == .active and p.name_len == name.len) {
            var match = true;
            for (0..name.len) |i| {
                if (p.name[i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return p;
        }
    }
    return null;
}

/// Find port by ID
pub fn findById(id: u32) ?*Port {
    if (id >= MAX_PORTS) return null;
    if (ports[id].state == .active) {
        return &ports[id];
    }
    return null;
}

/// Connect to a port
pub fn connect(port: *Port, client: *Thread) ?usize {
    const rights = PortRights{ .send = true, .receive = false, .transfer = false };
    return port.addConnection(client, rights);
}

/// Send message to port (blocking)
pub fn send(port: *Port, msg: *const message.Message) i32 {
    const current = context.getCurrent() orelse return -1;

    if (!port.canSend(current)) {
        return -2; // Permission denied
    }

    // Check if server is waiting
    if (port.waiting_receiver_count > 0) {
        // Direct handoff
        port.waiting_receiver_count -= 1;
        const server = port.waiting_receivers[port.waiting_receiver_count] orelse return -1;
        port.waiting_receivers[port.waiting_receiver_count] = null;

        // Copy message and wake server
        // Server's receive buffer should be set up
        scheduler.unblock(server);
        return 0;
    }

    // Queue the message
    if (!port.queueMessage(msg, current)) {
        return -3; // Queue full
    }

    return 0;
}

/// Receive message from port (blocking)
pub fn receive(port: *Port, msg: *message.Message) ?*Thread {
    const current = context.getCurrent() orelse return null;

    // Check for pending messages
    if (port.dequeueMessage(msg)) |sender| {
        return sender;
    }

    // No messages - block
    if (port.waiting_receiver_count < 8) {
        port.waiting_receivers[port.waiting_receiver_count] = current;
        port.waiting_receiver_count += 1;

        current.state = .blocked;
        scheduler.schedule();

        // Woken up - try again
        return port.dequeueMessage(msg);
    }

    return null;
}

/// Close a port
pub fn close(port: *Port) void {
    // Wake all waiting threads
    for (port.waiting_receivers[0..port.waiting_receiver_count]) |t| {
        if (t) |thread| {
            scheduler.unblock(thread);
        }
    }

    // Wake all pending senders
    for (port.pending_senders[0..port.pending_count]) |t| {
        if (t) |thread| {
            scheduler.unblock(thread);
        }
    }

    port.state = .closed;
    console.log(.debug, "Port: Closed '{s}'", .{port.getName()});
}

/// Destroy a port
pub fn destroy(port: *Port) void {
    close(port);
    port.* = Port.init(port.id);
}

/// Get port count
pub fn getCount() usize {
    var count: usize = 0;
    for (ports) |p| {
        if (p.state == .active) count += 1;
    }
    return count;
}
