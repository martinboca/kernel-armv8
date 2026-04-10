# Kernel ARMv8-A

Repositorio donde voy construyendo, paso a paso, un kernel para la
arquitectura **ARMv8-A**, emulado con **QEMU**. El objetivo es entender
la arquitectura en profundidad: desde imprimir bytes por un UART en assembler
hasta, eventualmente, arrancar Rust sobre una MMU configurada a mano.

## Estructura

| Lección | Archivo | Descripción |
|---|---|---|
| 01 | [docs/01-hello-world.md](docs/01-hello-world.md) | Bare-metal assembler que imprime `"Martin Bocanegra"` por el UART PL011 de QEMU `virt`. |
| 02 | [docs/02-functions.md](docs/02-functions.md) | Refactor a funciones `puts`/`putc`. Introduce `bl`/`ret`, calling convention AAPCS64, stack y prólogo/epílogo. |
| 03 | [docs/03-kmain.md](docs/03-kmain.md) | Separa `_start` (startup code) de `kmain` (kernel entry point). `b kmain` sin link porque `kmain` nunca retorna. |
| 04 | [docs/04-bss.md](docs/04-bss.md) | Inicialización de `.bss` en el startup. Introduce el zero register `xzr`, loop de memset en asm, y `SHT_NOBITS` en ELF. Prerrequisito para Rust. |
| 05 | [docs/05-hello-rust.md](docs/05-hello-rust.md) | Primer código Rust en el kernel: `kmain` pasa a un crate `no_std`/`no_main`, linkeado contra `boot.o`. Introduce `extern "C"`, `#[no_mangle]`, `#[panic_handler]` y `.rodata`. |
| 06 | [docs/06-putc-rust.md](docs/06-putc-rust.md) | `putc` pasa a Rust con `core::ptr::write_volatile`. Introduce MMIO, por qué `volatile` es necesario, y `-C debug-assertions=off` para evitar las precondition checks de `core`. |
| 07 | [docs/07-puts-rust.md](docs/07-puts-rust.md) | `puts` pasa a Rust, iterando un `&[u8]`. `boot.S` queda con solo `_start`. `puts`/`putc` dejan de ser símbolos globales y pasan a ser funciones Rust privadas del crate. |

## Archivos del kernel actual

- [boot.S](boot.S) — startup code y helpers I/O (`puts`/`putc`) en assembler.
- [kmain.rs](kmain.rs) — entry point del kernel en Rust (`no_std`/`no_main`).
- [linker.ld](linker.ld) — linker script: `.text`, `.rodata`, `.bss`, stack.
- [Makefile](Makefile) — build y run con QEMU.

## Historial de iteraciones

En [iterations/](iterations/) se guarda una copia congelada del estado del
proyecto al final de cada lección, junto con su documento explicativo,
para poder seguir la evolución del proyecto paso a paso.

- [iterations/01-hello-world/](iterations/01-hello-world/) — hello en assembly.
- [iterations/02-functions/](iterations/02-functions/) — funciones en assembly.
- [iterations/03-kmain/](iterations/03-kmain/) — kmain en assembly.
- [iterations/04-bss/](iterations/04-bss/) — inicializar bss en assembly.
- [iterations/05-hello-rust/](iterations/05-hello-rust/) — hello en Rust.
- [iterations/06-putc-rust/](iterations/06-putc-rust/) — putc en Rust con MMIO.
- [iterations/07-puts-rust/](iterations/07-puts-rust/) — puts en Rust, boot.S con solo `_start`.

## Toolchain

Todo corre en macOS Apple Silicon con herramientas de Homebrew:

- **clang** como assembler cross, usando
  `--target=aarch64-none-elf`.
- **lld** como linker.
- **qemu** (`qemu-system-aarch64`) como emulador.
- **rustc** (vía `rustup`) con el target `aarch64-unknown-none` instalado
  (`rustup target add aarch64-unknown-none`).

## Build & Run

```sh
make          # compila kernel.elf
make run      # arranca QEMU; imprime el mensaje y entra en wfe loop
make dump     # desensambla kernel.elf (sanity check)
make clean
```

Para salir de QEMU (`-nographic`): **Ctrl-A** seguido de **X**.

## Decisiones de diseño

- **Máquina QEMU**: `virt`. Es un board sintético pensado específicamente
  para virtualización y desarrollo; su memory map está documentado y es
  estable entre versiones de QEMU.
- **CPU**: `cortex-a72`. Un core ARMv8-A bien conocido (Raspberry Pi 4).
- **Load address**: `0x40080000`. Convención heredada del protocolo de boot
  de Linux arm64: RAM comienza en `0x40000000` en `virt`, y el kernel se
  carga 512 KiB más arriba para dejar espacio al device tree y otras
  estructuras.
- **Formato ejecutable**: ELF. QEMU con `-kernel <archivo.elf>` respeta las
  direcciones de carga y el entry point del ELF.

## Referencias consultadas

Las specs y recursos que fui usando los dejo acá para referencia
futura. Cada lección además tiene sus propias referencias específicas.

### Arquitectura ARMv8-A
- **Arm Architecture Reference Manual for A-profile (ARM ARM)** — el
  documento fundacional. Define todo el ISA y el modelo de excepciones.
  https://developer.arm.com/documentation/ddi0487/latest/
- **Arm A64 Instruction Set Architecture (quick reference)** — más liviano
  que el ARM ARM, útil para buscar instrucciones específicas.
  https://developer.arm.com/documentation/ddi0596/latest/
- **Learn the architecture** — guías introductorias oficiales de Arm.
  https://developer.arm.com/documentation#cf[navigationhierarchiescontenttype]=Learn%20the%20architecture

### Periféricos
- **PrimeCell UART (PL011) Technical Reference Manual** — ARM DDI 0183.
  Describe todos los registros del UART emulado por QEMU en `virt`.
  https://developer.arm.com/documentation/ddi0183/latest/

### QEMU
- **QEMU 'virt' generic virtual platform** — memory map, dispositivos,
  comportamiento de `-kernel`.
  https://qemu-project.gitlab.io/qemu/system/arm/virt.html
- **QEMU invocation / `-machine` / `-nographic`** —
  https://qemu-project.gitlab.io/qemu/system/invocation.html

### Protocolo de boot
- **Linux arm64 booting.rst** — referencia del load address `0x40080000`
  y el contrato de entrada al kernel en arm64.
  https://docs.kernel.org/arch/arm64/booting.html
