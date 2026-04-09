// boot.S — Lección 03: separar _start (startup code) de kmain (kernel).
//
// _start se reduce al mínimo absoluto: setear SP y transferir el control
// a kmain. Toda la "lógica del kernel" se muda a kmain.
//
// La transferencia se hace con 'b' (no 'bl') porque kmain no vuelve a
// nadie: es el entry point del kernel, no una subrutina. _start deja de
// existir en términos conceptuales en cuanto hace el salto.

.equ UART0_DR, 0x09000000

// ---- Startup code: corre una sola vez, con SP y registros basura ----
.global _start
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    b       kmain

// ---- kmain: entry point del kernel ----
// Arranca con un entorno utilizable: SP válido, puede llamar funciones,
// puede usar el stack. No tiene obligación de preservar ningún registro
// del caller (nadie la está llamando en el sentido tradicional).
// Nunca retorna: cuando termine su trabajo, halt loop.
kmain:
    adr     x0, msg
    bl      puts

halt:
    wfe
    b       halt

// ---- puts(x0 = puntero a string '\0'-terminada) ----
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

msg: .asciz "Martin Bocanegra\n"
