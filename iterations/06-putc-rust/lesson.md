# Lección 06 — `putc` en Rust con MMIO volátil

**Objetivo**: portar `putc` de assembler a Rust. Es la primera vez que
código Rust toca hardware directamente — no a través de una función de
asm — usando `core::ptr::write_volatile`. La lección introduce el
concepto de **MMIO** (memory-mapped I/O) y por qué Rust necesita una
primitiva especial (`volatile`) para hablar con hardware.

`puts` se queda en asm por una lección más. En L07 también pasa a
Rust, y `boot.S` queda con solo `_start`.

Archivos:
[boot.S](../iterations/06-putc-rust/boot.S),
[kmain.rs](../iterations/06-putc-rust/kmain.rs),
[linker.ld](../iterations/06-putc-rust/linker.ld),
[Makefile](../iterations/06-putc-rust/Makefile).

---

## 1. Qué es MMIO

Hasta ahora veníamos escribiendo al UART con una línea de asm:

```asm
ldr     x1, =UART0_DR    // x1 = 0x09000000
strb    w0, [x1]         // *0x09000000 = byte
```

Cargamos la dirección `0x09000000` en un registro y escribimos un
byte ahí. Visto de afuera, parece una operación de memoria normal: un
store a una dirección. Pero esa dirección no apunta a RAM. Apunta al
**registro de datos del UART PL011**, un periférico de hardware que el
SoC ha mapeado dentro del espacio de direcciones del CPU.

Eso es lo que se llama **MMIO** — Memory-Mapped I/O. La idea es:
ciertos rangos del espacio de direcciones físicas no están conectados
a celdas de DRAM, sino a registros internos de periféricos (UART,
timer, GIC, controlador de disco, etc.). El CPU accede a esos
registros con las mismas instrucciones de load/store que usa para la
RAM, pero el hardware del bus desvía la operación al periférico
correspondiente en lugar de a un chip de memoria.

En el caso del UART PL011, la dirección `0x09000000` es el **data
register** (UARTDR). Escribir un byte ahí significa "transmitir este
byte por la línea serie". Leer del mismo registro significa "darme el
próximo byte recibido". El periférico interpreta cada acceso de manera
muy distinta a cómo interpretaría la RAM una celda en la misma
dirección.

La consecuencia importante de esto es que **MMIO tiene efectos
secundarios visibles desde fuera del CPU**. Cada acceso "hace algo" en
el mundo real: una escritura literalmente envía un byte por un cable
físico. Eso choca con lo que un compilador asume sobre la memoria.

## 2. El problema con la memoria "normal"

Los compiladores modernos hacen muchas optimizaciones sobre accesos a
memoria, todas basadas en una suposición central: **la memoria es
silenciosa**. Si escribís un valor a una dirección y nadie más toca
esa dirección, leer de ahí más tarde devuelve el mismo valor. Si
escribís dos veces seguidas a la misma dirección sin leer en el medio,
la primera escritura es inútil y se puede borrar. Si lees una dirección
dos veces seguidas sin escribirla, el compilador puede deducir el valor
de la segunda lectura sin emitir el load.

Eso es cierto para RAM normal. Es **falso** para MMIO. Considerá:

```rust
*UART_DR = b'A';
*UART_DR = b'B';
```

Para una memoria normal, el compilador puede borrar la primera
escritura sin cambiar la semántica (nadie va a leer `'A'` antes de que
se sobreescriba con `'B'`). Para el UART, eso es un desastre: borrar la
primera escritura significa **no transmitir la `'A'`**.

Otro ejemplo:

```rust
let a = *STATUS_REG;
let b = *STATUS_REG;
```

Para memoria normal, el compilador puede asumir que `b == a` y emitir
un solo load (o ninguno si nadie usa los valores). Para un registro de
estado de hardware, eso es incorrecto: el bit de "byte recibido" puede
cambiar entre los dos accesos porque acaba de llegar un byte por la
línea serie. El compilador no puede saberlo porque no tiene visibilidad
de qué pasa fuera del CPU.

La conclusión: cuando estamos hablando con MMIO, le tenemos que
**prohibir al compilador** que aplique sus optimizaciones habituales
sobre esos accesos. Necesitamos una primitiva que diga "este acceso
existe exactamente como lo escribí, no lo elimines, no lo combines, no
lo reordenes, no lo deduplices".

