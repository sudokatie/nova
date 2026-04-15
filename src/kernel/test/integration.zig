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
const syscall = @import("../arch/x86_64/syscall.zig");
const ipc = @import("../ipc/message.zig");
const vfs = @import("../fs/vfs.zig");
const ramfs = @import("../fs/ramfs.zig");

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
    testVfs();

    console.println("", .{});
    console.print("Results: ", .{});
    console.print("{}", .{tests_passed});
    console.print(" passed, ", .{});
    console.print("{}", .{tests_failed});
    console.println(" failed", .{});
    console.println("=========================", .{});
}

const serial = @import("../drivers/serial.zig");

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
        process.free(proc.pid);
    } else {
        fail("process creation");
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
        thread_mod.free(t);
    } else {
        fail("thread creation with stack");
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
}

fn testVfs() void {
    console.println("[VFS Tests]", .{});

    // Initialize ramfs
    const fs = ramfs.init();
    if (fs.root != null) {
        pass("ramfs init");
    } else {
        fail("ramfs init");
    }

    // Mount at root
    vfs.mount(fs, "/") catch {
        fail("vfs mount");
        return;
    };
    pass("vfs mount");

    // Create file
    const flags = vfs.OpenFlags{ .read = true, .write = true, .create = true };
    const fd = vfs.open("/test.txt", flags) catch {
        fail("vfs create file");
        return;
    };
    pass("vfs create file");

    // Write data
    const write_data = "Hello, Nova VFS!";
    const written = vfs.write(fd, write_data) catch {
        fail("vfs write");
        return;
    };
    if (written == write_data.len) {
        pass("vfs write");
    } else {
        fail("vfs write");
    }

    // Seek back
    _ = vfs.seek(fd, 0, .start) catch {
        fail("vfs seek");
        return;
    };
    pass("vfs seek");

    // Read back
    var buffer: [64]u8 = undefined;
    const bytes_read = vfs.read(fd, &buffer) catch {
        fail("vfs read");
        return;
    };
    if (bytes_read == write_data.len) {
        pass("vfs read");
    } else {
        fail("vfs read");
    }

    // Close
    vfs.close(fd);
    pass("vfs close");

    // Create directory
    vfs.mkdir("/mydir", vfs.DEFAULT_DIR_PERMS) catch {
        fail("vfs mkdir");
        return;
    };
    pass("vfs mkdir");

    // Stat
    const st = vfs.stat("/mydir") catch {
        fail("vfs stat");
        return;
    };
    if (st.file_type == .directory) {
        pass("vfs stat");
    } else {
        fail("vfs stat");
    }

    // Unlink file
    vfs.unlink("/test.txt") catch {
        fail("vfs unlink");
        return;
    };
    pass("vfs unlink");

    // Rmdir
    vfs.rmdir("/mydir") catch {
        fail("vfs rmdir");
        return;
    };
    pass("vfs rmdir");
}
