# Lección 05 — Primer código Rust en el kernel

**Objetivo**: mover la función `kmain` a Rust. El output sigue siendo
`Martin Bocanegra`, pero ahora `_start` (asm) hace `b kmain` y cae en
código generado por `rustc` en lugar de assembler. Las rutinas de I/O
(`puts`/`putc`) se quedan en asm por un rato más — la reimplementación
en Rust la dejamos para L06, para que esta lección se concentre en una
sola cosa: integrar Rust al build.

Archivos:
[boot.S](../iterations/05-hello-rust/boot.S),
[kmain.rs](../iterations/05-hello-rust/kmain.rs),
[linker.ld](../iterations/05-hello-rust/linker.ld),
[Makefile](../iterations/05-hello-rust/Makefile).

---

## 1. Qué significa "escribir Rust en un kernel"

Cuando uno escribe Rust "normal" para una aplicación de usuario, está
apoyado sobre una pila de cosas que el lenguaje da por sentadas:

- Una **standard library** (`std`) con `String`, `Vec`, `HashMap`,
  acceso a archivos, threads, red, etc.
- Un **allocator** para memoria dinámica (el heap de `malloc`).
- Un **sistema operativo** abajo que provee syscalls (leer del disco,
  escribir a la consola, crear threads).
- Una función **`main`** que el runtime de Rust llama después de
  inicializar el mundo (argv, stdio, panic hooks, etc.).

Nada de eso existe acá. No hay SO, no hay heap, no hay stdin/stdout,
no hay runtime. Solo tenemos una CPU, un rango de RAM, y un UART. Para
poder compilar Rust en este entorno necesitamos *apagar* todas esas
suposiciones que el compilador trae por default.

Eso se hace con dos atributos que van al tope del archivo:

```rust
#![no_std]
#![no_main]
```

### `#![no_std]` — apagar la standard library

`std` no compila sin un SO abajo, porque sus primitivas (archivos,
threads, sockets) están implementadas contra syscalls. `#![no_std]` le
dice al compilador "no linkees `std`; yo me las arreglo".

Lo que sigue disponible es `core`: la parte del lenguaje que no
necesita SO ni allocator. Iteradores, slices, opciones (`Option`),
resultados (`Result`), traits, aritmética, `PhantomData`, `MaybeUninit`,
`core::ptr`, `core::mem`, `core::arch` (para inline asm). Todo lo que
se puede hacer con solo CPU y memoria.

Lo que *no* está en `core`: nada que requiera allocation dinámica.
`String`, `Vec`, `Box`, `Rc`, `HashMap`, `format!` — todo eso vive en
`alloc` (necesita allocator) o en `std` (necesita SO). Si querés un
`Vec` en un kernel, hay que implementar un allocator y activar el crate
`alloc`. Eso lo haremos más adelante; por ahora vivimos solo con `core`.

### `#![no_main]` — apagar el entry point default

Por default, cuando rustc compila un binario, espera encontrar una
función `fn main()` y genera alrededor un **entry point** propio que
hace cosas como inicializar el runtime de Rust, parsear `argv`, llamar
a `main`, capturar el return code. Ese entry point asume que hay un SO.

`#![no_main]` le dice al compilador "no generes ningún entry point, yo
defino el mío". En nuestro caso el entry point ya existe y es `_start`
en `boot.S`. Desde la perspectiva de Rust, `kmain` no es el entry point
del programa: es una función cualquiera, que resulta ser la primera a
la que alguien la llama desde fuera del crate.

---

## 2. El crate `kmain.rs`

```rust
#![no_std]
#![no_main]

use core::panic::PanicInfo;

extern "C" {
    fn puts(s: *const u8);
}

#[no_mangle]
pub extern "C" fn kmain() -> ! {
    let msg: &[u8] = b"Martin Bocanegra\n\0";
    unsafe {
        puts(msg.as_ptr());
    }
    loop {}
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}
```

Vamos pieza por pieza.

### `extern "C" { fn puts(s: *const u8); }`

