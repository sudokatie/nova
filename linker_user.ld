/* Nova user program linker script */
/* User programs loaded at 0x400000 */

OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

USER_BASE = 0x400000;

SECTIONS
{
    . = USER_BASE;

    /* Text section - executable code */
    .text ALIGN(4K) :
    {
        *(.text .text.*)
    }

    /* Read-only data */
    .rodata ALIGN(4K) :
    {
        *(.rodata .rodata.*)
    }

    /* Initialized data */
    .data ALIGN(4K) :
    {
        *(.data .data.*)
    }

    /* Uninitialized data (zeroed) */
    .bss ALIGN(4K) :
    {
        *(.bss .bss.*)
        *(COMMON)
    }

    /* Discard unnecessary sections */
    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}
