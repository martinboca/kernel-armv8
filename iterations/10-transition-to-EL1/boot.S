// boot.S — Lección 10: arranque en EL2, transición a EL1 en Rust.
//
// Contiene:
//   1. _start: setup mínimo (FP/SIMD en EL2 y EL1, SP, .bss zero,
//      salto a _start_rust que corre en EL2 y hace el eret a kmain).

.global _start
_start:
    // Habilitar FP/SIMD en EL2: limpiar CPTR_EL2.TFP (bit 10).
    mrs     x0, cptr_el2
    bic     x0, x0, #(1 << 10)
    msr     cptr_el2, x0

    // Habilitar FP/SIMD en EL1: CPACR_EL1.FPEN = 0b11 (bits 21:20).
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    // Stack pointer para _start_rust (que corre en EL2).
    ldr     x0, =stack_top
    mov     sp, x0

    // Poner .bss a cero en chunks de 8 bytes.
    ldr     x0, =bss_start
    ldr     x1, =bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b

2:
    // _start_rust configura los system registers para EL1 y ejecuta eret.
    b       _start_rust