Esta declaración le dice al compilador: "existe en algún otro lado una
función llamada `puts` que toma un puntero a `u8` y devuelve nada, y
que respeta la convención de llamada C". No define la función —
solo declara su existencia. El símbolo `puts` lo va a resolver el
linker cuando una todos los `.o` en el ELF final; como `boot.S` exporta
`puts` con `.global`, el linker lo encuentra ahí.

**¿Por qué `"C"` y no el Rust default?** Rust tiene su propia ABI
interna, que **no está estabilizada** — el layout de structs, la forma
en que se pasan los argumentos, en qué registros — el compilador puede
cambiar eso entre versiones sin previo aviso. La ABI `"C"` en cambio es
un contrato público y estable. En `aarch64` significa AAPCS64, la
convención que ya venimos usando en asm: primer argumento en `x0`,
segundo en `x1`, etc. Al declarar `extern "C"` estamos diciendo "puts
sigue esa convención", y efectivamente es así, porque lo escribimos a
mano en ese estilo.

**¿Por qué `*const u8` y no `&[u8]`?** Porque del otro lado hay asm,
no Rust, y los slices (`&[u8]`) son un invento de Rust: un fat pointer
con puntero + longitud. `puts` en asm espera un solo puntero crudo y
lee hasta encontrar un `\0`. Así que el contrato es "puntero a bytes,
terminado en cero", que en Rust se expresa como `*const u8`.

### `#[no_mangle] pub extern "C" fn kmain() -> !`

Tres atributos distintos pegados a una sola firma. Cada uno resuelve
un problema concreto.

**`#[no_mangle]`** — Rust, por default, *mangle*-a los nombres de las
funciones: toma `kmain` y lo convierte en algo como
`_ZN6kmain17h8f3a...E`, un nombre que codifica el módulo, la signatura,
y un hash. Eso le permite sobrecargar nombres entre módulos sin
colisiones. Pero el linker *espera* encontrar un símbolo literalmente
llamado `kmain`, porque `_start` hace `b kmain`. Si dejamos que Rust
mangle el nombre, el linker no lo encuentra y falla. `#[no_mangle]` le
dice al compilador "exportá esta función con su nombre tal cual, sin
transformarlo".

**`pub`** — porque el símbolo tiene que ser visible fuera del crate.
Sin `pub`, Rust lo marca como símbolo local y el linker tampoco lo
encuentra.

**`extern "C"`** — por la misma razón que usamos `extern "C"` en la
declaración de `puts`: queremos que `kmain` respete AAPCS64 al ser
llamada. En realidad, como `_start` la llama con `b kmain` (un salto
sin argumentos ni retorno), la convención casi no importa para esta
llamada en particular — pero es buena higiene, y si algún día agregamos
parámetros (por ejemplo, el puntero al device tree blob en `x0`,
siguiendo el protocolo de boot de Linux arm64), el contrato ya va a
estar bien.

**`-> !`** — el tipo "never" de Rust, que literalmente significa "esta
función no retorna". No es una convención ni un hint: el compilador lo
verifica en tiempo de compilación. Si ponés un `return` en el medio o
si el cuerpo pudiera terminar normalmente, Rust no compila. En nuestro
caso, el `loop {}` final satisface la condición: un loop infinito sin
`break` es un valor de tipo `!`.

Esto encaja exactamente con el `b kmain` de `_start`: usamos `b` (sin
link) justamente porque nadie espera que `kmain` vuelva. Si el día de
mañana alguien cambia `_start` por `bl kmain`, Rust no se entera — va a
seguir compilando sin problemas — pero ahora `_start` va a esperar un
`ret` que nunca llega. El contrato correcto es `b` del lado de asm
y `-> !` del lado de Rust, juntos.

### El cuerpo de `kmain`

```rust
let msg: &[u8] = b"Martin Bocanegra\n\0";
unsafe {
    puts(msg.as_ptr());
}
loop {}
```

- **`b"..."` (byte string literal)**: en Rust, `"..."` es un `&str`
  (texto Unicode validado), mientras que `b"..."` es un `&[u8]` crudo.
  Para pasarle bytes a una función C que solo entiende bytes, `b"..."`
  es la forma correcta. Nota que agregamos el `\0` a mano — Rust no
  pone null-terminator, porque los strings de Rust llevan el largo en
  el tipo.

