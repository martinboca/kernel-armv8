//! kmain.rs — Lección 05: primer código Rust en el kernel.
//!
//! kmain() pasa a ser una función de Rust. La llama `_start` (asm) con
//! un `b kmain`, que encaja con el contrato `-> !` (nunca retorna).
//!
//! Por ahora seguimos usando `puts()` de boot.S — la reimplementación
//! en Rust queda para L06. Así esta lección se concentra en una sola
//! cosa: lograr que rustc emita un objeto que el linker pueda mezclar
//! con boot.o, y que el control de ejecución cruce de asm a Rust.

#![no_std]
#![no_main]

use core::panic::PanicInfo;

// puts() lo provee boot.S. La convención "C" es el contrato de ABI más
// simple y portable; AAPCS64 coincide con lo que rustc usa para
// `extern "C"` en aarch64, así que el primer argumento llega en x0.
extern "C" {
    fn puts(s: *const u8);
}

#[no_mangle]
pub extern "C" fn kmain() -> ! {
    // Byte string '\0'-terminada. Rust la coloca en .rodata; por eso
    // el linker script de esta lección agrega esa sección.
    let msg: &[u8] = b"Martin Bocanegra\n\0";
    unsafe {
        puts(msg.as_ptr());
    }
    loop {}
}

// Todo crate `no_std` que pueda hacer panic necesita un panic handler.
// El nuestro es el mínimo posible: colgar el core para siempre.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}
