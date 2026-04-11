# Lección 08 — Soporte completo de `core` en Rust

**Objetivo**: tener acceso completo a `core` de Rust para poder usarlo
sin restricciones en las próximas lecciones (`fmt::Write`, iteradores,
`Option`, `Result`, aritmética checked, etc.). Para lograrlo necesitamos
linkear `libcore.rlib` y `libcompiler_builtins.rlib` desde el sysroot
de rustup, eliminar el workaround `-C debug-assertions=off` que veníamos
arrastrando desde L06, y habilitar FP/SIMD en EL1 — porque `core` usa
internamente instrucciones NEON que están deshabilitadas por defecto
en ARMv8-A.

Archivos:
[boot.S](../iterations/08-rust-core-support/boot.S),
[kmain.rs](../iterations/08-rust-core-support/kmain.rs),
[linker.ld](../iterations/08-rust-core-support/linker.ld),
[Makefile](../iterations/08-rust-core-support/Makefile).

---

## 1. Qué cambia respecto de L07

- **Makefile**: se eliminó `-C debug-assertions=off` de `RUSTCFLAGS`.
  Se agregaron tres variables nuevas para localizar y linkear las
  bibliotecas precompiladas de Rust:
  ```make
  RUSTLIB := $(shell $(RUSTC) --print sysroot)/lib/rustlib/aarch64-unknown-none/lib
  LIBCORE := $(wildcard $(RUSTLIB)/libcore-*.rlib)
  LIBCB   := $(wildcard $(RUSTLIB)/libcompiler_builtins-*.rlib)
  ```
  La regla de link pasa a ser:
  ```make
  $(LD) $(LDFLAGS) -o $@ boot.o kmain.o $(LIBCORE) $(LIBCB)
  ```

- **boot.S**: se agrega habilitación de FP/SIMD antes del setup del
  stack pointer.

- **kmain.rs** y **linker.ld**: sin cambios.

## 2. Por qué linkear `libcore.rlib`

En L06 usamos `-C debug-assertions=off` como workaround para evitar
errores de "undefined symbol: `core::panicking::panic_fmt`". Esos
símbolos vienen de funciones internas de `core` que no se copian
(monomorfizan) dentro de nuestro `kmain.o` — quedan como referencias
externas esperando resolverse en el paso de link.

La solución definitiva es darle al linker acceso a esas funciones,
linkeando las bibliotecas precompiladas que rustup distribuye para
nuestro target `aarch64-unknown-none`:

- **`libcore-*.rlib`**: la biblioteca estándar `core` de Rust. Contiene
  `fmt`, `ptr`, `slice`, `iter`, `panic`, y todo lo que existe en
  `#![no_std]` sin allocator.
- **`libcompiler_builtins-*.rlib`**: funciones auxiliares que LLVM
  espera encontrar (equivalente a `libgcc` en el mundo C). Incluye
  implementaciones de `memcpy`, `memset`, operaciones de enteros
  grandes, etc.

Ambas viven en el sysroot de rustup, bajo
`lib/rustlib/aarch64-unknown-none/lib/`. El Makefile las localiza
automáticamente con `$(RUSTC) --print sysroot` y `wildcard`.

Con esto, ya no necesitamos `-C debug-assertions=off`. Las
precondition checks de `write_volatile` (y cualquier otra función de
`core`) ahora tienen acceso a `panic_fmt` y `panic_nounwind_fmt` para
reportar errores si alguna vez fallan.

## 3. El bug: instrucciones NEON en `core`

