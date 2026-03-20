// CPU Utilities for x86-64
//
// Low-level CPU control instructions and register access.

/// Halt the CPU
pub fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Disable interrupts
pub fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Enable interrupts
pub fn enableInterrupts() void {
    asm volatile ("sti");
}

/// Read CR0 register
pub fn readCR0() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr0, %[result]"
        : [result] "=r" (result),
    );
    return result;
}

/// Write CR0 register
pub fn writeCR0(value: u64) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (value),
    );
}

/// Read CR2 register (page fault address)
pub fn readCR2() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (result),
    );
    return result;
}

/// Read CR3 register (page table base)
pub fn readCR3() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (result),
    );
    return result;
}

/// Write CR3 register (switches address space)
pub fn writeCR3(value: u64) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
    );
}

/// Read CR4 register
pub fn readCR4() u64 {
    var result: u64 = undefined;
    asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (result),
    );
    return result;
}

/// Write CR4 register
pub fn writeCR4(value: u64) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value),
    );
}

/// Output byte to I/O port
pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

/// Input byte from I/O port
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Output word to I/O port
pub fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

/// Input word from I/O port
pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

/// Output double word to I/O port
pub fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

/// Input double word from I/O port
pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

/// I/O wait (small delay for I/O devices)
pub fn io_wait() void {
    outb(0x80, 0);
}

/// Load GDT - takes pointer to GDTR
/// Note: Due to Zig 0.15 inline asm limitations, caller must ensure pointer is valid
pub fn loadGDT(gdtr: *const GDTPointer) void {
    asm volatile ("lgdt %[gdtr]"
        :
        : [gdtr] "m" (gdtr.*),
    );
}

/// Load IDT - takes pointer to IDTR
pub fn loadIDT(idtr: *const IDTPointer) void {
    asm volatile ("lidt %[idtr]"
        :
        : [idtr] "m" (idtr.*),
    );
}

/// Load Task Register
pub fn loadTR(selector: u16) void {
    asm volatile ("ltr %[selector]"
        :
        : [selector] "r" (selector),
    );
}

/// Read MSR (Model Specific Register)
pub fn readMSR(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write MSR (Model Specific Register)
pub fn writeMSR(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Invalidate TLB entry for address
pub fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%%rax)"
        :
        : [addr] "{rax}" (addr),
    );
}

/// GDT Pointer structure
pub const GDTPointer = packed struct {
    limit: u16,
    base: u64,
};

/// IDT Pointer structure
pub const IDTPointer = packed struct {
    limit: u16,
    base: u64,
};

/// IdtPtr for boot.zig reboot
pub const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

/// CPUID result
pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Execute CPUID instruction
pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Write CR0 register
pub fn writeCr0(value: u64) void {
    writeCR0(value);
}

/// Read CR0 register
pub fn readCr0() u64 {
    return readCR0();
}
