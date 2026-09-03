// IPC Ports
//
// Named endpoints for inter-process communication.
// Allows processes to register services and clients to connect.

const console = @import("../lib/console.zig");
const std = @import("std");
const Thread = @import("../proc/thread.zig").Thread;
const Process = @import("../proc/process.zig").Process;
const message = @import("message.zig");
const scheduler = @import("../proc/scheduler.zig");
const context = @import("../proc/context.zig");

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

/// Result of receiving a message from a port.
///
/// The sender is optional because kernel-originated notifications do not have
/// a userspace thread as their sender.
pub const ReceiveResult = struct {
    delivered: bool,
    sender: ?*Thread,
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
                if (self.server_thread == client) {
                    self.server_thread = null;
                }
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

    /// Check if a thread has receive rights for this port.
    pub fn canReceive(self: *const Port, thread: *Thread) bool {
        for (self.connections) |conn| {
            if (conn.active and conn.client_thread == thread and conn.rights.receive) {
                return true;
            }
        }
        return false;
    }

    /// Queue a message
    pub fn queueMessage(self: *Port, msg: *const message.Message, sender: *Thread) bool {
        if (!msg.isValid() or self.pending_count >= self.pending_messages.len) return false;

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
        self.pending_senders[self.pending_count] = null;

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

/// Return whether a name can be registered as a port name.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len >= MAX_PORT_NAME) return false;

    for (name) |byte| {
        if (byte == 0) return false;
    }

    return true;
}

/// Create a new port
pub fn create(name: []const u8, owner: *Process, server: *Thread) ?*Port {
    if (!initialized or !isValidName(name) or server.process != owner) return null;

    // Check for duplicate name
    if (findByName(name) != null) {
        console.log(.warn, "Port: Name already exists: {s}", .{name});
        return null;
    }

    // Find free slot
    for (&ports) |*p| {
        if (p.state == .free) {
            const id = p.id;
            p.* = Port.init(id);
            p.state = .active;
            p.owner = owner;
            p.server_thread = server;
            p.setName(name);

            const server_rights = PortRights{ .send = false, .receive = true, .transfer = false };
            if (p.addConnection(server, server_rights) == null) {
                p.* = Port.init(id);
                return null;
            }

            console.log(.debug, "Port: Created '{s}' (id={})", .{ name, p.id });
            return p;
        }
    }

    console.log(.err, "Port: No free ports", .{});
    return null;
}

/// Find port by name
pub fn findByName(name: []const u8) ?*Port {
    if (!initialized or !isValidName(name)) return null;

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
    if (!initialized or id >= MAX_PORTS) return null;
    if (ports[id].state == .active) {
        return &ports[id];
    }
    return null;
}

/// Connect to a port
pub fn connect(port: *Port, client: *Thread) ?usize {
    if (port.state != .active or port.server_thread == client) return null;

    for (port.connections, 0..) |conn, i| {
        if (conn.active and conn.client_thread == client) return i;
    }

    const rights = PortRights{ .send = true, .receive = false, .transfer = false };
    return port.addConnection(client, rights);
}

/// Send message to port (blocking)
pub fn send(port: *Port, msg: *const message.Message) i32 {
    const current = context.getCurrent() orelse return -1;

    if (port.state != .active or !msg.isValid()) return -1;

    if (!port.canSend(current)) {
        return -2; // Permission denied
    }

    // Check if server is waiting
    if (port.waiting_receiver_count > 0) {
        // Queue before waking the receiver so the message cannot be lost
        // between the direct handoff and the receiver's retry.
        if (!port.queueMessage(msg, current)) return -3;

        while (port.waiting_receiver_count > 0) {
            port.waiting_receiver_count -= 1;
            const server = port.waiting_receivers[port.waiting_receiver_count];
            port.waiting_receivers[port.waiting_receiver_count] = null;
            if (server) |receiver| {
                scheduler.unblock(receiver);
                break;
            }
        }
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
    const result = receiveResult(port, msg);
    return result.sender;
}

/// Receive a message from a port, retaining whether a message was delivered.
///
/// This separate status is needed for IRQ notifications, whose sender is not
/// a thread and is therefore represented by null.
pub fn receiveResult(port: *Port, msg: *message.Message) ReceiveResult {
    const current = context.getCurrent() orelse return .{ .delivered = false, .sender = null };

    if (port.state != .active or !port.canReceive(current)) {
        return .{ .delivered = false, .sender = null };
    }

    // Check for pending messages
    if (port.pending_count > 0) {
        const sender = port.dequeueMessage(msg);
        return .{ .delivered = true, .sender = sender };
    }

    // No messages - block
    if (port.waiting_receiver_count < 8) {
        port.waiting_receivers[port.waiting_receiver_count] = current;
        port.waiting_receiver_count += 1;

        current.state = .blocked;
        scheduler.schedule();

        // Woken up - try again
        if (port.state == .active and port.pending_count > 0) {
            const sender = port.dequeueMessage(msg);
            return .{ .delivered = true, .sender = sender };
        }
    }

    return .{ .delivered = false, .sender = null };
}

/// Close a port
pub fn close(port: *Port) void {
    if (port.state == .free) return;

    port.state = .closed;

    // Wake all waiting threads
    for (port.waiting_receivers[0..port.waiting_receiver_count]) |t| {
        if (t) |thread| {
            scheduler.unblock(thread);
        }
    }
    for (&port.waiting_receivers) |*waiting| waiting.* = null;
    port.waiting_receiver_count = 0;

    // Wake all pending senders
    for (port.pending_senders[0..port.pending_count]) |t| {
        if (t) |thread| {
            scheduler.unblock(thread);
        }
    }
    for (&port.pending_senders) |*sender| sender.* = null;
    port.pending_count = 0;

    console.log(.debug, "Port: Closed '{s}'", .{port.getName()});
}

/// Destroy a port
pub fn destroy(port: *Port) void {
    const id = port.id;
    close(port);
    port.* = Port.init(id);
}

/// Destroy all ports owned by a process.
pub fn destroyOwnedBy(owner: *Process) void {
    if (!initialized) return;

    for (&ports) |*p| {
        if (p.state == .active and p.owner == owner) {
            destroy(p);
        }
    }
}

/// Remove all connections held by threads in a process.
pub fn disconnectProcess(owner: *Process) void {
    if (!initialized) return;

    for (&ports) |*p| {
        if (p.state != .active) continue;

        for (&p.connections) |*conn| {
            if (conn.active) {
                if (conn.client_thread) |client| {
                    if (client.process == owner) {
                        if (p.server_thread == client) p.server_thread = null;
                        conn.* = Connection.init();
                        p.connection_count -= 1;
                    }
                }
            }
        }
    }
}

/// Remove a thread's connections from every active port.
pub fn disconnectThread(thread: *Thread) void {
    if (!initialized) return;

    for (&ports) |*p| {
        if (p.state == .active) p.removeConnection(thread);
    }
}

/// Get port count
pub fn getCount() usize {
    if (!initialized) return 0;

    var count: usize = 0;
    for (ports) |p| {
        if (p.state == .active) count += 1;
    }
    return count;
}

test "named port creation and connection" {
    init();

    var owner = Process.init(100, null);
    var server = Thread.init(100, &owner);
    var client_process = Process.init(101, null);
    var client = Thread.init(101, &client_process);
    var outsider_process = Process.init(102, null);
    var outsider = Thread.init(102, &outsider_process);

    const endpoint = create("test-port", &owner, &server) orelse return error.PortCreationFailed;
    defer destroy(endpoint);

    try std.testing.expectEqualStrings("test-port", endpoint.getName());
    try std.testing.expect(endpoint.canReceive(&server));
    try std.testing.expect(!endpoint.canSend(&server));

    const connection = connect(endpoint, &client) orelse return error.ConnectionFailed;
    try std.testing.expectEqual(@as(usize, 1), connection);
    try std.testing.expectEqual(@as(usize, 2), endpoint.connection_count);
    try std.testing.expect(endpoint.canSend(&client));
    try std.testing.expect(!endpoint.canReceive(&client));

    const duplicate = connect(endpoint, &client) orelse return error.ConnectionFailed;
    try std.testing.expectEqual(connection, duplicate);
    try std.testing.expectEqual(@as(usize, 2), endpoint.connection_count);

    context.setCurrent(&outsider);
    defer context.setCurrent(null);
    const denied = message.Message.init(1);
    try std.testing.expectEqual(@as(i32, -2), send(endpoint, &denied));
}

test "port IPC delivers client and IRQ messages" {
    init();

    var owner = Process.init(110, null);
    var server = Thread.init(110, &owner);
    var client_process = Process.init(111, null);
    var client = Thread.init(111, &client_process);

    const endpoint = create("driver-port", &owner, &server) orelse return error.PortCreationFailed;
    defer {
        context.setCurrent(null);
        destroy(endpoint);
    }
    _ = connect(endpoint, &client) orelse return error.ConnectionFailed;

    var request = message.Message.init(0x100);
    request.setData("driver request");
    context.setCurrent(&client);
    try std.testing.expectEqual(@as(i32, 0), send(endpoint, &request));

    var received = message.Message.init(0);
    context.setCurrent(&server);
    const request_result = receiveResult(endpoint, &received);
    try std.testing.expect(request_result.delivered);
    try std.testing.expectEqual(@as(?*Thread, &client), request_result.sender);
    try std.testing.expectEqual(request.tag, received.tag);
    try std.testing.expectEqualStrings(request.getData(), received.getData());

    var irq = message.Message.init(0x49525100);
    irq.setData(&[_]u8{1});
    try std.testing.expect(message.sendToPort(endpoint.id, &irq));

    const irq_result = receiveResult(endpoint, &received);
    try std.testing.expect(irq_result.delivered);
    try std.testing.expect(irq_result.sender == null);
    try std.testing.expectEqual(irq.tag, received.tag);
    try std.testing.expectEqualStrings(irq.getData(), received.getData());
}

test "owned ports are destroyed with their process" {
    init();

    var owner = Process.init(120, null);
    var server = Thread.init(120, &owner);
    const endpoint = create("owned-port", &owner, &server) orelse return error.PortCreationFailed;
    try std.testing.expectEqual(@as(usize, 1), getCount());

    destroyOwnedBy(&owner);
    try std.testing.expectEqual(@as(usize, 0), getCount());
    try std.testing.expect(findById(endpoint.id) == null);
}
