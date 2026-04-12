#![no_std]
#![no_main]

use core::arch::asm;
use core::panic::PanicInfo;
use core::ptr::write_volatile;

// Función base para escribir en UART
const UART0_DR: *mut u8 = 0x0900_0000 as *mut u8;
fn putc(byte: u8) {
    unsafe {
        write_volatile(UART0_DR, byte);
    }
}

// Implementación de trait Write para UART
struct Uart;
impl core::fmt::Write for Uart {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for &byte in s.as_bytes() {
            putc(byte);
        }
        Ok(())
    }
}

// Macros print y println
macro_rules! print {
    ($($arg:tt)*) => {
        <Uart as core::fmt::Write>::write_fmt(&mut Uart, format_args!($($arg)*)).unwrap()
    };
}
macro_rules! println {
    () => { print!("\n") };
    ($($arg:tt)*) => { print!("{}\n", format_args!($($arg)*)) };
}
// ------------------------------------------------------------------

fn read_el() -> u64 {
    let el: u64;
    unsafe {
        asm!("mrs {0}, CurrentEL", out(reg) el);
    }
    el >> 2
}

#[no_mangle]
pub extern "C" fn kmain() -> ! {
    let el = read_el();
    println!("Iniciando en EL{}", el);
    println!("Martín Bocanegra");
    loop {}
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}
