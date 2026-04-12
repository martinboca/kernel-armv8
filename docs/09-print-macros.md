# Lección 09 — Macros `print!` y `println!`

**Objetivo**: dejar de escribir output byte por byte con `putc`
y tener acceso a todo el motor de formateo de Rust (`{}`, `{:?}`,
`{:#x}`, etc.) de la misma forma que hace `println!` de `std`. Para
lograrlo implementamos `core::fmt::Write` sobre el UART y envolvemos
`core::fmt::Write::write_fmt` en dos macros propias.

Archivos:
[boot.S](../iterations/09-print-macros/boot.S),
[kmain.rs](../iterations/09-print-macros/kmain.rs),
[linker.ld](../iterations/09-print-macros/linker.ld),
[Makefile](../iterations/09-print-macros/Makefile).

---

## 1. Por qué esta lección es corta

No agregamos capacidades nuevas al kernel: seguimos escribiendo los
mismos bytes al mismo registro MMIO que en L06. Lo que cambia es la
ergonomía — ahora escribimos `println!("EL{}", el)` en vez de manejar
buffers y conversiones a mano.

Es una lección preparatoria. A partir de L10 vamos a tocar MMU,
scheduler y userspace, y cada una de esas lecciones necesita imprimir
estado interno para debug. Tener `println!` antes de entrar a ese
territorio nos ahorra tiempo.

## 2. No existe `println!` en `core`

`std::println!` no se puede usar en `no_std`: depende de `std`, que
necesita un OS debajo (stdout, locks, file descriptors).

El motor de formateo — parsing de `"{:08x}"`, conversión de enteros,
padding, alineamiento — vive en `core::fmt`. Lo que `std` agrega
arriba es:

1. La macro `println!`
2. Un destino global (stdout)
3. Locking alrededor de ese destino

"No reimplementar `println!`" significa apoyarse en `core::fmt::Write`
y `format_args!`, y escribir un wrapper que les ponga un destino.

## 3. El `impl Write for Uart`

`core::fmt::Write` es el trait para destinos de texto formateado.
Tiene un método obligatorio:

```rust
fn write_str(&mut self, s: &str) -> core::fmt::Result;
```

Definimos una struct `Uart` sin campos (la dirección del UART vive en
la constante `UART0_DR`) y le implementamos el trait:

```rust
struct Uart;

impl core::fmt::Write for Uart {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for &byte in s.as_bytes() {
            putc(byte);
        }
        Ok(())
    }
}
```

Devolvemos `Ok(())` siempre: el UART no tiene backpressure ni retorna
errores, así que las macros de arriba pueden hacer `.unwrap()`.

Con este `impl`, `core` provee el método
`write_fmt(&mut self, args: fmt::Arguments<'_>) -> fmt::Result` como
default method del trait. Recorre los `Arguments` producidos por
`format_args!` emitiendo cada chunk por `write_str`. El parsing del
format string y la conversión de los tipos estándar los hace `core`.

## 4. Las macros

```rust
macro_rules! print {
    ($($arg:tt)*) => {
        <Uart as core::fmt::Write>::write_fmt(&mut Uart, format_args!($($arg)*)).unwrap()
    };
}

macro_rules! println {
    () => { print!("\n") };
    ($($arg:tt)*) => { print!("{}\n", format_args!($($arg)*)) };
}
```

Dos puntos:

- **`format_args!`** construye un `fmt::Arguments<'_>` en el stack sin
  alocar, por eso funciona en `no_std` sin allocator.

- **Fully qualified syntax** `<Uart as core::fmt::Write>::write_fmt(...)`:
  lo usamos en vez de `Uart.write_fmt(...)` para que la macro no
  requiera que el llamador tenga `use core::fmt::Write;` en scope.

## 5. El nuevo `kmain`

Antes (L08):

```rust
let el = read_el();
puts(b"Iniciando en EL");
print_hex(el);
putc(b'\n');
puts(b"Martin Bocanegra\n");
```

Ahora:

```rust
let el = read_el();
println!("Iniciando en EL{}", el);
println!("Martín Bocanegra");
```

`puts` y `print_hex` desaparecen. Queda `putc` (usada por
`Uart::write_str`) y las macros.

Como `core::fmt` maneja strings UTF-8, podemos escribir `Martín` con
acento: `format_args!` entrega los bytes UTF-8 a `write_str` y el
UART los recibe sin modificaciones.

## 6. Verificación

```sh
make clean && make && make run
```

Output:
```
Iniciando en EL1
Martín Bocanegra
```

## 7. Lo que queda preparado para L10

- ✅ Todo el formato de Rust (`{}`, `{:?}`, `{:#x}`, `{:08}`, etc.)
  disponible vía `println!`.
- ⚠️ `Uart` es un singleton sin locking. Cuando lleguemos a SMP o
  interrupciones concurrentes vamos a necesitar envolverlo en un
  spinlock.
- Siguiente: bajar de EL2 a EL1, forzando QEMU a arrancar en EL2 con
  `-machine virt,virtualization=on`.

---

## 8. Referencias consultadas

- **`core::fmt::Write` trait** — contrato del trait y default methods.
  https://doc.rust-lang.org/core/fmt/trait.Write.html

- **`core::format_args!` macro** — cómo Rust construye
  `fmt::Arguments<'_>` sin allocator.
  https://doc.rust-lang.org/core/macro.format_args.html

- **The Embedonomicon — A `no_std` Rust Environment** — patrón de
  `print!`/`println!` propias en embedded Rust.
  https://docs.rust-embedded.org/embedonomicon/smallest-no-std.html
