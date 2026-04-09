// boot.S — Lección 05: kmain pasa a Rust.
//
// Este archivo queda solo con dos cosas:
//   1. _start: el startup code (SP, seteo a cero de .bss, salto a kmain).
//   2. puts/putc: helpers de I/O que kmain (ahora en Rust) sigue usando
//      por un rato más, hasta que los reimplementemos en Rust en L06.
//
// El símbolo kmain ahora lo provee kmain.rs. Desde el punto de vista
// de _start no cambia nada: sigue haciendo `b kmain`, y el linker
// resuelve el símbolo contra el .o de Rust en vez del de asm.
//
// puts gana `.global` porque ahora lo llama código Rust desde otro .o;
// sin `.global` el símbolo es local al archivo y el linker no lo
// encontraría desde kmain.o. putc se queda local porque solo lo usa puts.

.equ UART0_DR, 0x09000000

// ---- Startup code ----
.global _start
_start:
    // 1. Stack pointer
    ldr     x0, =stack_top
    mov     sp, x0

    // 2. Poner .bss a cero en chunks de 8 bytes.
    ldr     x0, =bss_start
    ldr     x1, =bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:

    // 3. Transferir el control al kernel (ahora en Rust).
    b       kmain

// ---- puts(x0 = puntero a string '\0'-terminada) ----
.global puts
puts:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0
1:  ldrb    w0, [x19], #1
    cbz     w0, 2f
    bl      putc
    b       1b
2:  ldp     x19, x30, [sp], #16
    ret

// ---- putc(w0 = byte a transmitir) ----
putc:
    ldr     x1, =UART0_DR
    strb    w0, [x1]
    ret
