// boot.S — Lección 04: inicialización de .bss en el arranque.
//
// _start ahora hace tres cosas antes de ceder el control a kmain:
//   1. Setea SP.
//   2. Pone a cero el rango [bss_start, bss_end).
//   3. Salta a kmain.
//
// Setear .bss a cero es un paso indispensable antes de pasar el control
// a código generado por un compilador de alto nivel. El compilador
// (clang, rustc) coloca en .bss los statics cuyo valor inicial es todo
// ceros, como optimización de tamaño del ejecutable: si son todos ceros,
// no vale la pena gastar bytes del archivo guardándolos. El código
// generado asume entonces que ese rango de memoria está en cero cuando
// arranca el programa; si no lo está, un 'static X: u32 = 0' leería
// basura en lugar de 0. Hoy .bss está vacía y el loop no hace ningún
// trabajo, pero el día que aparezca Rust con su primer static, este
// mismo código lo va a poner a cero sin cambios.

.equ UART0_DR, 0x09000000

// ---- Startup code ----
.global _start
_start:
    // 1. Stack pointer
    ldr     x0, =stack_top
    mov     sp, x0

    // 2. Zero .bss en chunks de 8 bytes.
    //    xzr es el "zero register": siempre lee 0, no ocupa un registro real.
    //    [x0], #8 es post-indexed store: guarda, después incrementa x0 en 8.
    //    b.hs = "branch if higher or same" (comparación unsigned).
    ldr     x0, =bss_start
    ldr     x1, =bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:

    // 3. Transferir el control al kernel.
    b       kmain

// ---- kmain: entry point del kernel ----
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
