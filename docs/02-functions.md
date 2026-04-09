# Lección 02 — Llamar a funciones pasando argumentos

**Objetivo**: refactorizar el "hello world" de la lección 01 para poder
*llamar funciones*. El mismo output (`Martin Bocanegra`), pero ahora la
lógica de impresión está dividida en dos funciones con argumentos:

- `putc(byte)` → transmite un byte por el UART.
- `puts(puntero)` → recorre una string `'\0'`-terminada y llama a `putc`
  por cada byte.

Archivos: [boot.S](../iterations/02-functions/boot.S), [linker.ld](../iterations/02-functions/linker.ld). El `Makefile`
queda igual.

---

## 1. ¿Qué significa "llamar a una función" en ARMv8-A?

En ARMv8-A no existe una instrucción mágica de "call" como en x86. Una
llamada a función se arma con dos piezas:

### La instrucción `bl` (Branch with Link)

`bl etiqueta` hace dos cosas en un mismo ciclo:
1. Copia `PC + 4` (la dirección de la instrucción siguiente) al registro
   `x30`, llamado **Link Register** o **LR**.
2. Salta a `etiqueta`.

Es decir, `bl` es un "branch" normal pero que además deja anotado en `x30`
dónde tenía que volver. El nombre "link" viene de ahí: *enlaza* el punto
de retorno al salto.

### La instrucción `ret`

`ret` es equivalente a "saltar a la dirección que haya en `x30`". Es
literalmente una abreviación de `br x30` (branch al contenido de x30).

Con esas dos instrucciones ya podemos llamar una función y volver:

```asm
_start:
    bl      mi_funcion      // x30 = dirección de "siguiente", saltamos
    ...                     // al volver caemos acá

mi_funcion:
    ...
    ret                     // saltar a x30 → volvemos al caller
```

No hay más. No hay "call stack" en el sentido de x86. El mecanismo básico
es: `bl` guarda dónde volver, `ret` vuelve.

---

## 2. La calling convention (AAPCS64)

ARM publica un documento llamado **Procedure Call Standard for the Arm
64-bit Architecture (AAPCS64)** que define las reglas de cómo pasar
argumentos, devolver valores, y qué registros debe preservar cada lado
de una llamada. Es la "calling convention" de ARMv8-A.

Referencia: https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst

Lo mínimo que necesitamos saber para esta lección:

### Pasaje de argumentos

Los primeros 8 argumentos enteros/punteros van en los registros
`x0`..`x7` (o sus mitades `w0`..`w7` si son de 32 bits). Argumentos
adicionales van por stack, pero no vamos a llegar a eso hoy.

- `putc(byte)` → el byte va en `w0`.
- `puts(ptr)` → el puntero va en `x0`.

### Valor de retorno

Va en `x0` (o `w0`). Nuestras funciones no devuelven nada, así que no
nos importa.

### Registros "caller-saved" vs "callee-saved"

Esto es lo importante y lo que motiva que aparezca el stack.

| Registros    | Tipo          | Quién los preserva                              |
|--------------|---------------|-------------------------------------------------|
| `x0`..`x18`  | caller-saved  | El **caller** los guarda si le importan         |
| `x19`..`x28` | callee-saved  | La **función llamada** los guarda si los usa    |
| `x29` (FP)   | frame pointer | Callee-saved                                    |
| `x30` (LR)   | link register | Callee-saved **si la función llama a otra**     |

Traducido a reglas operativas:

- Si una función va a usar `x19..x28`, tiene que guardar el valor
  original y restaurarlo al salir. La obligación es de la función llamada.
- Si una función va a sobrevivir a una llamada con algún valor en
  `x0..x18`, le conviene moverlo a un `x19..x28` o guardarlo en memoria,
  porque la función llamada tiene derecho a pisarlos.
- Si una función llama a otra, tiene que guardar `x30` antes, porque el
  `bl` interno la va a sobreescribir con la nueva dirección de retorno.
  Si no lo guarda, se olvida cómo volver.

---

## 3. ¿Por qué aparece el stack?

Un **stack** es una región de memoria donde cada función puede guardar
temporalmente valores que necesita que "sobrevivan" a algo (a una llamada,
a una interrupción). Crece hacia abajo en ARMv8-A por convención: el SP
apunta al valor más recientemente pusheado, y "push" significa
*decrementar* SP y escribir.

En la lección 01 no necesitábamos stack porque todo estaba inline en
`_start` — no había llamadas. Ahora tenemos `puts` llamando a `putc`, y
`puts` necesita preservar dos cosas a través de la llamada:

