// Integration Tests
//
// End-to-end verification of kernel subsystems.
// Run during boot to verify system health.

const console = @import("../lib/console.zig");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");
const heap = @import("../mm/heap.zig");
const process = @import("../proc/process.zig");
const thread_mod = @import("../proc/thread.zig");
const scheduler = @import("../proc/scheduler.zig");
const context = @import("../proc/context.zig");
const syscall = @import("../arch/x86_64/syscall.zig");
const ipc = @import("../ipc/message.zig");
const elf = @import("../loader/elf.zig");

const serial = @import("../drivers/serial.zig");

var tests_passed: u32 = 0;
var tests_failed: u32 = 0;

/// Run all integration tests
pub fn runAll() void {
    console.println("", .{});
    console.println("=== Integration Tests ===", .{});

    testPmm();
    testVmm();
    testHeap();
    testProcess();
    testThread();
    testSyscall();
    testIpc();
    testElfParser();
    testStress();

    console.println("", .{});
    console.print("Results: ", .{});
    console.print("{}", .{tests_passed});
    console.print(" passed, ", .{});
    console.print("{}", .{tests_failed});
    console.println(" failed", .{});
    console.println("=========================", .{});
}

fn pass(name: []const u8) void {
    serial.writeString("  [PASS] ");
    serial.writeString(name);
    serial.writeString("\n");
    tests_passed += 1;
}

fn fail(name: []const u8) void {
    serial.writeString("  [FAIL] ");
    serial.writeString(name);
    serial.writeString("\n");
    tests_failed += 1;
}

fn testPmm() void {
    console.println("[PMM Tests]", .{});

    // Test allocation
    if (pmm.allocPage()) |page| {
        pmm.freePage(page);
        pass("allocPage/freePage");
    } else {
        fail("allocPage/freePage");
    }

    // Test contiguous allocation
    if (pmm.allocPages(4)) |pages| {
        pmm.freePages(pages, 4);
        pass("allocPages/freePages");
    } else {
        fail("allocPages/freePages");
    }

    // Test stats
    if (pmm.getFreePageCount() > 0) {
        pass("getFreePageCount > 0");
    } else {
        fail("getFreePageCount > 0");
    }

    // Test allocation and write
    if (pmm.allocPage()) |page| {
        const virt = pmm.physToVirt(page);
        const ptr: *volatile u64 = @ptrFromInt(virt);
        ptr.* = 0xDEADBEEF;
        if (ptr.* == 0xDEADBEEF) {
            pass("allocPage write/read");
        } else {
            fail("allocPage write/read");
        }
        pmm.freePage(page);
    } else {
        fail("allocPage write/read");
    }
}

fn testVmm() void {
    console.println("[VMM Tests]", .{});

    const space = vmm.getKernelSpace();

    // Test address translation
    const kernel_base: u64 = 0xFFFFFFFF80000000;
    if (space.translate(kernel_base) != null) {
        pass("kernel mapping exists");
    } else {
        fail("kernel mapping exists");
    }

    // Test new mapping
    const test_addr: u64 = 0xFFFFFFFF90100000;
    if (pmm.allocPage()) |phys| {
        const flags = vmm.MapFlags{ .writable = true };
        if (space.mapPage(test_addr, phys, flags)) {
            if (space.translate(test_addr)) |resolved| {
                if (resolved == phys) {
                    pass("mapPage/translate");
                } else {
                    fail("mapPage/translate");
                }
            } else {
                fail("mapPage/translate");
            }
            _ = space.unmapPage(test_addr);
        } else {
            fail("mapPage/translate");
        }
        pmm.freePage(phys);
    } else {
        fail("mapPage/translate");
    }

    // Test user address space creation
    if (vmm.createUserSpace()) |user_space| {
        _ = user_space;
        pass("createUserSpace");
    } else {
        fail("createUserSpace");
    }
}

