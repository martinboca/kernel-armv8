// boot.S — Lección 06: putc pasa a Rust.
//
// Este archivo ahora contiene:
//   1. _start: startup code (SP, seteo a cero de .bss, salto a kmain).
//   2. puts: helper que itera bytes de un string y llama a putc por
//      cada uno. Sigue en asm por una lección más; en L07 también
//      pasa a Rust.
//
// putc desapareció de este archivo: ahora vive en kmain.rs. La línea
// `bl putc` de puts queda igual, pero el símbolo `putc` que el linker
// resuelve ya no es local — viene de kmain.o. Como `putc` no está
// definido en este archivo, el assembler lo trata automáticamente
// como símbolo externo y deja la relocación pendiente para el linker.
// No hace falta declararlo explícitamente.

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
