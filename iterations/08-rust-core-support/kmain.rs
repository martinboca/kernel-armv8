#![no_std]
#![no_main]

use core::arch::asm;
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

fn read_el() -> u64 {
    let el: u64;
    unsafe {
        asm!("mrs {0}, CurrentEL", out(reg) el);
    }
    el >> 2
}

fn print_hex(mut n: u64) {
    if n == 0 {
        putc(b'0');
        return;
    }
    let mut buf = [0u8; 16];
    let mut i = 16;

    while n > 0 {
        i -= 1;
        let digit = (n % 16) as u8;
        buf[i] = if digit < 10 {
            digit + b'0'
        } else {
            digit - 10 + b'a'
        };
        n /= 16;
    }
    puts(&buf[i..]);
}

#[no_mangle]
pub extern "C" fn kmain() -> ! {
    let el = read_el();
    puts(b"Iniciando en EL");
    print_hex(el);
    putc(b'\n');

    let msg: &[u8] = b"Martin Bocanegra\n";
    puts(msg);
    loop {}
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}
