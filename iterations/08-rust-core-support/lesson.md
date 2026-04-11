# Lección 08 — Soporte completo de `core` en Rust

**Objetivo**: tener acceso completo a `core` de Rust para poder usarlo
sin restricciones en las próximas lecciones (`fmt::Write`, iteradores,
`Option`, `Result`, etc.). Para lograrlo necesitamos linkear
`libcore.rlib` y `libcompiler_builtins.rlib` desde el sysroot de
rustup, eliminar el workaround `-C debug-assertions=off` que veníamos
arrastrando desde L06, y habilitar FP/SIMD en EL1 — porque `core` usa
internamente instrucciones NEON que están deshabilitadas por defecto
en ARMv8-A.

---

## Qué cambia respecto de L07

1. **Makefile** — se eliminó `-C debug-assertions=off`. Se linkean
   las bibliotecas precompiladas de Rust:
   ```make
   RUSTLIB := $(shell $(RUSTC) --print sysroot)/lib/rustlib/aarch64-unknown-none/lib
   LIBCORE := $(wildcard $(RUSTLIB)/libcore-*.rlib)
   LIBCB   := $(wildcard $(RUSTLIB)/libcompiler_builtins-*.rlib)
   ```
   Estas `.rlib` proveen todos los símbolos de `core` que `kmain.o`
   referencia externamente (`panic_fmt`, `panic_nounwind_fmt`, `memcpy`,
   etc.).

2. **boot.S** — se agrega habilitación de FP/SIMD al inicio de
   `_start` vía CPACR_EL1.

3. **kmain.rs** — se recupera el Exception Level (EL) actual mediante
   el registro `CurrentEL` y se lo imprime por UART

## El bug de NEON

**NEON** (también llamado "Advanced SIMD") es la extensión SIMD de
ARM: permite operar sobre múltiples datos en paralelo usando registros
de 128 bits (`v0`–`v31`). Es el equivalente a SSE/AVX en x86. En
ARMv8-A, NEON comparte los registros físicos con la unidad de punto
flotante — por eso el mismo bit de control (CPACR_EL1.FPEN) habilita
tanto FP como NEON.

Ref: [ARM NEON Programmer's Guide](https://developer.arm.com/documentation/den0018/latest/).

Sin `-C debug-assertions=off`, `write_volatile` incluye una
precondition check que llama a `is_aligned_to`. A `opt-level=0`,
LLVM implementa el `count_ones()` interno con instrucciones NEON:

```asm
fmov    d0, x1          // mover entero a registro SIMD (d0 = vista 64-bit de v0)
cnt     v0.8b, v0.8b    // contar bits encendidos por cada byte del vector
addv    b0, v0.8b       // sumar horizontalmente los 8 bytes → total popcount
```

LLVM usa NEON acá no por paralelismo, sino porque `cnt` es la forma
más eficiente de hacer popcount en AArch64 — no existe una instrucción
escalar equivalente.

En ARMv8-A, FP/SIMD (y por tanto NEON) está deshabilitado por defecto.
Ejecutar una instrucción NEON sin habilitarlo genera un trap. Sin
vector table configurada, el trap cuelga el kernel.

## La solución: CPACR_EL1.FPEN

QEMU `virt` con `-kernel` arranca en EL1. El registro que controla
FP/SIMD en EL1 es **CPACR_EL1**, campo FPEN (bits 21:20).
Seteamos `0b11` = acceso completo:

```asm
mrs     x0, cpacr_el1
orr     x0, x0, #(3 << 20)
msr     cpacr_el1, x0
isb
```

**Error que cometimos**: primero intentamos limpiar `CPTR_EL2.TFP`
(bit 10), que controla FP/SIMD desde EL2. Pero acceder a un registro
de EL2 desde EL1 también causa un trap — empeorando el problema.


## Lo que queda preparado para L09

- ✅ `core` completo disponible: `fmt::Write`, iteradores, `Option`,
  `Result`, aritmética checked.
- ✅ FP/SIMD habilitado.
- ⚠️ El ELF creció a ~212 KB (21 KB son `.eh_frame` que podemos
  descartar con `/DISCARD/` en el linker script).
- Siguiente: implementar `println!` usando `core::fmt::Write`.
