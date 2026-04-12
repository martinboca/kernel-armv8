# Lección 09 — Macros `print!` y `println!`

**Objetivo**: dejar de escribir output byte por byte con `putc`
y tener acceso a todo el motor de formateo de Rust (`{}`, `{:?}`,
`{:#x}`, etc.) de la misma forma que hace `println!` de `std`. Para
lograrlo implementamos `core::fmt::Write` sobre el UART y envolvimos
`core::write_fmt` en dos macros propias.

---

## Qué hicimos

1. **Struct `Uart` + `impl core::fmt::Write`**: una struct
   que representa el UART como destino de escritura. Su `write_str`
   itera sobre los bytes del `&str` y los manda por `putc`.
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

2. **Macros `print!` y `println!`**: wrappers mínimos que delegan en
   `core::fmt::Write::write_fmt` con `format_args!`:
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

3. **`kmain` simplificado**: desaparece `puts`, `print_hex` y el
   pegado manual del newline. Ahora es literal:
   ```rust
   println!("Iniciando en EL{}", el);
   println!("Martín Bocanegra");
   ```

## Por qué reimplementamos `println!`

`std::println!` depende de `std`, que no tenemos. Pero todo el motor
de formateo vive en **`core::fmt`**, que sí tenemos gracias al linkeo
de `libcore.rlib` en L08. Nuestras macros son un wrapper sobre
`core::fmt::Write::write_fmt` — el parsing de `"{}"`, la conversión de
enteros, el padding, todo lo hace `core`.

## Verificación

```sh
make clean && make && make run
```

Output:
```
Iniciando en EL1
Martín Bocanegra
```

## Lo que queda preparado para L10

- ✅ Debug output ergonómico con todo el formato de Rust.
- ⚠️ `Uart` no tiene locking — cuando lleguemos a
  SMP o interrupciones concurrentes vamos a necesitar envolverlo en
  un lock.
- Siguiente: bajar de EL2 a EL1 . Iniciando QEMU a EL2 con
  `-machine virt,virtualization=on` y bajando a EL1.
