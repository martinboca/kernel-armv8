# Lección 07 — `puts` en Rust

**Objetivo**: portar `puts` de assembler a Rust. Después de esta
lección, `boot.S` contiene solo `_start` (startup code) y toda la
lógica del kernel vive en `kmain.rs`.

Archivos:
[boot.S](../iterations/07-puts-rust/boot.S),
[kmain.rs](../iterations/07-puts-rust/kmain.rs),
[linker.ld](../iterations/07-puts-rust/linker.ld),
[Makefile](../iterations/07-puts-rust/Makefile).

---

## 1. Qué cambia respecto de L06

- `puts` se elimina de `boot.S` y aparece en `kmain.rs`.
- La firma cambia: en asm era `puts(x0 = *const u8)` null-terminated;
  en Rust es `fn puts(s: &[u8])` — slice con longitud explícita.
- `putc` y `puts` dejan de ser símbolos exportados. Pasan a ser
  funciones privadas del crate, sin `#[no_mangle]` ni `extern "C"`.
- El string literal pierde su `\0` final: `b"Martin Bocanegra\n"`.
  Como el slice lleva la longitud en el tipo, el terminator ya no
  hace falta.
- `boot.S` queda con ~20 líneas: solo `_start` y sus tres pasos
  (setear SP, zero `.bss`, `b kmain`).

## 2. Por qué `&[u8]` en vez de `*const u8`

Podemos aprovechar que el slice lleva la longitud en el tipo, así que el terminator ya no hace falta.

Puntos a cubrir:
- En C, la convención de null-terminator viene de que los strings no
  llevan longitud; hay que "descubrirla" recorriendo hasta encontrar
  el `\0`. Eso es la causa histórica de muchos bugs de buffer
  overflow.
- En Rust, `&[u8]` es un **fat pointer**: dos words, puntero +
  longitud. El chequeo de bound lo puede hacer el compilador o el
  runtime, y no dependés de que el buffer tenga un byte centinela.

## 3. Símbolos globales vs locales

Antes de L07, `puts` tenía `.global puts` en asm y `putc` tenía
`#[no_mangle] pub extern "C"` en Rust. Los dos eran símbolos globales
del ELF final.

Ahora, ni `puts` ni `putc` son globales. Rustc los trata como
funciones internas del crate, visibles solo a otras funciones del
mismo `.o`. Se puede verificar con:

```sh
llvm-objdump -t kernel.elf | grep -E 'puts|putc|kmain|_start'
```

*(pegar el output real cuando lo corras, comentar qué letras
aparecen — `g` para global, `l` para local — y qué implica eso en
cuanto a qué optimizaciones el compilador está habilitado a hacer).*

La consecuencia práctica: a opt-level ≥ 2, rustc puede inlinear
`putc` dentro de `puts` (y quizás `puts` dentro de `kmain`) porque
sabe que nadie externo las llama. A opt-level=0 el inlining no
ocurre, pero la oportunidad está ahí para el día que subamos el
nivel.

## 4. Lo que queda preparado para L08

- ✅ `boot.S` solo contiene `_start`.
- ✅ Todo el I/O vive en Rust.
- ✅ `puts(&[u8])` encaja directamente con el output de
  `str::as_bytes()`, así que implementar `core::fmt::Write` en L08
  es casi gratis.
- ⚠️ Seguimos dependiendo de `-C debug-assertions=off`.
  Esto probablemente nos traiga problemas en nuevas iteraciones
  porque `core::fmt::Write` usa `core::fmt::num` que usa `memcpy` del
  `compiler_builtins`. Vamos a tener que decidir entre linkear
  `libcore.rlib` + `libcompiler_builtins.rlib` explícitamente, o
  pasarnos a Cargo.

