/*
 * linker.ld — Lección 04.
 *
 * Agregamos la sección .bss con símbolos bss_start y bss_end para que
 * _start pueda ponerla a cero en el arranque. Hoy la sección va a
 * quedar vacía (ningún archivo .o tiene contenido para .bss todavía),
 * pero la infraestructura queda montada para cuando aparezca código
 * que la use.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x40000000;
    .text : { *(.text) }

    /*
     * .bss: datos no inicializados en el archivo, que deben valer cero
     * cuando el programa arranca. No ocupan lugar en el ELF (no hay
     * nada que cargar), solo reservan espacio en memoria. Los alineamos
     * a 8 bytes en ambos extremos para que el loop que los pone a cero
     * pueda usar stores de u64 sin preocuparse por los bordes.
     */
    .bss : ALIGN(8) {
        bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(8);
        bss_end = .;
    }

    /* Stack del kernel (igual que en L02). */
    . = ALIGN(16);
    . += 0x1000;
    stack_top = .;
}
