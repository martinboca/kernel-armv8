ENTRY(_start)

SECTIONS
{
    . = 0x40000000;

    .text : {
        *(.text)
        *(.text.*)
    }

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }

    .bss : ALIGN(8) {
        bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(8);
        bss_end = .;
    }

    /* Stack del kernel. */
    . = ALIGN(16);
    . += 0x1000;
    stack_top = .;
}
