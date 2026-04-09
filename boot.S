// boot.S — Imprime "Martin Bocanegra\n" por el UART PL011 de QEMU virt.
//
// El UART vive en MMIO en 0x09000000 (dato de la máquina 'virt' de QEMU).
// Escribir un byte a esa dirección lo transmite por la consola serial.

.equ UART0_DR, 0x09000000   // Data Register del UART

.global _start
_start:
    ldr     x0, =UART0_DR   // x0 = dirección del registro de datos
    adr     x1, msg         // x1 = puntero al mensaje (PC-relativo)

1:  ldrb    w2, [x1], #1    // w2 = *x1++ (carga byte, post-incrementa)
    cbz     w2, 2f          // si es '\0', saltar al halt
    strb    w2, [x0]        // transmitir el byte
    b       1b

2:  wfe                     // halt: dormir esperando un evento
    b       2b              // (que nunca llega → loop infinito)

msg: .asciz "Martin Bocanegra\n"
