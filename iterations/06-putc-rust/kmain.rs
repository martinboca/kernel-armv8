//! kmain.rs — Lección 06: putc pasa a Rust con MMIO volátil.
//!
//! Nueva pieza en este crate: `putc`, que escribe un byte al UART PL011
//! usando `core::ptr::write_volatile`. Es la primera vez que el código
//! Rust toca hardware directo en lugar de delegar en asm.
//!
//! `puts` sigue viviendo en boot.S por una lección más. Su `bl putc`
//! ahora resuelve, vía linker, contra esta función de Rust en lugar
//! de contra el `putc` local que tenía boot.S hasta L05. El cruce de
//! ABI funciona en ambas direcciones (asm→Rust acá, Rust→asm en L05)
//! gracias a que ambos lados respetan AAPCS64 / `extern "C"`.

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use core::ptr::write_volatile;

// Dirección base del data register (UARTDR) del UART PL011 en QEMU virt.
// Mismo valor que la `.equ UART0_DR` que tenía boot.S hasta L05.
const UART0_DR: *mut u8 = 0x0900_0000 as *mut u8;

// puts() todavía vive en boot.S; lo importamos por FFI igual que en L05.
extern "C" {
    fn puts(s: *const u8);
}

// putc() pasa a vivir acá. boot.S la sigue llamando con `bl putc`, y el
// linker resuelve esa referencia cruzada contra este símbolo.
//
// El argumento llega en w0 / x0 (primer arg AAPCS64). Rust lo recibe
// como `u8`. Escribimos ese byte al data register del UART con
// write_volatile, que es la primitiva de Rust para acceso a MMIO.
#[no_mangle]
pub extern "C" fn putc(byte: u8) {
    unsafe {
        write_volatile(UART0_DR, byte);
    }
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
