const std = @import("std");

pub fn build(b: *std.Build) void {
    // Freestanding x86_64 target for kernel
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "nova",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });

    // Disable features that don't work in kernel mode
    kernel.root_module.red_zone = false;
    kernel.root_module.stack_check = false;
    kernel.root_module.stack_protector = .none;

    // Use custom linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Install the kernel binary
    b.installArtifact(kernel);

    // Run step - boots kernel in QEMU
    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64",
        "-cdrom",
        "nova.iso",
        "-serial",
        "stdio",
        "-no-reboot",
        "-no-shutdown",
    });
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the kernel in QEMU");
    run_step.dependOn(&run_cmd.step);

    // ISO creation step
    const iso_cmd = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        \\mkdir -p iso_root/boot/limine && \
        \\cp zig-out/bin/nova iso_root/boot/ && \
        \\cp limine.cfg iso_root/boot/limine/ && \
        \\cp /usr/local/share/limine/limine-bios.sys iso_root/boot/limine/ 2>/dev/null || true && \
        \\cp /usr/local/share/limine/limine-bios-cd.bin iso_root/boot/limine/ 2>/dev/null || true && \
        \\cp /usr/local/share/limine/limine-uefi-cd.bin iso_root/boot/limine/ 2>/dev/null || true && \
        \\xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin \
        \\    -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\    --efi-boot boot/limine/limine-uefi-cd.bin \
        \\    -efi-boot-part --efi-boot-image --protective-msdos-label \
        \\    iso_root -o nova.iso 2>/dev/null || \
        \\xorriso -as mkisofs iso_root -o nova.iso
    });
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Create bootable ISO");
    iso_step.dependOn(&iso_cmd.step);

    // Unit tests (run on host)
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