## 3. La primitiva: `core::ptr::write_volatile`

Rust tiene exactamente eso: `core::ptr::write_volatile` y
`core::ptr::read_volatile`. Sus firmas son:

```rust
pub unsafe fn write_volatile<T>(dst: *mut T, src: T);
pub unsafe fn read_volatile<T>(src: *const T) -> T;
```

Lo que hacen, semánticamente, es: emitir **exactamente** un acceso a
memoria del tamaño de `T`, en el orden en que aparece en el código,
sin combinarse con otros accesos volátiles ni eliminarse aunque parezca
muerto. LLVM (el backend de rustc) tiene una propiedad interna
"volatile" sobre instrucciones de load/store que las marca como
"intocables" para todas las pasas de optimización.

Son `unsafe` por dos razones:

1. **Trabajan con raw pointers**, y Rust no puede verificar que el
   puntero apunte a algo válido.
2. **MMIO tiene efectos en hardware**, y el compilador no puede
   verificar que esos efectos sean lo que el programador quería. La
   responsabilidad de no romper nada es del programador, marcada con
   `unsafe`.

Vale la pena entender que `volatile` en Rust es **más estricto** que
en C, donde "volatile" históricamente ha tenido una semántica vaga y
ha sido fuente de bugs en kernels. Rust no expone una "marca volatile"
sobre tipos como C; en cambio, hay funciones específicas
`read_volatile` / `write_volatile` que cada acceso aplica
explícitamente. Eso evita el problema clásico de C de "este puntero es
volatile, pero esta optimización lo trató como no-volatile sin querer".
En Rust no podés equivocarte: o usás la función `write_volatile`
explícitamente, o no estás haciendo MMIO.

Importante: `volatile` **no** es lo mismo que "sincronización entre
threads" o "memory barrier entre cores". Para eso hace falta usar
`core::sync::atomic` o instrucciones de barrier (`dmb`/`dsb` en
ARMv8). `volatile` solo le habla al compilador, no al hardware de
coherencia. En L06 no necesitamos barriers porque solo hay un core, un
thread, y nadie más toca el UART. Cuando lleguemos a SMP o a
interacciones entre periféricos, las barriers van a aparecer.

## 4. El cambio en `kmain.rs`

```rust
use core::ptr::write_volatile;

const UART0_DR: *mut u8 = 0x0900_0000 as *mut u8;

#[no_mangle]
pub extern "C" fn putc(byte: u8) {
    unsafe {
        write_volatile(UART0_DR, byte);
    }
}
```

Pieza por pieza:

- **`const UART0_DR: *mut u8 = 0x0900_0000 as *mut u8;`**: declara la
  dirección del data register como una constante de tipo `*mut u8` —
  un raw pointer mutable a un byte. Lo declaramos como `const` porque
  es un valor conocido en tiempo de compilación; no hay alocación, no
  hay variable global, es literalmente "el número 0x09000000 con el
  tipo *mut u8". El cast `as *mut u8` es la única forma legal en Rust
  de fabricar un puntero a partir de un entero.

- **`#[no_mangle] pub extern "C" fn putc(byte: u8)`**: misma combinación
  de atributos que `kmain` en L05. `#[no_mangle]` para que el linker
  encuentre el símbolo bajo el nombre literal `putc` (que es lo que
  busca el `bl putc` de `puts` en `boot.S`). `pub extern "C"` para
  hacerlo visible y respetar AAPCS64. El argumento `byte: u8` llega
  en `w0` por la convención.

  Notá que **no tiene `-> !`** — `putc` sí retorna, a diferencia de
  `kmain`. Eso significa que sí va a tener prólogo y epílogo
  completos.

- **`unsafe { write_volatile(UART0_DR, byte); }`**: el acceso MMIO
  propiamente dicho. El `unsafe` block es obligatorio porque
  `write_volatile` es unsafe. Adentro: pasarle el puntero al UART y
  el byte a transmitir. El compilador emite exactamente un `strb`
  (store byte) a esa dirección, sin combinarlo con nada y sin
  optimizarlo.

## 5. El cambio en `boot.S`

