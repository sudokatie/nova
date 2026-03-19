// Limine Bootloader Protocol
//
// These structures match the Limine boot protocol specification.
// The bootloader fills in responses to our requests.

// Limine magic numbers
pub const LIMINE_COMMON_MAGIC = [4]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0, 0 };

// Base revision - verifies protocol compatibility
pub const BaseRevision = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC,
    revision: u64,

    pub fn is_supported(self: *const @This()) bool {
        return self.revision == 0;
    }
};

// Memory map entry types
pub const MemoryMapEntryKind = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

// Memory map entry
pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemoryMapEntryKind,
};

// Memory map response
pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries_ptr: [*]*MemoryMapEntry,

    pub fn entries(self: *const @This()) []*MemoryMapEntry {
        return self.entries_ptr[0..self.entry_count];
    }
};

// Memory map request
pub const MemoryMapRequest = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [2]u64{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};

// HHDM (Higher Half Direct Map) response
pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

// HHDM request
pub const HhdmRequest = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [2]u64{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

// Kernel address response
pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

// Kernel address request
pub const KernelAddressRequest = extern struct {
    id: [4]u64 = LIMINE_COMMON_MAGIC ++ [2]u64{ 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,
    response: ?*KernelAddressResponse = null,
};
