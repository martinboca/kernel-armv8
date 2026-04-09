/*
 * linker.ld — Lección 02.
 *
 * Además del .text de la lección 01, reservamos espacio para el stack
 * inmediatamente después del código y exportamos el símbolo stack_top
 * para que boot.S pueda cargarlo en SP.
 *
 * En ARMv8-A el stack crece hacia abajo, así que 'stack_top' es la
 * dirección más alta del área reservada: ese es el valor inicial del SP.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x40000000;
    .text : { *(.text) }

    /* Reservamos 4 KiB de stack, alineados a 16 bytes (requisito de ARMv8). */
    . = ALIGN(16);
    . += 0x1000;
    stack_top = .;
}