- **`msg.as_ptr()`**: convierte el slice en un `*const u8` (solo el
  puntero al primer byte, sin el largo). Es lo que `puts` espera.

- **`unsafe { ... }`**: llamar a `extern "C"` siempre es `unsafe` en
  Rust. La razón es que el compilador no puede verificar del otro lado
  del FFI boundary nada: no sabe si `puts` lee de memoria válida, si el
  puntero tiene que ser no-nulo, si está null-terminated. Es el
  programador el que garantiza eso, y `unsafe` es la marca de que el
  programador se hace cargo.

- **`loop {}`**: el halt loop, ahora en Rust. Mucho más pobre que el
  `wfe` + `b` de asm — un `loop {}` no hace WFE, o sea el core no se
  duerme, consume energía todo el tiempo esperando activamente.
  Podríamos mejorar esto con `core::arch::asm!("wfe")`, pero por
  minimalismo lo dejamos en `loop {}` por ahora. Es una deuda técnica
  menor que vamos a limpiar en cuanto necesitemos usar más asm desde
  Rust.

### `#[panic_handler]`

```rust
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}
```

Todo crate `no_std` que pueda hacer panic necesita definir *exactamente
uno* (ni más ni menos) `#[panic_handler]`. Es la función que Rust
llama cuando algo hace panic: una indexación fuera de rango, un
`unwrap()` sobre `None`, un `panic!()` explícito, etc.

En una app normal, el panic handler viene con `std` y hace cosas como
imprimir un stack trace y abortar. Acá no hay nada de eso: el nuestro
es el mínimo posible, colgar el core para siempre. Cuando tengamos un
UART reutilizable desde Rust, una versión mejorada va a imprimir el
mensaje del panic en la consola antes del halt, lo que es una
herramienta de debug invaluable. Por ahora, lo dejamos vacío.

**¿Por qué `-> !`?** Porque el panic handler, conceptualmente, no puede
volver: no tiene a dónde volver. El runtime que lo llama asume que si
llegaste acá, no hay forma de continuar la ejecución. Rust hace cumplir
esa semántica con el tipo de retorno.

**¿Puede nuestro `kmain` actual hacer panic?** En el estado actual, no:
no hay indexaciones, ni `unwrap()`, ni divisiones que puedan dar
division-by-zero. Pero el compilador no sabe eso — el panic handler es
requerido por el lenguaje para cualquier crate `no_std + no_main`,
porque el compilador no puede descartar que algún día, en alguna
recompilación, aparezca un panic. Así que lo tenemos que declarar
siempre. El linker va a descartar el símbolo si nadie lo llama.

---

## 3. Los cambios en `boot.S`

`boot.S` perdió tres cosas: el cuerpo de `kmain`, el halt loop (que
vivía pegado a `kmain`) y el string `msg`. Las tres se fueron a Rust.

Y ganó una cosa: `.global puts`. En L02/L03/L04 `puts` era un símbolo
*local* al archivo, porque nadie fuera de `boot.S` lo llamaba: `_start`
y `kmain` vivían en el mismo `.o`, así que la resolución del símbolo
era interna al ensamblador. Ahora `kmain` vive en `kmain.o` y desde ahí
llama a `puts`; el linker tiene que resolver esa referencia cruzando
archivos, y para eso `puts` tiene que ser un símbolo global. Si nos
olvidamos el `.global`, ld.lld se queja con "undefined symbol: puts".

`putc` no necesita `.global` porque sigue siendo llamada solamente
desde `puts`, dentro del mismo archivo.

El resto queda idéntico: el startup code (`_start` con SP, seteo de
`.bss` a cero, salto a `kmain`) no cambia una línea.

---

## 4. Los cambios en `linker.ld`

Dos cambios, ambos relacionados con cómo rustc emite secciones.

### `.rodata`

```ld
.rodata : {
    *(.rodata)
    *(.rodata.*)
}
```

