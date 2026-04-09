# Kernel ARMv8-A — Proyecto de aprendizaje

Repositorio pedagógico donde voy construyendo, paso a paso, un kernel para la
arquitectura **ARMv8-A**, emulado con **QEMU**. El objetivo no es construir un
producto utilizable, sino entender la arquitectura en profundidad: desde
imprimir bytes por un UART en assembler hasta, eventualmente, arrancar Rust
sobre una MMU configurada a mano.

## Estructura

| Lección | Archivo | Descripción |
|---|---|---|
| 01 | [docs/01-hello-world.md](docs/01-hello-world.md) | Bare-metal assembler que imprime `"Martin Bocanegra"` por el UART PL011 de QEMU `virt`. |
| 02 | [docs/02-functions.md](docs/02-functions.md) | Refactor a funciones `puts`/`putc`. Introduce `bl`/`ret`, calling convention AAPCS64, stack y prólogo/epílogo. |
| 03 | [docs/03-kmain.md](docs/03-kmain.md) | Separa `_start` (startup code) de `kmain` (kernel entry point). `b kmain` sin link porque `kmain` nunca retorna. |
| 04 | [docs/04-bss.md](docs/04-bss.md) | Inicialización de `.bss` en el startup. Introduce el zero register `xzr`, loop de memset en asm, y `SHT_NOBITS` en ELF. Prerrequisito para Rust. |

## Archivos del kernel actual

- [boot.S](boot.S) — código de arranque en assembler ARMv8-A.
- [linker.ld](linker.ld) — linker script que ubica el código en `0x40080000`.
- [Makefile](Makefile) — build y run con QEMU.

## Historial de iteraciones

En [iterations/](iterations/) se guarda una copia congelada del estado del
proyecto al final de cada lección, junto con su documento explicativo,
para poder seguir la evolución del proyecto paso a paso.

- [iterations/01-hello-world/](iterations/01-hello-world/) — estado al final
  de la lección 01.
- [iterations/02-functions/](iterations/02-functions/) — estado al final
  de la lección 02.
- [iterations/03-kmain/](iterations/03-kmain/) — estado al final
  de la lección 03.
- [iterations/04-bss/](iterations/04-bss/) — estado al final
  de la lección 04.

## Toolchain

Todo corre en macOS Apple Silicon con herramientas de Homebrew:

- **clang** (Apple clang alcanza) como assembler cross, usando
  `--target=aarch64-none-elf`.
- **lld** (`ld.lld`) como linker. El `ld` de Apple solo produce Mach-O; para
  generar un ELF bare-metal necesitamos lld.
- **qemu** (`qemu-system-aarch64`) como emulador.

No hace falta un toolchain dedicado tipo `aarch64-elf-gcc`: clang puede
emitir código para cualquier target ARM de una sola instalación, y lld se
encarga del linking ELF.

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
  estable entre versiones de QEMU. No emula hardware "real" con cuirks.
- **CPU**: `cortex-a72`. Un core ARMv8-A bien conocido (Raspberry Pi 4).
- **Load address**: `0x40080000`. Convención heredada del protocolo de boot
  de Linux arm64: RAM comienza en `0x40000000` en `virt`, y el kernel se
  carga 512 KiB más arriba para dejar espacio al device tree y otras
  estructuras.
- **Formato ejecutable**: ELF. QEMU con `-kernel <archivo.elf>` respeta las
  direcciones de carga y el entry point del ELF.

## Referencias consultadas

Las specs y recursos que fui usando los voy acumulando acá para referencia
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
