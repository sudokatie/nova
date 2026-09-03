// Device Capability System
//
// Manages capabilities that allow userspace processes to access hardware.
// Capabilities are granted by the kernel and checked on every I/O operation.

const std = @import("std");
const Process = @import("../proc/process.zig").Process;
const console = @import("../lib/console.zig");

/// I/O port range capability
pub const IoPortRange = struct {
    base: u16,
    count: u16,

    /// Return whether this describes a non-empty range within the I/O space.
    pub fn isValid(self: IoPortRange) bool {
        const end: u32 = @as(u32, self.base) + @as(u32, self.count);
        return self.count != 0 and end <= 0x1_0000;
    }

    pub fn contains(self: IoPortRange, port: u16) bool {
        if (!self.isValid()) return false;
        const end: u32 = @as(u32, self.base) + @as(u32, self.count);
        return @as(u32, port) >= self.base and @as(u32, port) < end;
    }
};

/// MMIO region capability
pub const MmioRegion = struct {
    base: u64,
    size: u64,

    /// Return whether this describes a non-empty addressable region.
    pub fn isValid(self: MmioRegion) bool {
        return self.size != 0 and self.size - 1 <= std.math.maxInt(u64) - self.base;
    }

    pub fn contains(self: MmioRegion, addr: u64) bool {
        return self.isValid() and addr >= self.base and addr - self.base < self.size;
    }
};

/// IRQ capability (single IRQ number)
pub const IrqCapability = struct {
    irq: u8,
    /// Port to send IRQ notifications to
    notify_port: u32,
};

/// Maximum capabilities per type per process
pub const MAX_IO_PORTS: usize = 16;
pub const MAX_MMIO_REGIONS: usize = 8;
pub const MAX_IRQS: usize = 16;

