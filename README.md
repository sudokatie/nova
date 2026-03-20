# Nova

Microkernel operating system from scratch. Written in Zig.

## Why?

Because sometimes you want to understand what's actually happening between your code and the metal. Because existing tutorials either hand-wave the hard parts or drown you in x86 manual quotes. Because writing an OS is one of those things that seems impossible until you do it.

Nova is a learning project. It's not trying to replace Linux. It's trying to demystify the magic.

## What It Does

- Boots on real x86-64 hardware (and QEMU)
- Higher-half kernel with proper virtual memory
- Preemptive multitasking scheduler
- L4-style synchronous IPC
- Runs userspace programs
- That's it. That's the whole kernel.

Everything else (filesystems, networking, drivers) runs in userspace servers. Microkernel philosophy: the kernel should be as small as possible while still being useful.

## Building

Requires:
- Zig 0.13+
- QEMU (for testing)
- xorriso (for ISO creation)

```bash
# Build kernel
zig build

# Run in QEMU
zig build run

# Create bootable ISO
zig build iso
```

## Project Structure

```
nova/
  src/
    kernel/
      main.zig          # Entry point
      arch/x86_64/      # CPU-specific code
      mm/               # Memory management
      proc/             # Process and scheduler
      ipc/              # Message passing
      drivers/          # Hardware drivers
    user/
      libnova/          # Userspace runtime
      init/             # First userspace process
      shell/            # Simple shell
```

## Status

v0.1.0 complete. All core subsystems implemented:
- [x] Limine boot protocol
- [x] Serial console and panic handler
- [x] Physical memory manager (bitmap allocator)
- [x] Virtual memory manager (4-level paging)
- [x] Kernel heap (slab allocator)
- [x] APIC timer
- [x] Process and thread management
- [x] Priority scheduler with preemption
- [x] System calls (exit, print, getpid, mmap, etc.)
- [x] IPC message passing
- [x] ELF64 loader
- [x] Userspace runtime (libnova)
- [x] Init process and shell

## Philosophy

1. Simplicity over features. Every line should be understandable.
2. Correctness over performance. Get it right first.
3. Real hardware matters. QEMU is for iteration speed, not validation.
4. Code is documentation. Comments explain why, not what.

## Resources

- [OSDev Wiki](https://wiki.osdev.org/) - The encyclopedia of OS development
- [Limine Protocol](https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md) - Boot protocol docs
- [Intel SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html) - The x86 bible

## License

MIT

---

*Building an OS is surprisingly achievable. The hard part is knowing what to build.*