Es solo eliminación: borramos la definición de `putc` y la directiva
`.equ UART0_DR`. Lo que queda en el archivo es `_start`, `puts`, y
nada más:

```asm
puts:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0
1:  ldrb    w0, [x19], #1
    cbz     w0, 2f
    bl      putc           // ← este símbolo ahora viene de kmain.o
    b       1b
2:  ldp     x19, x30, [sp], #16
    ret
```

La línea `bl putc` no cambia. Lo que cambia es **cómo el linker la
resuelve**: hasta L05, `putc` era un símbolo local definido más abajo
en el mismo archivo, y el assembler ya generaba el offset relativo
exacto en el `.o`. Ahora `putc` no aparece en `boot.S`, así que el
assembler emite la instrucción `bl` con un offset placeholder (todo
ceros) y agrega una **relocación** al `.o` que dice "acá hay un `bl`,
el target es el símbolo `putc`, cuando el linker sepa dónde está,
parchee este offset".

El linker hace ese parche en el paso final, después de combinar
`boot.o` y `kmain.o` en `kernel.elf`. El `bl` queda apuntando a la
dirección donde rustc colocó la función `putc` de Rust. Desde el punto
de vista de la CPU, no hay diferencia con un `bl` "normal" — es la
misma instrucción, el mismo offset, el mismo efecto. El cruce de
lenguaje es invisible en runtime.

**Detalle de assembler que es bueno tener claro**: GNU as / clang as
tratan automáticamente los símbolos no definidos como **externos**
durante el ensamblado. No hay que escribir `.extern putc` ni nada
similar. La existencia de la referencia (`bl putc`) sin definición es
suficiente para que el assembler emita la relocación. Si después el
linker no encuentra el símbolo en ningún `.o`, entonces sí da error
("undefined symbol: putc"). Para que esto funcione, `putc` en Rust
tiene que estar marcado `#[no_mangle]` y `pub` — sin eso, rustc lo
mangle-aría o lo dejaría local, y el linker no lo encontraría.

## 6. Un obstáculo: las precondition checks de `core`

La primera vez que intenté compilar con la nueva `putc`, el linker
rechazó el build con dos errores:

```
ld.lld: error: undefined symbol: core::panicking::panic_nounwind_fmt::...
>>> referenced by kmain.o:(core::ptr::write_volatile::precondition_check::...)

ld.lld: error: undefined symbol: core::panicking::panic_fmt::...
>>> referenced by kmain.o:(core::ptr::const_ptr::is_aligned_to::...)
```

Esto es muy instructivo y vale la pena entenderlo bien.

`core::ptr::write_volatile` tiene, en su implementación interna, una
**precondition check**: verifica que el puntero esté alineado al
tamaño del tipo `T`. En nuestro caso `T = u8`, así que la condición es
trivialmente cierta (todo puntero está alineado a 1), pero el
compilador en `opt-level=0` no la elimina — la deja como una rama
condicional que, si falla, llama a `core::panicking::panic_fmt(...)`
con un mensaje describiendo el error.

`panic_fmt` es una función interna de `core`, definida en otro módulo
de `core` que **no se compila junto con nuestro crate**. Cuando rustc
emite el código de `write_volatile` con la check incluida, deja la
referencia a `panic_fmt` como una relocación external — esperando que
en algún momento esté disponible en la rama de linkeo. Para una
aplicación normal con `std`, `panic_fmt` viene del `core` precompilado
distribuido por rustup (lo que vive en `~/.rustup/.../libcore-*.rlib`),
y el linker lo encuentra ahí.

Nosotros no estamos linkeando contra esa `core` precompilada de la
misma manera. Estamos invocando `rustc --emit=obj` directamente, lo
que genera un único `.o` con solo el código de **nuestro crate**, no
de las dependencias. La parte de `core` que usamos viene "inlineada"
en el sentido de que rustc copia las funciones de `core` que el código
necesita, dentro de `kmain.o`. Pero `panic_fmt` queda como referencia
porque no se inlinea — y como no estamos linkeando `libcore.rlib`
explícitamente, no aparece.

Hay varias soluciones posibles. La que elegimos es la más quirúrgica:

```make
RUSTCFLAGS := ... -C debug-assertions=off
```