1. **Su link register `x30`**. Cuando `puts` fue llamada, `x30` guardaba
   "a dónde volver cuando termine". En el momento en que `puts` hace
   `bl putc`, esa instrucción sobreescribe `x30` con la dirección de
   retorno de `putc`. Si `puts` no guardó su `x30` antes, pierde para
   siempre la dirección a la que tenía que volver.

2. **El puntero al string**. Lo queremos preservar a lo largo de todo el
   loop. Pero el loop llama a `putc`, y `putc` puede usar cualquier
   registro `x0..x18` como scratch (son caller-saved). Si guardáramos el
   puntero en, digamos, `x1`, `putc` tendría derecho a pisarlo. Tenemos
   que ponerlo en un registro callee-saved (`x19..x28`). Pero **eso**
   implica que al final de `puts` tenemos que devolver el valor original
   de `x19` al caller, porque el caller tiene derecho a asumir que sus
   `x19..x28` siguen intactos. O sea, también lo tenemos que guardar al
   entrar y restaurar al salir.

Esas dos cosas —salvar `x30` y salvar `x19`— son la razón por la que
necesitamos el stack. En `putc` en cambio no hace falta stack, porque
`putc` no llama a nadie (`x30` no corre peligro) y solo usa `x1`
(caller-saved, nadie espera nada de él).

---

## 4. Montar el stack

Un stack son tres cosas:

1. **Una región de memoria** reservada para ese uso.
2. **Una dirección inicial** (el "tope") desde la cual el SP va a empezar
   a crecer hacia abajo.
3. **SP apuntando ahí** antes de la primera operación que use el stack.

### Reservar la memoria: linker script

```ld
SECTIONS
{
    . = 0x40000000;
    .text : { *(.text) }

    . = ALIGN(16);
    . += 0x1000;        /* 4 KiB de stack */
    stack_top = .;
}
```

Lo que hicimos:

- Después del `.text`, alineamos el location counter a 16 bytes con
  `. = ALIGN(16)`. **SP en ARMv8-A tiene que estar alineado a 16 bytes**
  cuando se usa para accesos a memoria; si no, las instrucciones
  `stp`/`ldp` tiran excepción.
- Avanzamos 4096 bytes con `. += 0x1000`. Esa es la región del stack.
  Es un tamaño arbitrario elegido por simplicidad — 4 KiB alcanza y
  sobra para lo poco que pushea nuestro código.
- Definimos el símbolo `stack_top` con el valor actual del location
  counter. Como el stack crece hacia abajo, `stack_top` queda en la
  dirección *más alta* del área reservada, que es el valor inicial
  correcto para SP.

Nota: esta región no ocupa bytes en el ELF. No hay contenido que cargar,
solo estamos reservando un rango de direcciones. La memoria física está
ahí (QEMU `virt` tiene RAM desde `0x40000000`) y la usamos tal cual,
sin inicializar. Como el stack se va a escribir antes de leerse, da igual
qué basura tenga.

### Setear SP: en `boot.S`

```asm
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    ...
```

`SP` no puede ser destino directo de un `ldr` con literal pool (es un
registro "especial"), así que cargamos primero el valor en `x0` y después
lo movemos a `sp` con `mov`. Dos instrucciones, listo.

---

## 5. El prólogo y epílogo de `puts`

Este es el patrón canónico que vas a ver en cualquier función ARMv8 que
llame a otra o use registros callee-saved:

```asm
puts:
    stp     x19, x30, [sp, #-16]!   // prólogo: push de x19 y x30
    mov     x19, x0

    ...body...

    ldp     x19, x30, [sp], #16     // epílogo: pop de x19 y x30
    ret
```

### `stp x19, x30, [sp, #-16]!`

`stp` = "store pair". Guarda dos registros de 64 bits en memoria
contiguamente (16 bytes). Los argumentos:

- `x19, x30` → los dos registros a guardar.
- `[sp, #-16]!` → la dirección de destino es `sp - 16`, y el `!` al final
  es la sintaxis de **pre-indexed writeback**: antes del store, SP se
  actualiza a `sp - 16`. En C sería algo como `sp -= 16; *sp = x19; *(sp+8) = x30;`.

Esto es equivalente al "push" de x86 pero empujando dos valores de una
sola vez. Y como movemos SP en exactamente 16 bytes, mantenemos el
alineamiento de 16 que ARMv8 exige.

### `ldp x19, x30, [sp], #16`

