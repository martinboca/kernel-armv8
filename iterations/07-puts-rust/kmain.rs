//! kmain.rs — Lección 07: puts en Rust

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use core::ptr::write_volatile;

const UART0_DR: *mut u8 = 0x0900_0000 as *mut u8;

fn putc(byte: u8) {
    unsafe {
        write_volatile(UART0_DR, byte);
    }
}

fn puts(s: &[u8]) {
    for &byte in s {
        putc(byte);
    }
}

#[no_mangle]
pub extern "C" fn kmain() -> ! {
    let msg: &[u8] = b"Martin Bocanegra\n";
    puts(msg);
    loop {}
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}