Rust coloca los string literals (como `b"Martin Bocanegra\n\0"`) en
`.rodata` — *read-only data*. Es la sección estándar de ELF para datos
constantes: tienen valor inicial (a diferencia de `.bss`), pero no se
pueden escribir en runtime (a diferencia de `.data`). En un sistema con
MMU, el loader marca esas páginas como read-only y cualquier escritura
da page fault.

Hasta L04 no teníamos `.rodata` en el linker script porque el único
archivo objeto era `boot.o`, y el assembler no genera nada en
`.rodata` — el `msg` vivía dentro de `.text` porque lo declaramos así.
Rust no: cada constante que aparece en el código queda en su propia
sub-sección `.rodata.ALGO`, y si no las capturamos explícitamente, el
linker no sabe dónde ponerlas y las tira o las coloca en lugares
incorrectos.

El patrón `*(.rodata) *(.rodata.*)` captura tanto `.rodata` "pelado"
como cualquier sub-sección `.rodata.NOMBRE`.

### `*(.text.*)` en la sección `.text`

```ld
.text : {
    *(.text)
    *(.text.*)
}
```

Misma idea que con `.bss.*` en L04. Rustc emite cada función en su
propia sub-sección `.text.NOMBRE` (en nuestro caso, `.text.kmain`)
para permitir al linker hacer garbage collection de funciones no
usadas. Si solo capturáramos `.text` pelado, `kmain` quedaría fuera
del ELF y `_start` haría `b kmain` a una dirección indefinida.

---

## 5. El Makefile

Tres cambios:

```make
RUSTC := rustc
RUSTCFLAGS := --target aarch64-unknown-none --edition 2021 --emit=obj
```

Agregamos `rustc` como herramienta. Si `rustc` no está en el `PATH` del
shell que corre `make`, se puede sobreescribir desde la línea de
comandos con `make RUSTC=~/.cargo/bin/rustc` — Make da precedencia a
los valores pasados por CLI sobre cualquier asignación del Makefile,
así que no importa que sea `:=`.

Los flags:

- **`--target aarch64-unknown-none`**: le dice a rustc que compile para
  ARMv8-A bare-metal. Ese target es Tier 2 de Rust, lo que significa
  que el equipo de Rust distribuye una `core` precompilada — por eso
  nos alcanzó con `rustup target add aarch64-unknown-none`. Si fuera
  un target Tier 3, tendríamos que compilar `core` nosotros con
  `-Z build-std`, que requiere toolchain nightly y es bastante más
  complicado.

  Este target ya tiene configurado `panic-strategy: abort` (tiene
  sentido: en bare-metal no hay nada que "unwind-ear"), así que no
  hace falta pasar `-C panic=abort` explícitamente.

- **`--edition 2021`**: fijamos la edition porque `rustc` invocado
  directamente, sin Cargo.toml, no tiene de dónde deducirla, y el
  default puede cambiar entre versiones. Así el build es reproducible.

- **`--emit=obj`**: por default, rustc quiere producir un ejecutable
  linkeado. `--emit=obj` le dice "generá solo el `.o`" — el linkeo lo
  hacemos nosotros con ld.lld en un paso posterior, igual que con
  `boot.o`. Esto es lo que permite mezclar el objeto de Rust con el de
  asm en un solo ELF final.

```make
kmain.o: kmain.rs
	$(RUSTC) $(RUSTCFLAGS) -o $@ $<

kernel.elf: boot.o kmain.o linker.ld
	$(LD) $(LDFLAGS) -o $@ boot.o kmain.o
```

La regla para `kmain.o` es trivial. La de `kernel.elf` gana una
dependencia y un archivo más en la línea del linker. Todo lo demás
(la regla de `boot.o`, el comando `run`, `clean`) queda igual.

### Por qué `rustc` directo y no Cargo

Cargo es el workflow canónico de Rust. Pero para un kernel mínimo es
overkill: requiere un `Cargo.toml`, un `src/` directory, posiblemente
un `.cargo/config.toml` con el target default, un `target/` directory
que ocupa espacio, etc. Y lo que hace por nosotros, en este estado del
proyecto, se reduce a una sola llamada a `rustc`. Para L05, `rustc`
directo es estrictamente más simple.

