// boot.S — Lección 07: puts pasa a Rust.
//
// Este archivo ahora contiene:
//   1. _start: startup code (SP, seteo a cero de .bss, salto a kmain).

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
    
    // Iniciar el kernel en Rust
2:
    b       kmain
