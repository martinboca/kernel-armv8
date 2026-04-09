/*
 * linker.ld — Coloca el código en 0x40000000 (inicio de RAM de QEMU virt)
 * y marca _start como entry point.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x40000000;
    .text : { *(.text) }
}
