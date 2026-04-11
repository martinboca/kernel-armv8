// boot.S — Lección 08: habilitar FP/SIMD, linkear libcore.
//
// Este archivo ahora contiene:
//   1. _start: startup code (FP/SIMD, SP, seteo a cero de .bss, salto a kmain).

// ---- Startup code ----
.global _start
_start:
    // Habilitar FP/SIMD en EL1: CPACR_EL1.FPEN = 0b11 (bits 21:20)
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    // Stack pointer
    ldr     x0, =stack_top
    mov     sp, x0

    // Poner .bss a cero en chunks de 8 bytes.
    ldr     x0, =bss_start
    ldr     x1, =bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
    
    // Iniciar el kernel en Rust
2:
    b       kmain