/// Capability set for a process
pub const CapabilitySet = struct {
    /// I/O port ranges this process can access
    io_ports: [MAX_IO_PORTS]?IoPortRange,
    io_port_count: usize,

    /// MMIO regions this process can access
    mmio_regions: [MAX_MMIO_REGIONS]?MmioRegion,
    mmio_region_count: usize,

    /// IRQs this process can receive
    irqs: [MAX_IRQS]?IrqCapability,
    irq_count: usize,

    /// Initialize empty capability set
    pub fn init() CapabilitySet {
        return .{
            .io_ports = [_]?IoPortRange{null} ** MAX_IO_PORTS,
            .io_port_count = 0,
            .mmio_regions = [_]?MmioRegion{null} ** MAX_MMIO_REGIONS,
            .mmio_region_count = 0,
            .irqs = [_]?IrqCapability{null} ** MAX_IRQS,
            .irq_count = 0,
        };
    }

    /// Check if process can access an I/O port
    pub fn canAccessPort(self: *const CapabilitySet, port: u16) bool {
        for (self.io_ports[0..self.io_port_count]) |maybe_range| {
            if (maybe_range) |range| {
                if (range.contains(port)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Check if process can access an MMIO address
    pub fn canAccessMmio(self: *const CapabilitySet, addr: u64) bool {
        for (self.mmio_regions[0..self.mmio_region_count]) |maybe_region| {
            if (maybe_region) |region| {
                if (region.contains(addr)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Check if process owns an IRQ
    pub fn ownsIrq(self: *const CapabilitySet, irq: u8) bool {
        for (self.irqs[0..self.irq_count]) |maybe_irq| {
            if (maybe_irq) |cap| {
                if (cap.irq == irq) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Get notification port for an IRQ
    pub fn getIrqPort(self: *const CapabilitySet, irq: u8) ?u32 {
        for (self.irqs[0..self.irq_count]) |maybe_irq| {
            if (maybe_irq) |cap| {
                if (cap.irq == irq) {
                    return cap.notify_port;
                }
            }
        }
        return null;
    }

    /// Grant I/O port range capability
    pub fn grantIoPorts(self: *CapabilitySet, base: u16, count: u16) !void {
        const range = IoPortRange{ .base = base, .count = count };
        if (!range.isValid()) return error.InvalidRange;
        if (self.io_port_count >= MAX_IO_PORTS) {
            return error.TooManyCapabilities;
        }
        for (self.io_ports[0..self.io_port_count]) |maybe_existing| {
            if (maybe_existing) |existing| {
                if (existing.base == base and existing.count == count) {
                    return error.DuplicateCapability;
                }
            }
        }
        self.io_ports[self.io_port_count] = range;
        self.io_port_count += 1;
        console.log(.debug, "Granted IO ports 0x{x}-0x{x}", .{ base, @as(u32, base) + count - 1 });
    }

    /// Revoke I/O port range capability
    pub fn revokeIoPorts(self: *CapabilitySet, base: u16) bool {
        for (0..self.io_port_count) |i| {
            if (self.io_ports[i]) |range| {
                if (range.base == base) {
                    // Shift remaining entries
                    var j = i;
                    while (j + 1 < self.io_port_count) : (j += 1) {
                        self.io_ports[j] = self.io_ports[j + 1];
                    }
                    self.io_ports[self.io_port_count - 1] = null;
                    self.io_port_count -= 1;
                    console.log(.debug, "Revoked IO ports from 0x{x}", .{base});
                    return true;
                }
            }
        }
        return false;
    }

    /// Grant MMIO region capability
    pub fn grantMmio(self: *CapabilitySet, base: u64, size: u64) !void {
        const region = MmioRegion{ .base = base, .size = size };
        if (!region.isValid()) return error.InvalidRange;
        if (self.mmio_region_count >= MAX_MMIO_REGIONS) {
            return error.TooManyCapabilities;
        }
        for (self.mmio_regions[0..self.mmio_region_count]) |maybe_existing| {
            if (maybe_existing) |existing| {
                if (existing.base == base and existing.size == size) {
                    return error.DuplicateCapability;
                }
            }
        }
        self.mmio_regions[self.mmio_region_count] = region;
        self.mmio_region_count += 1;
        console.log(.debug, "Granted MMIO 0x{x}-0x{x}", .{ base, base + size - 1 });
    }

    /// Revoke an MMIO region by its base address.
    pub fn revokeMmio(self: *CapabilitySet, base: u64) bool {
        for (0..self.mmio_region_count) |i| {
            if (self.mmio_regions[i]) |region| {
                if (region.base == base) {
                    var j = i;
                    while (j + 1 < self.mmio_region_count) : (j += 1) {
                        self.mmio_regions[j] = self.mmio_regions[j + 1];
                    }
                    self.mmio_regions[self.mmio_region_count - 1] = null;
                    self.mmio_region_count -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    /// Grant IRQ capability
    pub fn grantIrq(self: *CapabilitySet, irq: u8, notify_port: u32) !void {
        if (self.irq_count >= MAX_IRQS) {
            return error.TooManyCapabilities;
        }
        if (self.ownsIrq(irq)) return error.DuplicateCapability;
        self.irqs[self.irq_count] = IrqCapability{
            .irq = irq,
            .notify_port = notify_port,
        };
        self.irq_count += 1;
        console.log(.debug, "Granted IRQ {} -> port {}", .{ irq, notify_port });
    }

    /// Revoke IRQ capability
    pub fn revokeIrq(self: *CapabilitySet, irq: u8) bool {
        for (0..self.irq_count) |i| {
            if (self.irqs[i]) |cap| {
                if (cap.irq == irq) {
                    var j = i;
                    while (j + 1 < self.irq_count) : (j += 1) {
                        self.irqs[j] = self.irqs[j + 1];
                    }
                    self.irqs[self.irq_count - 1] = null;
                    self.irq_count -= 1;
                    console.log(.debug, "Revoked IRQ {}", .{irq});
                    return true;
                }
            }
        }
        return false;
    }
};

// Global capability tracking

/// IRQ ownership table - which process owns which IRQ
var irq_owners: [256]?*Process = [_]?*Process{null} ** 256;

/// Check if an IRQ is available
pub fn isIrqAvailable(irq: u8) bool {
    return irq_owners[irq] == null;
}

/// Claim an IRQ for a process
pub fn claimIrq(irq: u8, process: *Process) !void {
    if (irq_owners[irq] != null) {
        return error.IrqInUse;
    }
    irq_owners[irq] = process;
}

/// Release an IRQ
pub fn releaseIrq(irq: u8, process: *Process) void {
    if (irq_owners[irq] == process) {
        irq_owners[irq] = null;
    }
}

/// Get process owning an IRQ (for interrupt forwarding)
pub fn getIrqOwner(irq: u8) ?*Process {
    return irq_owners[irq];
}

/// Release every device capability held by a process.
/// This is idempotent so it is safe to call during both exit and final reap.
pub fn releaseAll(process: *Process) void {
    while (process.capabilities.io_port_count > 0) {
        const range = process.capabilities.io_ports[process.capabilities.io_port_count - 1].?;
        _ = process.capabilities.revokeIoPorts(range.base);
        releasePorts(range.base, process);
    }

    while (process.capabilities.mmio_region_count > 0) {
        const region = process.capabilities.mmio_regions[process.capabilities.mmio_region_count - 1].?;
        _ = process.capabilities.revokeMmio(region.base);
    }

    while (process.capabilities.irq_count > 0) {
        const irq = process.capabilities.irqs[process.capabilities.irq_count - 1].?.irq;
        _ = process.capabilities.revokeIrq(irq);
        releaseIrq(irq, process);
    }
}

// I/O port reservation tracking (optional - for exclusive access)
const PortReservation = struct {
    base: u16,
    count: u16,
    owner: *Process,
};

const MAX_PORT_RESERVATIONS: usize = 64;
var port_reservations: [MAX_PORT_RESERVATIONS]?PortReservation = [_]?PortReservation{null} ** MAX_PORT_RESERVATIONS;
var port_reservation_count: usize = 0;

/// Reserve I/O ports exclusively for a process
pub fn reservePorts(base: u16, count: u16, process: *Process) !void {
    const requested = IoPortRange{ .base = base, .count = count };
    if (!requested.isValid()) return error.InvalidRange;

    // Check for overlap with existing reservations
    for (port_reservations[0..port_reservation_count]) |maybe_res| {
        if (maybe_res) |res| {
            const res_end: u32 = @as(u32, res.base) + @as(u32, res.count);
            const req_end: u32 = @as(u32, base) + @as(u32, count);
            if (@as(u32, base) < res_end and req_end > res.base) {
                return error.PortsInUse;
            }
        }
    }

    if (port_reservation_count >= MAX_PORT_RESERVATIONS) {
        return error.TooManyReservations;
    }

    port_reservations[port_reservation_count] = PortReservation{
        .base = base,
        .count = count,
        .owner = process,
    };
    port_reservation_count += 1;
}

/// Release port reservation
pub fn releasePorts(base: u16, process: *Process) void {
    for (0..port_reservation_count) |i| {
        if (port_reservations[i]) |res| {
            if (res.base == base and res.owner == process) {
                var j = i;
                while (j + 1 < port_reservation_count) : (j += 1) {
                    port_reservations[j] = port_reservations[j + 1];
                }
                port_reservations[port_reservation_count - 1] = null;
                port_reservation_count -= 1;
                return;
            }
        }
    }
}

// Tests
test "capability set basics" {
    var caps = CapabilitySet.init();

    // Initially empty
    try std.testing.expect(!caps.canAccessPort(0x60));
    try std.testing.expect(!caps.ownsIrq(1));

    // Grant and check
    try caps.grantIoPorts(0x60, 5);
    try std.testing.expect(caps.canAccessPort(0x60));
    try std.testing.expect(caps.canAccessPort(0x64));
    try std.testing.expect(!caps.canAccessPort(0x65));
    try std.testing.expect(!caps.canAccessPort(0x5F));

    // Grant IRQ
    try caps.grantIrq(1, 100);
    try std.testing.expect(caps.ownsIrq(1));
    try std.testing.expectEqual(@as(?u32, 100), caps.getIrqPort(1));

    // Revoke
    try std.testing.expect(caps.revokeIoPorts(0x60));
    try std.testing.expect(!caps.canAccessPort(0x60));
}

test "capability limits" {
    var caps = CapabilitySet.init();

    // Fill up IO ports
    for (0..MAX_IO_PORTS) |i| {
        try caps.grantIoPorts(@intCast(i * 10), 5);
    }

    // Should fail on next
    const result = caps.grantIoPorts(1000, 5);
    try std.testing.expectError(error.TooManyCapabilities, result);
}

test "capability ranges do not wrap" {
    const io_end = IoPortRange{ .base = 0xFFFE, .count = 2 };
    try std.testing.expect(io_end.isValid());
    try std.testing.expect(io_end.contains(0xFFFE));
    try std.testing.expect(io_end.contains(0xFFFF));
    try std.testing.expect(!io_end.contains(0));

    const empty_io = IoPortRange{ .base = 0x60, .count = 0 };
    try std.testing.expect(!empty_io.isValid());
    try std.testing.expect(!empty_io.contains(0x60));

    const last_mmio = MmioRegion{ .base = std.math.maxInt(u64), .size = 1 };
    try std.testing.expect(last_mmio.isValid());
    try std.testing.expect(last_mmio.contains(std.math.maxInt(u64)));

    const overflowing_mmio = MmioRegion{ .base = std.math.maxInt(u64), .size = 2 };
    try std.testing.expect(!overflowing_mmio.isValid());
    try std.testing.expect(!overflowing_mmio.contains(std.math.maxInt(u64)));
}

test "capability grants reject invalid and duplicate entries" {
    var caps = CapabilitySet.init();

    try std.testing.expectError(error.InvalidRange, caps.grantIoPorts(0xFFFF, 2));
    try std.testing.expectError(error.InvalidRange, caps.grantIoPorts(0x60, 0));
    try caps.grantIoPorts(0x60, 5);
    try std.testing.expectError(error.DuplicateCapability, caps.grantIoPorts(0x60, 5));

    try std.testing.expectError(error.InvalidRange, caps.grantMmio(std.math.maxInt(u64), 2));
    try caps.grantMmio(0xFEE00000, 0x1000);
    try std.testing.expectError(error.DuplicateCapability, caps.grantMmio(0xFEE00000, 0x1000));
    try std.testing.expect(caps.revokeMmio(0xFEE00000));
    try std.testing.expect(!caps.revokeMmio(0xFEE00000));

    try caps.grantIrq(1, 100);
    try std.testing.expectError(error.DuplicateCapability, caps.grantIrq(1, 101));
}

test "process cleanup releases device capabilities" {
    var owner = Process.init(99, null);

    try std.testing.expectError(error.InvalidRange, reservePorts(0xFFFF, 2, &owner));
    try std.testing.expectError(error.InvalidRange, reservePorts(0x300, 0, &owner));
    try reservePorts(0x300, 2, &owner);
    try owner.capabilities.grantIoPorts(0x300, 2);
    try owner.capabilities.grantMmio(0xFEE00000, 0x1000);
    try claimIrq(42, &owner);
    try owner.capabilities.grantIrq(42, 77);

    owner.terminate(1);
    releaseAll(&owner);

    try std.testing.expectEqual(@as(usize, 0), owner.capabilities.io_port_count);
    try std.testing.expectEqual(@as(usize, 0), owner.capabilities.mmio_region_count);
    try std.testing.expectEqual(@as(usize, 0), owner.capabilities.irq_count);
    try std.testing.expect(isIrqAvailable(42));
    try std.testing.expectEqual(@as(?*Process, null), getIrqOwner(42));

    // The reservation is gone too, so another process can claim the range.
    var replacement = Process.init(100, null);
    try reservePorts(0x300, 2, &replacement);
    releasePorts(0x300, &replacement);
}
