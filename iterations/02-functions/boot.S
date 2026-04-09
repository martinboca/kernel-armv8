// boot.S — Lección 02: llamar a funciones pasando argumentos.
//
// Refactor de la lección 01. Antes el loop de impresión estaba inline en
// _start. Ahora está dividido en dos funciones:
//
//   putc(w0 = byte)              — transmite un byte por el UART.
//   puts(x0 = puntero a string)  — recorre la string y llama a putc
//                                  por cada byte hasta encontrar '\0'.
//
// Como puts llama a putc, tiene que guardar su link register (x30) antes
// de hacer el bl, porque si no se pierde la dirección de retorno de puts
// cuando putc la sobreescriba. Ese es el motivo por el cual aparece el
// stack en esta lección.

.equ UART0_DR, 0x09000000

.global _start
_start:
    // Inicializar el stack pointer al tope del stack reservado en linker.ld.
    // En ARMv8-A, SP es indeterminado al reset; hay que setearlo antes de
    // usar cualquier instrucción que acceda a la pila.
    ldr     x0, =stack_top
    mov     sp, x0

    adr     x0, msg         // x0 = primer argumento = puntero al mensaje
    bl      puts            // puts(msg)

halt:
    wfe
    b       halt

// ---- puts(x0 = puntero a string '\0'-terminada) ----
puts:
    // Prólogo: guardamos x30 (link register) y x19 (callee-saved) en el
    // stack. Los guardamos juntos con 'stp' para mantener SP alineado a
    // 16 bytes (requisito de ARMv8-A).
    //
    //   [sp, #-16]!  = pre-decremento: SP = SP - 16, y luego store
    //
    // Necesitamos x30 porque bl putc lo va a pisar.
    // Necesitamos x19 (callee-saved) para guardar el puntero al string,
    // porque x0..x18 son caller-saved y putc tiene derecho a clobbearlos.
    stp     x19, x30, [sp, #-16]!

    mov     x19, x0         // x19 = puntero al string (preservado en todo puts)

1:  ldrb    w0, [x19], #1   // w0 = *x19++; listo como arg0 para putc
    cbz     w0, 2f          // si el byte es '\0', terminamos
    bl      putc            // putc(w0) — pisa x0, x1, x30
    b       1b

2:  // Epílogo: restauramos x19 y x30 del stack y volvemos.
    //   [sp], #16  = post-incremento: load, y luego SP = SP + 16
    ldp     x19, x30, [sp], #16
    ret                     // salta a x30 (el caller de puts)

// ---- putc(w0 = byte a transmitir) ----
// Función hoja: no llama a nadie, así que no necesita prólogo ni stack.
// Puede clobbear libremente los registros caller-saved que use (x1).
putc:
    ldr     x1, =UART0_DR
    strb    w0, [x1]
    ret

msg: .asciz "Martin Bocanegra\n"