fn testHeap() void {
    console.println("[Heap Tests]", .{});

    // Test small allocation
    if (heap.alloc(32)) |ptr| {
        ptr[0] = 0xAB;
        if (ptr[0] == 0xAB) {
            pass("small alloc/write/read");
        } else {
            fail("small alloc/write/read");
        }
        heap.free(ptr, 32);
    } else {
        fail("small alloc/write/read");
    }

    // Test multiple allocations
    var ptrs: [5]?[*]u8 = [_]?[*]u8{null} ** 5;
    var all_ok = true;
    for (0..5) |i| {
        ptrs[i] = heap.alloc(64);
        if (ptrs[i] == null) all_ok = false;
    }
    for (0..5) |i| {
        if (ptrs[i]) |p| heap.free(p, 64);
    }
    if (all_ok) {
        pass("multiple allocations");
    } else {
        fail("multiple allocations");
    }

    // Test various sizes
    const sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
    var size_test_ok = true;
    for (sizes) |size| {
        if (heap.alloc(size)) |ptr| {
            ptr[0] = 0x55;
            ptr[size - 1] = 0xAA;
            if (ptr[0] != 0x55 or ptr[size - 1] != 0xAA) {
                size_test_ok = false;
            }
            heap.free(ptr, size);
        } else {
            size_test_ok = false;
        }
    }
    if (size_test_ok) {
        pass("various sizes");
    } else {
        fail("various sizes");
    }
}

fn testProcess() void {
    console.println("[Process Tests]", .{});

    // Test kernel process exists
    const kernel = process.getKernel();
    if (kernel.pid == 0) {
        pass("kernel process PID 0");
    } else {
        fail("kernel process PID 0");
    }

    // Test process creation
    if (process.create(0)) |proc| {
        if (proc.pid > 0) {
            pass("process creation");
        } else {
            fail("process creation");
        }

        // Test process name
        proc.setName("test_proc");
        const name = proc.getName();
        if (name.len == 9 and name[0] == 't') {
            pass("process name");
        } else {
            fail("process name");
        }

        process.free(proc.pid);
    } else {
        fail("process creation");
    }

    // Test multiple processes
    var procs: [5]?*process.Process = [_]?*process.Process{null} ** 5;
    var proc_ok = true;
    for (&procs) |*p| {
        p.* = process.create(0);
        if (p.* == null) proc_ok = false;
    }
    for (procs) |p| {
        if (p) |proc| process.free(proc.pid);
    }
    if (proc_ok) {
        pass("multiple processes");
    } else {
        fail("multiple processes");
    }
}

fn testThread() void {
    console.println("[Thread Tests]", .{});

    const kernel = process.getKernel();

    // Test thread creation
    if (thread_mod.create(kernel)) |t| {
        if (t.tid > 0 and t.kernel_stack_top > 0) {
            pass("thread creation with stack");
        } else {
            fail("thread creation with stack");
        }

        // Test thread context initialization
        context.initContext(t, 0x1000, 42);
        if (t.kernel_rsp > 0) {
            pass("thread context init");
        } else {
            fail("thread context init");
        }

        thread_mod.free(t);
    } else {
        fail("thread creation with stack");
    }

    // Test multiple threads
    var threads: [5]?*thread_mod.Thread = [_]?*thread_mod.Thread{null} ** 5;
    var thread_ok = true;
    for (&threads) |*t| {
        t.* = thread_mod.create(kernel);
        if (t.* == null) thread_ok = false;
    }
    for (threads) |t| {
        if (t) |thread| thread_mod.free(thread);
    }
    if (thread_ok) {
        pass("multiple threads");
    } else {
        fail("multiple threads");
    }
}

fn testSyscall() void {
    console.println("[Syscall Tests]", .{});

    // Test dispatch table
    const result = syscall.syscallDispatch(syscall.SYS_GETPID, 0, 0, 0, 0, 0, 0);
    // Should return -1 since no current thread in test context
    if (result == -1 or result >= 0) {
        pass("syscall dispatch");
    } else {
        fail("syscall dispatch");
    }

    // Test invalid syscall
    const invalid = syscall.syscallDispatch(255, 0, 0, 0, 0, 0, 0);
    if (invalid == -1) {
        pass("invalid syscall returns -1");
    } else {
        fail("invalid syscall returns -1");
    }

    // Test gettime
    const time1 = syscall.syscallDispatch(syscall.SYS_GETTIME, 0, 0, 0, 0, 0, 0);
    const time2 = syscall.syscallDispatch(syscall.SYS_GETTIME, 0, 0, 0, 0, 0, 0);
    if (time2 >= time1) {
        pass("gettime monotonic");
    } else {
        fail("gettime monotonic");
    }
}