El día que necesitemos dependencias externas (por ejemplo, `uefi-rs`,
o un crate de estructuras de datos lock-free), migraremos a Cargo. Por
ahora, directo.

---

## 6. Flujo de ejecución post-L05

1. QEMU salta a `_start` en `0x40000000`.
2. `_start` (asm) setea SP y pone `.bss` a cero.
3. `_start` hace `b kmain`.
4. **Crossing the boundary**: el `kmain` que se ejecuta ahora es código
   generado por rustc, no por clang. Misma ISA, misma ABI (AAPCS64),
   distinto origen.
5. `kmain` de Rust arma el puntero al byte string en `.rodata` y llama
   a `puts`.
6. `puts` (asm) itera el string y llama a `putc` por cada byte.
7. `putc` (asm) escribe cada byte al UART.
8. `puts` retorna a `kmain`.
9. `kmain` entra al `loop {}` y el core queda girando para siempre.

El output en la consola sigue siendo `Martin Bocanegra\n`. Desde
afuera nada cambió; desde adentro, cruzamos el puente más importante
del proyecto hasta ahora.

---

## 7. Verificación

Compilar y correr:

```sh
make clean && make && make run
```

Si tu shell no tiene `~/.cargo/bin` en el PATH:

```sh
make clean && make RUSTC=~/.cargo/bin/rustc && make run
```

El output debe ser `Martin Bocanegra`.

Para inspeccionar que `kmain` viene realmente de Rust, se puede mirar
la tabla de símbolos:

```sh
llvm-objdump -t kernel.elf | grep -E 'kmain|puts|_start'
```

Algo así:

```
0000000040000000 g       .text   _start
0000000040000024 g       .text   puts
0000000040000070 g     F .text   kmain
```

La `F` al lado del tipo de símbolo para `kmain` la pone rustc: marca
el símbolo como "function" con tamaño explícito en la tabla ELF.
El assembler no la pone para `_start` y `puts`, no porque sean "menos
función" sino porque clang no emite el tamaño en esos símbolos por
default. Es una diferencia puramente cosmética, no afecta al linkeo
ni a la ejecución.

---

## 8. Lo que queda preparado para L06

- ✅ Hay un crate Rust compilando limpio y linkeado al ELF.
- ✅ `kmain` vive en Rust con la firma correcta (`extern "C" fn() -> !`).
- ✅ Rust puede llamar a funciones de asm vía `extern "C"`.
- ✅ `.rodata` existe en el linker script y captura datos de Rust.
- ❌ `putc` todavía está en asm — lo vamos a portar a Rust en L06
  usando `core::ptr::write_volatile`. Una vez que `putc` esté en Rust,
  podemos portar `puts` también, y `boot.S` va a quedar con solo
  `_start`, que es el estado terminal que queremos.

---

## 9. Referencias consultadas

- **The Rust Reference — Linkage** (atributos `no_mangle`, `extern`,
  cómo rustc genera nombres de símbolos, tipos de crate).
  https://doc.rust-lang.org/reference/linkage.html

- **The Rust Reference — The `!` type** (el tipo "never" y cuándo es
  habitado / inhabitado).
  https://doc.rust-lang.org/reference/types/never.html

- **The Rustonomicon — FFI** (cómo llamar C desde Rust y viceversa,
  ABI, `unsafe`, tipos compatibles).
  https://doc.rust-lang.org/nomicon/ffi.html

- **The `no_std` book / Embedded Rust Book** (patrón `#![no_std]` +
  `#![no_main]`, panic handler, targets bare-metal).
  https://doc.rust-lang.org/embedded-book/

- **Rust platform support — aarch64-unknown-none** (Tier 2, `core`
  precompilada, panic strategy default).
  https://doc.rust-lang.org/rustc/platform-support/aarch64-unknown-none.html

- **rustc command-line arguments** (`--target`, `--emit`, `--edition`).
  https://doc.rust-lang.org/rustc/command-line-arguments.html
