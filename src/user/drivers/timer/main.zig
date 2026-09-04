// Userspace Timer Driver
//
// The kernel keeps the APIC timer running for scheduling and forwards a copy
// of each timer IRQ to this driver when it owns IRQ 0.  This example shows
// the userspace side of that contract:
// - creates a private IRQ notification port
// - claims IRQ 0 through the device capability syscall
// - creates the public timer service endpoint
// - consumes timer notifications over port IPC

const syscall = @import("syscall");

pub const TIMER_IRQ: u8 = 0;
pub const TIMER_HZ: u64 = 100;
pub const TICK_NS: u64 = 10_000_000;

pub const MSG_TAG_IRQ: u32 = 0x49525100; // "IRQ\0"
pub const MSG_TAG_TICK: u32 = 0x5449434B; // "TICK"

// The public endpoint is intentionally kept small for this example.  Clients
// can discover/connect to timer0 as the driver protocol grows; IRQ delivery
// itself uses the private endpoint below.
pub const SERVICE_NAME = "timer0";
const IRQ_PORT_NAME = "timer-irq";

var irq_notify_port: i32 = -1;
var service_port: i32 = -1;
var ticks: u64 = 0;

/// Set up the timer's IRQ capability and IPC endpoints.
fn init() !void {
    const irq_port = syscall.port_create(IRQ_PORT_NAME);
    if (irq_port < 0) {
        _ = syscall.debug_print("timer: failed to create IRQ port\n");
        return error.PortRequestFailed;
    }
    irq_notify_port = irq_port;

    // IRQ 0 is delivered by the kernel APIC path.  No I/O-port capability is
    // needed because the userspace driver only consumes notifications.
    if (syscall.request_irq(TIMER_IRQ, @intCast(irq_notify_port)) < 0) {
        _ = syscall.debug_print("timer: failed to request IRQ 0\n");
        _ = syscall.port_destroy(irq_notify_port);
        irq_notify_port = -1;
        return error.IrqRequestFailed;
    }

    const service = syscall.port_create(SERVICE_NAME);
    if (service < 0) {
        _ = syscall.debug_print("timer: failed to create service port\n");
        _ = syscall.release_irq(TIMER_IRQ);
        _ = syscall.port_destroy(irq_notify_port);
        irq_notify_port = -1;
        return error.PortRequestFailed;
    }
    service_port = service;

    _ = syscall.debug_print("timer: userspace timer driver initialized at 100Hz\n");
}

/// Account for one validated timer IRQ notification.
fn handleIrq(msg: *const syscall.Message) void {
    if (msg.tag != MSG_TAG_IRQ or msg.len < 1 or msg.data[0] != TIMER_IRQ) return;

    ticks += 1;

    // Keep boot/runtime output useful without printing from every interrupt.
    if (ticks == 1 or ticks % TIMER_HZ == 0) {
        _ = syscall.debug_print("timer: userspace tick\n");
    }
}

/// Wait for kernel IRQ notifications and process them in userspace.
fn driverLoop() noreturn {
    var msg: syscall.Message = undefined;

    while (true) {
        if (syscall.port_receive(irq_notify_port, &msg) == 0) {
            handleIrq(&msg);
        }
    }
}

// Driver entry point.
export fn main() void {
    _ = syscall.debug_print("timer: starting userspace timer driver\n");

    init() catch {
        _ = syscall.debug_print("timer: initialization failed\n");
        syscall.exit(1);
    };

    driverLoop();
}

// Entry point for userspace.
pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\call main
        \\mov $13, %%rax
        \\xor %%rdi, %%rdi
        \\syscall
        ::: "rax", "rdi");
}