`ldp` = "load pair". El opuesto de `stp`. Y `[sp], #16` es
**post-indexed writeback**: primero se hacen los loads desde `sp` y
`sp+8`, y después se hace `sp += 16`. En C: `x19 = *sp; x30 = *(sp+8); sp += 16;`.

Es "pop" de dos valores. Restauramos exactamente lo que habíamos empujado.

### ¿Por qué `x19` y `x30` juntos?

Podríamos haberlos guardado con dos `str` separados, pero `stp`/`ldp`
son una sola instrucción cada uno, más rápidos, y —lo más importante—
mueven SP en un múltiplo de 16 de una sola vez, así que no hay un
estado intermedio donde SP quede desalineado. Es idiomático.

---

## 6. Recorrido paso a paso

Lo que pasa cuando ejecutamos el programa:

1. **`_start` arranca** con PC = `0x40000000` y SP = basura.
2. **Seteo del stack**:
   - `ldr x0, =stack_top` carga el valor de `stack_top` (calculado por
     el linker) en `x0`.
   - `mov sp, x0` → SP apunta ahora al final del área reservada de stack.
3. **Llamada a puts**:
   - `adr x0, msg` pone en `x0` la dirección de la string.
   - `bl puts` → guarda `PC+4` en `x30` (la dirección de `halt`) y salta
     a `puts`.
4. **Prólogo de puts**:
   - `stp x19, x30, [sp, #-16]!` decrementa SP en 16 y guarda ahí `x19`
     (el valor original del caller, basura en nuestro caso porque
     `_start` no lo usaba) y `x30` (la dirección de `halt`).
   - `mov x19, x0` → `x19` ahora guarda el puntero al string.
5. **Loop de puts**:
   - `ldrb w0, [x19], #1` carga un byte y pre-carga el siguiente
     incrementando `x19`.
   - `cbz w0, 2f` → si el byte es 0, salta al epílogo.
   - `bl putc` → `x30` se sobreescribe con la dirección de retorno a
     dentro del loop, y saltamos a `putc`.
6. **putc ejecuta**:
   - `ldr x1, =UART0_DR` pone la dirección del UART en `x1` (pisa el
     valor caller-saved que había antes, sin consecuencias).
   - `strb w0, [x1]` transmite el byte.
   - `ret` salta a `x30`, que apunta de vuelta a la instrucción
     siguiente a `bl putc` dentro de `puts`.
7. **Volvemos al loop** y repetimos hasta encontrar `'\0'`.
8. **Epílogo de puts**:
   - `ldp x19, x30, [sp], #16` restaura `x19` (a la basura original) y
     `x30` (a la dirección de `halt`), e incrementa SP en 16.
   - `ret` salta a `halt`.
9. **halt**: `wfe` y loop infinito.

---

## 7. Comparación con la lección 01

| Concepto                  | Lección 01                  | Lección 02                         |
|---------------------------|-----------------------------|------------------------------------|
| Cantidad de funciones     | 0 (solo `_start` lineal)    | 2 (`puts`, `putc`) + `_start`      |
| Llamadas                  | Ninguna                     | `_start → puts → putc`             |
| Stack                     | No existe                   | 4 KiB reservados en linker.ld      |
| SP                        | Indeterminado, no se usa    | Seteado a `stack_top` al arranque  |
| Uso de `x30` (LR)         | No                          | Guardado/restaurado en prólogos    |
| Uso de registros callee-saved | No                      | `x19` para preservar el puntero    |
| Instrucciones nuevas      | —                           | `bl`, `ret`, `stp`, `ldp`          |
| Output                    | `Martin Bocanegra`          | `Martin Bocanegra` (idem)          |

El output es exactamente el mismo. Lo que cambió es la **estructura
interna** del kernel: ahora es modular, y esa modularidad es la base
sobre la cual vamos a poder eventualmente saltar a C o Rust.

---

## 8. Referencias consultadas

- **AAPCS64 — Procedure Call Standard for the Arm 64-bit Architecture**.
  La spec oficial de la calling convention. Define quién es caller-saved,
  quién es callee-saved, y cómo se pasan argumentos.
  https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst
- **Arm A64 Instruction Set Architecture** — referencia de `bl`, `ret`,
  `stp`, `ldp`, y sus modos de direccionamiento con pre/post-indexed
  writeback. https://developer.arm.com/documentation/ddi0596/latest/
- **Arm ARM (DDI 0487)** — sección "Stack pointer alignment" (requisito
  de alineamiento de 16 bytes en accesos a memoria con SP).
  https://developer.arm.com/documentation/ddi0487/latest/