**NEON** (también llamado "Advanced SIMD") es la extensión SIMD de ARM.
Permite operar sobre múltiples datos en paralelo usando registros de
128 bits (`v0`–`v31`). Es el equivalente a SSE/AVX en x86. En ARMv8-A,
NEON comparte los registros físicos con la unidad de punto flotante —
por eso el mismo bit de control (CPACR_EL1.FPEN) habilita tanto FP
como NEON. Ref: [ARM NEON Programmer's Guide](https://developer.arm.com/documentation/den0018/latest/).

Al sacar `-C debug-assertions=off` y linkear `libcore`, el kernel dejó
de imprimir. La cadena de llamadas es:

```
putc → write_volatile → precondition_check → is_aligned_to
```

`is_aligned_to` verifica que el alignment sea potencia de dos usando
`count_ones() == 1`. A `opt-level=0`, LLVM implementa `count_ones`
(popcount) con instrucciones NEON:

```asm
fmov    d0, x1          // mover entero a registro SIMD (d0 = vista 64-bit de v0)
cnt     v0.8b, v0.8b    // contar bits encendidos por cada byte del vector
addv    b0, v0.8b       // sumar horizontalmente los 8 bytes → total popcount
```

LLVM usa NEON acá no por paralelismo, sino porque `cnt` es la forma
más eficiente de hacer popcount en AArch64 — no existe una instrucción
escalar equivalente.

En ARMv8-A, el acceso a FP/SIMD (y por tanto NEON) está **deshabilitado
por defecto**. Si el código ejecuta una instrucción NEON sin habilitar
el acceso, el CPU genera un trap de excepción. Sin una vector table
configurada, ese trap cuelga el kernel.

## 4. La solución: habilitar FP/SIMD en EL1

QEMU `virt` con `-kernel` arranca nuestro código en **EL1** (Exception
Level 1 — kernel mode). El registro que controla el acceso a FP/SIMD
desde EL1 es **CPACR_EL1** (Architectural Feature Access Control
Register), campo **FPEN** en los bits 21:20:

| FPEN | Efecto |
|------|--------|
| 0b00 | FP/SIMD trapeado desde EL0 y EL1 |
| 0b01 | FP/SIMD trapeado desde EL0, permitido desde EL1 |
| 0b11 | FP/SIMD permitido desde EL0 y EL1 |

Seteamos FPEN = 0b11 al inicio de `_start`:

```asm
mrs     x0, cpacr_el1
orr     x0, x0, #(3 << 20)
msr     cpacr_el1, x0
isb
```

El `isb` (Instruction Synchronization Barrier) asegura que el cambio
de configuración sea visible antes de que se ejecute cualquier
instrucción posterior.

**Nota sobre CPTR_EL2**: inicialmente intentamos limpiar
`CPTR_EL2.TFP` (bit 10), que es el registro que controla FP/SIMD
desde EL2. Pero como QEMU arranca en EL1, acceder a un registro de
EL2 desde EL1 causa un trap de instrucción indefinida — empeorando el
problema en vez de resolverlo.

## 5. Lo que queda preparado para L09

- ✅ `core` de Rust completamente disponible, sin workarounds.
- ✅ FP/SIMD habilitado — el kernel puede usar cualquier función de
  `core` que internamente requiera NEON.
- ✅ Debug assertions activas — si `core` detecta un invariante
  violado, va a hacer panic (que nuestro `panic_handler` captura con
  `loop {}`).
- ⚠️ El ELF creció de ~700 bytes a ~212 KB (130 KB `.text`, 59 KB
  `.rodata`, 21 KB `.eh_frame`). La sección `.eh_frame` es metadata
  de unwinding que no usamos; se puede descartar con `/DISCARD/` en
  el linker script en una lección futura.
- L09: implementar `println!` usando `core::fmt::Write`.

---

## 6. Referencias consultadas

- **ARMv8-A Architecture Reference Manual** — CPACR_EL1 (D13.2.32),
  CPTR_EL2 (D13.2.35), campo FPEN.
  https://developer.arm.com/documentation/ddi0487/latest/

- **ARM Cortex-A Series Programmer's Guide for ARMv8-A** — Chapter 3:
  ARMv8-A Exception Model, Exception Levels.
  https://developer.arm.com/documentation/den0024/latest/

- **Rust `core` library documentation** — todo lo disponible en
  `#![no_std]` sin allocator.
  https://doc.rust-lang.org/core/

- **rustc codegen options — `-C debug-assertions`** — qué activa y
  desactiva este flag.
  https://doc.rust-lang.org/rustc/codegen-options/index.html#debug-assertions
