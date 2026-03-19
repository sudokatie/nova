/* Nova kernel linker script */
/* Higher-half kernel at 0xFFFFFFFF80000000 */

OUTPUT_FORMAT(elf64-x86-64)
ENTRY(kmain)

KERNEL_PHYS = 0x100000;
KERNEL_VIRT = 0xFFFFFFFF80000000;

SECTIONS
{
    . = KERNEL_VIRT;

    /* Limine requests section */
    .limine_reqs ALIGN(4K) : AT(ADDR(.limine_reqs) - KERNEL_VIRT + KERNEL_PHYS)
    {
        KEEP(*(.limine_reqs))
    }

    /* Text section - executable code */
    .text ALIGN(4K) : AT(ADDR(.text) - KERNEL_VIRT + KERNEL_PHYS)
    {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    }

    /* Read-only data */
    .rodata ALIGN(4K) : AT(ADDR(.rodata) - KERNEL_VIRT + KERNEL_PHYS)
    {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    }

    /* Initialized data */
    .data ALIGN(4K) : AT(ADDR(.data) - KERNEL_VIRT + KERNEL_PHYS)
    {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    }

    /* Uninitialized data (zeroed) */
    .bss ALIGN(4K) : AT(ADDR(.bss) - KERNEL_VIRT + KERNEL_PHYS)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    /* Kernel end marker */
    . = ALIGN(4K);
    __kernel_end = .;
    __kernel_size = __kernel_end - KERNEL_VIRT;

    /* Discard unnecessary sections */
    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}