`-C debug-assertions=off` le dice a rustc "compilá `core` (y nuestro
código) sin incluir las assertions de debug". Las precondition checks
de `write_volatile` y `is_aligned_to` son debug assertions, así que
con esta flag desaparecen completamente, y con ellas las referencias a
`panic_fmt`. El link funciona limpio.

Alternativas que descartamos:

- **`-C opt-level=1`** o más: las optimizaciones de LLVM eliminan las
  checks (porque ve que la condición es trivialmente cierta para
  punteros a `u8`) y el problema desaparece. Pero eso cambia mucho
  más que solo las debug assertions: cambia todo el código generado,
  hace que el desensamblado sea mucho más difícil de seguir, y nos
  aleja del estilo "literal" que estamos manteniendo en estas
  lecciones para fines pedagógicos. Por eso preferimos
  `-C debug-assertions=off`, que es estrictamente más quirúrgico.

- **Linkear contra `libcore.rlib`**: técnicamente posible pero complica
  bastante el Makefile y nos acerca al territorio de Cargo, que
  estamos evitando deliberadamente.

- **Implementar nuestro propio `panic_fmt`**: feo porque tendríamos
  que copiar las firmas internas de `core`, que están marcadas como
  `unstable` y pueden cambiar.

`-C debug-assertions=off` es la solución estándar en la comunidad de
embedded Rust para este caso exacto. Vale la pena entender que esto
**no afecta a nuestro `panic_handler`**: ese sigue siendo el mínimo de
`loop {}` y se va a invocar normalmente si nuestro código de aplicación
hace `panic!()`. Lo que apagamos son las checks que `core` mete dentro
de sus propias funciones para validar invariantes en debug builds.

## 7. Inspección del binario resultante

Después del build, el `putc` que generó rustc se ve así (a opt-level=0):

```
00000000400000a4 <putc>:
400000a4: f81f0ffe     str    x30, [sp, #-0x10]!
400000a8: 2a0003e1     mov    w1, w0
400000ac: d503201f     nop
400000b0: 100001c2     adr    x2, 0x400000e8
400000b4: 52a12008     mov    w8, #0x9000000
400000b8: 2a0803e0     mov    w0, w8
400000bc: 97ffffeb     bl     0x40000068 <core::ptr::write_volatile>
400000c0: f84107fe     ldr    x30, [sp], #0x10
400000c4: d65f03c0     ret
```

Hay tres cosas para destacar:

**Primera**: `putc` no inlinea `write_volatile`. Hace `bl` a una
función `core::ptr::write_volatile` que rustc copió dentro de
`kmain.o` desde `core`. A `opt-level=0` no hay inlining, ni siquiera
de funciones triviales como esta. A `opt-level=2` o más, LLVM sin duda
la inlinearía y `putc` quedaría reducida a 2-3 instrucciones. Es
deuda de "modo debug" que aceptamos por legibilidad.

**Segunda**: `mov w8, #0x9000000` carga el valor `0x09000000` como
inmediato. Esto puede sorprender porque `0x09000000` parece un número
"grande", pero AArch64 tiene un encoding de mov-immediate que soporta
constantes con un patrón limitado de bits. `0x09000000` cae dentro de
ese patrón (es `9` shift-eado a la izquierda por 24 bits), así que
LLVM lo emite en una sola instrucción sin necesidad de cargarlo de
`.rodata`. Si la dirección fuera un valor más raro, se vería un `adrp`
+ `add` o un `ldr` desde un literal pool.

**Tercera y más interesante**: el `adr x2, 0x400000e8` antes del `bl`.
¿Qué hace ahí? Estamos llamando a `write_volatile`, que toma dos
argumentos (dst en `x0`, src en `w1`). ¿Por qué se está cargando un
**tercer** argumento en `x2`?

Es la **caller location** del `#[track_caller]` interno. `write_volatile`
en `core` está marcada (por dentro) con un mecanismo que le permite,
si llega a hacer panic, reportar dónde fue **llamada** en lugar de
"dentro de `write_volatile`". Para hacer eso, rustc transforma la
firma de la función internamente para agregar un parámetro implícito
extra: un puntero a una struct `&'static core::panic::Location` que
describe el call site (filename, línea, columna). Ese parámetro va en
`x2` (tercer argumento AAPCS64).

Si miramos `.rodata` en el ELF final, lo confirmamos:

