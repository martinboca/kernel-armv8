# Lección 01 — "Hello, bare-metal world"

**Objetivo**: ejecutar un programa ARMv8-A en QEMU que imprima
`"Martin Bocanegra"` por la consola serial, sin sistema operativo, sin
runtime, sin libc. El mínimo indispensable.

Archivos: [boot.S](./boot.S), [linker.ld](./linker.ld), [Makefile](./Makefile).

---

## 1. Qué estamos emulando

QEMU puede emular muchas máquinas ARM. Usamos la llamada **`virt`**: un
board sintético pensado para desarrollo y virtualización, con un memory
map público y estable.

Referencia: https://qemu-project.gitlab.io/qemu/system/arm/virt.html

Dos direcciones de ese memory map nos importan hoy:

| Dirección     | Qué hay ahí            |
|---------------|------------------------|
| `0x09000000`  | UART0 (PL011)          |
| `0x40000000`  | Inicio de DRAM         |

- En **`0x09000000`** vive el UART PL011 emulado. Escribir un byte en esa
  dirección lo transmite por la consola serial, que con `-nographic`
  aparece en nuestro terminal.
- A partir de **`0x40000000`** empieza la RAM. Nuestro código va a vivir
  exactamente ahí.

CPU elegida: `-cpu cortex-a72` (un core ARMv8-A real; cualquier otro sirve).

**Nota importante**: estas direcciones NO son parte de la arquitectura
ARMv8-A. Son decisiones del board "virt" de QEMU. Cada dispositivo real
(Raspberry Pi, celulares, etc.) tiene su propio memory map distinto.

---

## 2. Imprimir un byte por el PL011

El PL011 es un diseño de UART de ARM (IP block "PrimeCell"), descrito en
**ARM DDI 0183**: https://developer.arm.com/documentation/ddi0183/latest/

Para esta lección solo necesitamos un registro:

| Offset  | Registro | Uso                                              |
|---------|----------|--------------------------------------------------|
| `0x000` | `UARTDR` | Data Register. Escribir 1 byte acá lo transmite. |

Como la base del UART en QEMU `virt` es `0x09000000` y `UARTDR` está en
offset `0x000`, la dirección absoluta donde escribimos es simplemente
`0x09000000`.

En hardware real habría que:
- Inicializar baudrate, habilitar TX.
- Chequear el bit "Transmit FIFO Full" del Flag Register antes de cada
  escritura, para no perder bytes.

En QEMU el modelo del PL011 ya está listo para transmitir desde el
arranque y el FIFO nunca se llena, así que omitimos todo eso.

---

## 3. `boot.S` línea por línea

```asm
.equ UART0_DR, 0x09000000

.global _start
_start:
    ldr     x0, =UART0_DR
    adr     x1, msg

1:  ldrb    w2, [x1], #1
    cbz     w2, 2f
    strb    w2, [x0]
    b       1b

2:  wfe
    b       2b

msg: .asciz "Martin Bocanegra\n"
```

- **`.equ UART0_DR, 0x09000000`**: define una constante del ensamblador,
  como un `#define` en C. No reserva memoria, solo le da nombre a un número.

- **`.global _start`**: marca el símbolo `_start` como global, es decir,
  visible fuera de este archivo. Hace falta porque el linker script dice
  `ENTRY(_start)` y necesita encontrarlo en la tabla de símbolos globales.
  En ensamblador, los símbolos son locales por default (al revés que en C).

- **`_start:`** es la etiqueta a la que va a saltar QEMU cuando arranque
  el CPU. Es el entry point del kernel.

- **`ldr x0, =UART0_DR`**: carga el valor constante `0x09000000` en el
  registro `x0`. La sintaxis `=valor` es una pseudo-instrucción del
  assembler: como `0x09000000` es demasiado grande para caber en el campo
  inmediato de `mov`, el assembler lo guarda en un "literal pool" cerca
  del código y emite una carga PC-relativa.

- **`adr x1, msg`**: carga en `x1` la dirección de la etiqueta `msg`, de
  forma **PC-relativa** (calcula `PC + offset`). Esto es importante en
  bare-metal porque no dependemos de una dirección absoluta fija.

- **Loop principal** (etiqueta numérica `1:`):

  - **`ldrb w2, [x1], #1`**: carga un *byte* de la dirección apuntada por
    `x1` en `w2`, y **después** incrementa `x1` en 1. Es un "post-indexed
    load". Equivale a `w2 = *x1; x1 += 1;` en C.

    `w2` es la vista de 32 bits del registro `x2` (los 32 bits bajos).
    Todos los registros generales tienen esa doble vista: `x0..x30` de
    64 bits y `w0..w30` de 32 bits. Usamos `w` porque un byte cabe de
    sobra en 32 bits.

  - **`cbz w2, 2f`**: "compare and branch if zero". Si `w2` es 0 (fin de
    string), salta a la etiqueta `2` *forward*. El sufijo `f` significa
    "forward", `b` sería "backward".

  - **`strb w2, [x0]`**: guarda el byte bajo de `w2` en la dirección
    apuntada por `x0`, que es el Data Register del UART. Este store es
    lo que efectivamente transmite el byte por la consola.

  - **`b 1b`**: branch incondicional a la etiqueta `1` *backward*.
    Volvemos al principio del loop.

