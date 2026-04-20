#![no_std]
#![no_main]

use core::arch::asm;
use core::panic::PanicInfo;
use core::ptr::{addr_of, write_volatile};

const UART0_DR: *mut u8 = 0x0900_0000 as *mut u8;
fn putc(byte: u8) {
    unsafe {
        write_volatile(UART0_DR, byte);
    }
}

struct Uart;
impl core::fmt::Write for Uart {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for &byte in s.as_bytes() {
            putc(byte);
        }
        Ok(())
    }
}

macro_rules! print {
    ($($arg:tt)*) => {
        <Uart as core::fmt::Write>::write_fmt(&mut Uart, format_args!($($arg)*)).unwrap()
    };
}
macro_rules! println {
    () => { print!("\n") };
    ($($arg:tt)*) => { print!("{}\n", format_args!($($arg)*)) };
}

fn read_el() -> u64 {
    let el: u64;
    unsafe {
        asm!("mrs {0}, CurrentEL", out(reg) el);
    }
    // CurrentEL almacena el EL en los bits 3:2.
    el >> 2
}

// Símbolo del linker script: dirección tope del stack.
extern "C" {
    static stack_top: u8;
}

/// Corre en EL2. Configura los system registers para EL1 y ejecuta
/// eret para transicionar a kmain en EL1.
#[no_mangle]
pub extern "C" fn _start_rust() -> ! {
    let el = read_el();
    if el != 2 {
        println!("ERROR: se esperaba EL2, estamos en EL{}", el);
        loop {}
    }

    println!("Arrancando en EL{}, transicionando a EL1...", el);

    unsafe {
        asm!(
            // -------------------------------------------------------
            // HCR_EL2 — Hypervisor Configuration Register
            //
            // Bit 31 (RW): Execution State de EL1.
            //   1 = EL1 ejecuta AArch64.
            //   0 = EL1 ejecuta AArch32.
            // Resto en 0: sin traps de virtualización, sin routing
            // de interrupciones a EL2.
            // -------------------------------------------------------
            "msr hcr_el2, {hcr}",

            // -------------------------------------------------------
            // SCTLR_EL1 — System Control Register para EL1
            //
            // Estado inicial de EL1. Valor 0x30D00800:
            //   - Bits RES1 (29, 28, 23, 22, 20, 11) seteados a 1
            //     (obligatorio por spec ARMv8-A).
            //   - MMU deshabilitada (bit 0 = 0).
            //   - I-cache y D-cache deshabilitadas (bits 2, 12 = 0).
            //   - Alignment check deshabilitado (bit 1 = 0).
            // -------------------------------------------------------
            "msr sctlr_el1, {sctlr}",

            // -------------------------------------------------------
            // SPSR_EL2 — Saved Program Status Register para EL2
            //
            // PSTATE que va a tener el CPU después del eret.
            // Valor 0x3C5 = 0b_0011_1100_0101:
            //
            //   Bits 9:6 = DAIF = 0b1111:
            //     D (9): Debug exceptions enmascaradas.
            //     A (8): SError enmascarado.
            //     I (7): IRQ enmascarado.
            //     F (6): FIQ enmascarado.
            //
            //   Bits 3:0 = M = 0b0101 = EL1h:
            //     Entrar a EL1 usando SP_EL1 (no SP_EL0).
            // -------------------------------------------------------
            "msr spsr_el2, {spsr}",

            // -------------------------------------------------------
            // ELR_EL2 — Exception Link Register para EL2
            //
            // Dirección de destino del eret. Apunta a kmain: la
            // primera función que corre en EL1.
            // -------------------------------------------------------
            "msr elr_el2, {elr}",

            // -------------------------------------------------------
            // SP_EL1 — Stack Pointer de EL1
            //
            // Stack para kmain en EL1. Apunta a stack_top (definido
            // en linker.ld). El SP de EL2 se descarta.
            // -------------------------------------------------------
            "msr sp_el1, {sp}",

            // -------------------------------------------------------
            // ERET — Exception Return
            //
            //   PC     ← ELR_EL2   (salta a kmain)
            //   PSTATE ← SPSR_EL2  (modo EL1h, interrupts masked)
            //   SP     ← SP_EL1    (stack fresco)
            //
            // El CPU pasa a correr en EL1. No retorna.
            // -------------------------------------------------------
            "eret",

            hcr   = in(reg) 1_u64 << 31,              // HCR_EL2.RW = 1
            sctlr = in(reg) 0x30D00800_u64,            // RES1 bits
            spsr  = in(reg) 0x3C5_u64,                 // DAIF=1111, M=EL1h
            elr   = in(reg) kmain as *const () as u64,
            sp    = in(reg) addr_of!(stack_top) as u64,
            options(noreturn),
        );
    }
}

#[no_mangle]
pub extern "C" fn kmain() -> ! {
    let el = read_el();
    println!("Corriendo en EL{}", el);
    println!("Martín Bocanegra");
    loop {}
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    println!("¡PANIC!");
    loop {}
}