```
400000c8 6b6d6169 6e2e7273 00...                 "kmain.rs\0"
400000d8 4d617274 696e2042 6f63616e 65677261 0a00 "Martin Bocanegra\n\0"
400000e8 c8000040 00000000 08000000 00000000      Location { file_ptr=0x400000c8, file_len=8,
400000f8 25000000 09000000                                   line=37, col=9 }
```

`0x400000e8` (la dirección que carga `adr x2`) contiene un struct
`Location` que apunta a `"kmain.rs"` (8 bytes), línea 37 (`0x25 = 37`),
columna 9. Línea 37 columna 9 de `kmain.rs` es exactamente
`        write_volatile(UART0_DR, byte);` — la columna 9 es donde
empieza la palabra `write_volatile`. Esa metadata existe **por si**
`write_volatile` hace panic alguna vez, para reportar "panicked at
kmain.rs:37:9". No vamos a hacer panic nunca acá (la check de
alineación trivialmente pasa para `u8`), pero el compilador no puede
saberlo a `opt-level=0`, así que la metadata se queda.

24 bytes en `.rodata` y un `adr` extra por cada call site. Es el costo
de un compilador que prioriza calidad de mensajes de error sobre
tamaño binario. A `opt-level=2` esa metadata se elimina junto con la
llamada inlineada a `write_volatile` cuando LLVM ve que la check de
alineación es trivialmente cierta.

## 8. Verificación

```sh
make clean && make && make run
```

Output: `Martin Bocanegra`. Idéntico a L05, idéntico a L01.

Para confirmar que `putc` ahora está en Rust:

```sh
llvm-objdump -t kernel.elf | grep -E 'putc|puts'
```

Debe aparecer `putc` con la marca `F` (function) que pone rustc, en
una dirección distinta de `puts`:

```
0000000040000024 g       .text   puts          ← asm, sin tamaño
00000000400000a4 g     F .text   putc          ← Rust, con tamaño
```

El cruce asm→Rust se puede verificar desensamblando `puts` y viendo
que su `bl putc` apunta a `0x400000a4`:

```sh
llvm-objdump -d --disassemble-symbols=puts kernel.elf
```

## 9. Lo que queda preparado para L07

- ✅ `putc` vive en Rust, accede al UART vía `write_volatile`.
- ✅ El cruce asm→Rust (puts→putc) funciona.
- ✅ El cruce Rust→asm (kmain→puts) funciona desde L05.
- ✅ El Makefile usa `-C debug-assertions=off`, lo que abre la puerta
  a usar otras funciones de `core::ptr` sin chocar con symbol errors.
- ❌ `puts` todavía está en asm. En L07 la portamos también, y queda
  como un loop trivial en Rust sobre los bytes de un slice. Después
  de L07, `boot.S` va a contener solo `_start`.

---

## 10. Referencias consultadas

- **`core::ptr::write_volatile` y `read_volatile`** — semántica y
  garantías sobre el orden, tamaño, no-elimination.
  https://doc.rust-lang.org/core/ptr/fn.write_volatile.html

- **The Rust Reference — Behavior considered undefined / unsafe** —
  por qué los accesos a raw pointers son `unsafe`, qué garantías
  tiene que dar el programador.
  https://doc.rust-lang.org/reference/behavior-considered-undefined.html

- **Embedded Rust Book — Memory-mapped Registers** — patrones
  recomendados para envolver MMIO en wrappers seguros (usando crates
  como `volatile-register`); todavía no los necesitamos pero es bueno
  conocer la dirección a la que evolucionan los proyectos serios.
  https://docs.rust-embedded.org/book/peripherals/index.html

- **The Rustonomicon — Beneath `std`** — `#[track_caller]`,
  `core::panic::Location`, cómo Rust reporta call sites en panics.
  https://doc.rust-lang.org/std/panic/struct.Location.html

- **rustc command-line — `-C debug-assertions`** — qué activa y
  desactiva esta flag exactamente.
  https://doc.rust-lang.org/rustc/codegen-options/index.html#debug-assertions

- **PrimeCell UART (PL011) Technical Reference Manual — UARTDR
  (data register)** — el registro en `+0x000` que escribimos para
  transmitir.
  https://developer.arm.com/documentation/ddi0183/latest/
