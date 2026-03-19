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
    return asm volatile ("mov %%cr0, %[result]"
        : [result] "=r" (-> u64),
    );
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
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Read CR3 register (page table base)
pub fn readCR3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
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
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (-> u64),
    );
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

/// Load GDT
pub fn loadGDT(gdtr: *const GDTPointer) void {
    asm volatile ("lgdt %[gdtr]"
        :
        : [gdtr] "*m" (gdtr),
    );
}

/// Load IDT
pub fn loadIDT(idtr: *const IDTPointer) void {
    asm volatile ("lidt %[idtr]"
        :
        : [idtr] "*m" (idtr),
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
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
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
