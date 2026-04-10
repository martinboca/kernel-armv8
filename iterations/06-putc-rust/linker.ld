/*
 * linker.ld — Lección 05.
 *
 * Dos cambios respecto de L04:
 *
 *  1. Agregamos .rodata, porque rustc coloca los string literals (como
 *     el b"Martin Bocanegra\n\0" de kmain.rs) en esa sección. Sin un
 *     output section para .rodata el linker los tiraría a una zona sin
 *     ubicación definida y el programa leería basura.
 *
 *  2. El patrón de .text ahora captura también .text.* — rustc pone
 *     cada función en su propia sub-sección (.text.kmain, etc.) para
 *     permitir garbage collection de funciones no usadas. Mismo truco
 *     que ya hacíamos con .bss.* en L04.
 */

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