- **Halt** (etiqueta `2:`):

  - **`wfe`**: "wait for event". Duerme el core hasta que llegue un
    evento al sistema. Consume poco mientras tanto.
  - **`b 2b`**: si por alguna razón despierta, volvemos a dormir.

- **`msg: .asciz "Martin Bocanegra\n"`**: emite los bytes del string más
  un terminador nulo, precedidos por la etiqueta `msg`. Queda embebido en
  la sección `.text` junto con el código, que es lo más simple posible.
  El CPU nunca lo ejecuta como instrucción porque hacemos `b 1b` antes de
  llegar ahí.

Referencia del ISA: https://developer.arm.com/documentation/ddi0596/latest/

---

## 4. `linker.ld`

```ld
ENTRY(_start)

SECTIONS
{
    . = 0x40000000;
    .text : { *(.text) }
}
```

- **`ENTRY(_start)`**: escribe `_start` en el campo `e_entry` del header
  ELF. QEMU va a leer ese campo para saber a qué dirección saltar.

- **`SECTIONS { ... }`**: la lista de instrucciones de layout para el
  linker.

- **`. = 0x40000000`**: "el location counter empieza en `0x40000000`". A
  partir de acá, lo que coloquemos se ubica en esa dirección. Como
  `0x40000000` es donde empieza la RAM de QEMU `virt`, el `.text` va a
  quedar literalmente al principio de la RAM.

- **`.text : { *(.text) }`**: crea una sección de salida llamada `.text`
  y mete dentro las secciones `.text` de todos los archivos de entrada
  (nuestro único `boot.o`). El location counter avanza automáticamente
  por el tamaño de lo que se coloca.

Y eso es todo lo que hace falta. El código, la constante del UART, y el
string del mensaje caben todos en esa única sección.

---

## 5. `Makefile`

```make
AS := clang
LD := ld.lld

ASFLAGS := --target=aarch64-none-elf -c
LDFLAGS := -T linker.ld

QEMU_FLAGS := -machine virt -cpu cortex-a72 -nographic -kernel kernel.elf
```

- **`clang --target=aarch64-none-elf`**: usamos el clang de Apple como
  assembler cross. La flag `--target` le dice que genere código ARMv8-A
  de 64 bits en formato ELF (no Mach-O). La flag `-c` significa
  "compilá pero no linkees".

- **`ld.lld -T linker.ld`**: linker de LLVM con nuestro script. Usamos
  `ld.lld` directamente y no a través de `clang` porque en macOS el
  driver de clang le pasa flags de Mach-O al linker y confunde a lld.

- **`qemu-system-aarch64 -machine virt -cpu cortex-a72 -nographic -kernel kernel.elf`**:

  - `-machine virt`: el board sintético que vimos en §1.
  - `-cpu cortex-a72`: el core.
  - `-nographic`: redirige la consola serial a stdin/stdout del terminal.
    Sin esto no veríamos nada.
  - `-kernel kernel.elf`: QEMU parsea el ELF, carga los segmentos en
    las direcciones indicadas por el ELF (o sea `0x40000000`), y salta
    al `e_entry` (o sea `_start`).

Para salir de QEMU con `-nographic`: **Ctrl-A** y después **X**.

---

## 6. Qué pasa al apretar `make run`

1. `make` compila `boot.S` → `boot.o` y linkea → `kernel.elf`.
2. QEMU arranca, parsea el ELF, ve que hay que cargar contenido en
   `0x40000000`, y copia el código del `.text` ahí.
3. QEMU inicializa el CPU (Cortex-A72) con `PC = 0x40000000`
   (el valor de `e_entry`).
4. El CPU empieza a ejecutar desde `_start`:
   - Carga `0x09000000` en `x0`.
   - Carga la dirección de `msg` en `x1`.
   - Lee bytes del mensaje uno a uno y los va escribiendo al UART.
5. Cuando llega al `'\0'`, salta al halt y entra en `wfe`.
6. Nosotros, del otro lado, vemos `"Martin Bocanegra"` en el terminal.

---

## 7. Referencias consultadas

- **QEMU virt machine** — memory map, UART base, `-kernel` con ELF.
  https://qemu-project.gitlab.io/qemu/system/arm/virt.html
- **Arm PrimeCell UART (PL011) TRM (DDI 0183)** — offset del Data Register.
  https://developer.arm.com/documentation/ddi0183/latest/
- **Arm A64 Instruction Set Architecture** — referencia de `ldr`, `adr`,
  `ldrb` post-indexed, `cbz`, `strb`, `wfe`.
  https://developer.arm.com/documentation/ddi0596/latest/