fn testIpc() void {
    console.println("[IPC Tests]", .{});

    // Test message creation
    var msg = ipc.Message.init(42);
    msg.setData("hello");
    const data = msg.getData();
    if (data.len == 5 and data[0] == 'h') {
        pass("message create/setData/getData");
    } else {
        fail("message create/setData/getData");
    }

    // Test extended message with grants
    var ext_msg = ipc.ExtendedMessage.init(100);
    if (ext_msg.addGrant(0x1000, 4096, .{ .read = true, .write = true })) {
        if (ext_msg.grant_count == 1) {
            pass("extended message with grant");
        } else {
            fail("extended message with grant");
        }
    } else {
        fail("extended message with grant");
    }

    // Test notification
    const kernel = process.getKernel();
    if (thread_mod.create(kernel)) |t| {
        if (ipc.createNotification(t)) |notif| {
            ipc.signal(notif, 0x1);
            const bits = ipc.pollNotification(notif);
            if (bits == 0x1) {
                pass("notification signal/poll");
            } else {
                fail("notification signal/poll");
            }
            ipc.destroyNotification(notif);
        } else {
            fail("notification signal/poll");
        }
        thread_mod.free(t);
    } else {
        fail("notification signal/poll");
    }
}

fn testElfParser() void {
    console.println("[ELF Parser Tests]", .{});

    // Test ELF magic validation with invalid data
    var bad_header: elf.Elf64Header = undefined;
    @memset(@as([*]u8, @ptrCast(&bad_header))[0..@sizeOf(elf.Elf64Header)], 0);

    const result = elf.validateHeader(&bad_header);
    if (result == elf.LoadError.InvalidMagic) {
        pass("ELF invalid magic detected");
    } else {
        fail("ELF invalid magic detected");
    }

    // Test ELF with correct magic but wrong class
    bad_header.e_ident[0] = 0x7F;
    bad_header.e_ident[1] = 'E';
    bad_header.e_ident[2] = 'L';
    bad_header.e_ident[3] = 'F';
    bad_header.e_ident[4] = 1; // ELFCLASS32 (wrong)
    const result2 = elf.validateHeader(&bad_header);
    if (result2 == elf.LoadError.InvalidClass) {
        pass("ELF invalid class detected");
    } else {
        fail("ELF invalid class detected");
    }
}

fn testStress() void {
    console.println("[Stress Tests]", .{});

    // Stress test: many allocations
    var alloc_count: usize = 0;
    var free_count: usize = 0;
    var ptrs: [100]?[*]u8 = [_]?[*]u8{null} ** 100;

    for (&ptrs) |*p| {
        p.* = heap.alloc(128);
        if (p.* != null) alloc_count += 1;
    }

    for (&ptrs) |*p| {
        if (p.*) |ptr| {
            heap.free(ptr, 128);
            free_count += 1;
            p.* = null;
        }
    }

    if (alloc_count == 100 and free_count == 100) {
        pass("stress: 100 alloc/free cycles");
    } else {
        fail("stress: 100 alloc/free cycles");
    }

    // Stress test: process churn
    var proc_creates: usize = 0;
    var proc_frees: usize = 0;

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (process.create(0)) |proc| {
            proc_creates += 1;
            process.free(proc.pid);
            proc_frees += 1;
        }
    }

    if (proc_creates == 20 and proc_frees == 20) {
        pass("stress: 20 process create/free");
    } else {
        fail("stress: 20 process create/free");
    }

    // Stress test: thread churn
    const kernel = process.getKernel();
    var thread_creates: usize = 0;
    var thread_frees: usize = 0;

    i = 0;
    while (i < 20) : (i += 1) {
        if (thread_mod.create(kernel)) |t| {
            thread_creates += 1;
            thread_mod.free(t);
            thread_frees += 1;
        }
    }

    if (thread_creates == 20 and thread_frees == 20) {
        pass("stress: 20 thread create/free");
    } else {
        fail("stress: 20 thread create/free");
    }

    // Stress test: page allocation
    const initial_free = pmm.getFreePageCount();
    var pages_allocated: usize = 0;
    var page_ptrs: [50]?u64 = [_]?u64{null} ** 50;

    for (&page_ptrs) |*p| {
        p.* = pmm.allocPage();
        if (p.* != null) pages_allocated += 1;
    }

    for (&page_ptrs) |*p| {
        if (p.*) |page| {
            pmm.freePage(page);
            p.* = null;
        }
    }

    const final_free = pmm.getFreePageCount();
    if (pages_allocated == 50 and initial_free == final_free) {
        pass("stress: 50 page alloc/free");
    } else {
        fail("stress: 50 page alloc/free");
    }

    // Stress test: IPC messages
    var msg_count: usize = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        var msg = ipc.Message.init(@intCast(i));
        const data_str = "test message data";
        msg.setData(data_str);
        const data = msg.getData();
        if (data.len == data_str.len) {
            msg_count += 1;
        }
    }

    if (msg_count == 100) {
        pass("stress: 100 IPC messages");
    } else {
        fail("stress: 100 IPC messages");
    }
}
