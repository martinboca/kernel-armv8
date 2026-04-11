# Roadmap del kernel

Documento vivo: estado actual + plan a futuro hacia un kernel funcional
capaz de ejecutar programas en userspace, hacer `fork`/`exec`, y
eventualmente correr sobre hardware real (Xiaomi Poco X3 NFC).

El proyecto avanza por **lecciones**, cada una con su snapshot en
[iterations/](iterations/) y documentación detallada en [docs/](docs/).

---

## Estado actual

### ✅ Completado (L01–L08)

- [x] **L01 — hello world**: arranque en QEMU `virt`, escritura por
  UART PL011 a `0x09000000`. Linker script básico, load address
  `0x40000000`. [docs](docs/01-hello-world.md)
- [x] **L02 — funciones**: `puts`/`putc` con stack, AAPCS64, `stp`/`ldp`.
  [docs](docs/02-functions.md)
- [x] **L03 — kmain**: separación `_start` (startup) / `kmain` (kernel
  entry). Prepara el contrato `fn kmain() -> !` para Rust.
  [docs](docs/03-kmain.md)
- [x] **L04 — bss**: seteo de `.bss` a cero en `_start`. Linker script
  expandido con sección `.bss` y símbolos `bss_start`/`bss_end`.
  [docs](docs/04-bss.md)
- [x] **L05 — hello-rust**: primer Rust. Crate `no_std`/`no_main`,
  target `aarch64-unknown-none`, `rustc --emit=obj` directo sin Cargo.
  `kmain` pasa a Rust, llama a `puts` de asm vía FFI.
  [docs](docs/05-hello-rust.md)
- [x] **L06 — putc en Rust**: `putc` portado a Rust con
  `core::ptr::write_volatile`. Cruce asm→Rust en `puts→putc`.
  [docs](docs/06-putc-rust.md)
- [x] **L07 — puts en Rust**: `puts` también pasa a Rust.
  `boot.S` queda solo con `_start`. [docs](docs/07-puts-rust.md)
- [x] **L08 — soporte completo de `core` + leer CurrentEL**: linkeo de
  `libcore.rlib` + `libcompiler_builtins.rlib`, eliminación del
  workaround `-C debug-assertions=off`, habilitación de FP/SIMD en EL1
  vía CPACR_EL1.FPEN. Lectura de `CurrentEL` con inline asm e
  impresión por UART (confirmamos que QEMU `virt` con `-kernel`
  arranca en EL1 por defecto).
  [docs](docs/08-rust-core-support.md)

### Lo que ya tenemos

- Boot end-to-end: `_start` → setup FP/SIMD → stack → `.bss` zero → `kmain`
- Rust con `core` completo (`fmt`, `iter`, `Option`, `Result`, etc.)
- Inline asm para acceso a system registers
- Output por UART desde Rust
- Conocimiento de en qué Exception Level arrancamos

---

## Próximas lecciones planeadas (L09–L13)

Capa de **arquitectura/fundaciones**: dejar el kernel ejecutándose
en EL1 con capacidad de atrapar excepciones e interrupciones.

- [ ] **L09 — `println!` propio**: implementar `core::fmt::Write` sobre
  el UART. Macro `print!`/`println!` como herramienta de debug
  fundacional.
- [ ] **L10 — Bajar de EL2 a EL1**: forzar QEMU a arrancar en EL2 con
  `-machine virt,virtualization=on`, después configurar HCR_EL2,
  SCTLR_EL1, SPSR_EL2, ELR_EL2 y ejecutar `eret` para caer en EL1.
  Es la transición que vamos a necesitar en hardware real (donde el
  bootloader nos suele dejar en EL2).
- [ ] **L11 — Vector table de excepciones**: VBAR_EL1, formato fijo de
  vectores AArch64 (16 entries × 128 bytes), handlers mínimos en Rust.
- [ ] **L12 — `svc #0`**: triggear una syscall, atrapar la excepción,
  leer ESR_EL1 para identificar la causa.
- [ ] **L13 — IRQs e interrupciones**: GIC v2 init, enable IRQ,
  diferenciar sync vs async exceptions en el handler.

---

## Roadmap de largo plazo

Organizado en **fases**. Cada fase tiene varias lecciones.
Los rangos de lecciones son aproximados — algunas fases pueden requerir
más iteraciones de las planeadas.

### Fase A — Excepciones e interrupciones (L14–L17)

- [ ] L14: Generic Timer del ARM + tick periódico
- [ ] L15: Refactor del vector table para sync vs async exceptions
- [ ] L16: Manejo básico de page faults (preparación para MMU)
- [ ] L17: Spinlocks y deshabilitación de IRQs (sincronización mínima)

### Fase B — MMU y memoria virtual (L18–L22)

- [ ] L18: Formato de page tables AArch64 (TTBR0_EL1, TCR_EL1, MAIR_EL1)
- [ ] L19: Identity mapping del kernel + activar la MMU
- [ ] L20: Physical frame allocator (bitmap o buddy)
- [ ] L21: Higher-half kernel — mover el kernel a `0xFFFF...`
- [ ] L22: Kernel heap + global allocator (`linked_list_allocator` o
  uno propio). Habilita `Box`, `Vec`, etc. en el kernel.

### Fase C — Tareas y scheduler (L23–L27)

- [ ] L23: Estructura `Task`/PCB (Process Control Block), kernel stack
  por tarea
- [ ] L24: Context switch en asm — guardar/restaurar callee-saved
  registers, sp, etc.
- [ ] L25: Scheduler cooperativo (`yield`)
- [ ] L26: Scheduler preemptivo usando el timer
- [ ] L27: Sincronización avanzada (mutex, channels)

### Fase D — Userspace (L28–L33)

- [ ] L28: Construir un binario "user" mínimo y embebearlo en el kernel
- [ ] L29: Address space por proceso (page tables separadas)
- [ ] L30: Bajar a EL0 con `eret` — primer userspace
- [ ] L31: Tabla de syscalls + `write` y `exit`
- [ ] L32: `fork` (clonar address space, eventualmente con COW)
- [ ] L33: `exec` (cargar y ejecutar un binario ELF estático)

**Hito de orgullo**: al final de la Fase D, podés correr un binario
de userspace que hace `fork` + `exec` de otro programa.

### Fase E — Filesystem mínimo (L34–L37)

- [ ] L34: VFS skeleton + tabla de file descriptors por proceso
- [ ] L35: initramfs (CPIO embebido en el kernel)
- [ ] L36: Syscalls `open` / `read` / `close`
- [ ] L37: `/dev/console` mapeando al UART

### Fase F — IPC y herramientas (L38+)

- [ ] Pipes
- [ ] Signals
- [ ] Shared memory
- [ ] Una shell estática mínima en userspace

### Fase G — Almacenamiento real (L?)

- [ ] Driver virtio-blk
- [ ] Filesystem real (FAT32 o ext2)
- [ ] Mount + unmount

### Fase H — Networking (L?)

- [ ] Driver virtio-net
- [ ] TCP/IP stack (probablemente con `smoltcp`)
- [ ] Socket layer + syscalls de red

### Fase I — Multi-core / SMP (L?)

- [ ] PSCI para encender los otros cores
- [ ] Per-CPU data structures
- [ ] Refactor del scheduler para multi-core
- [ ] Memory barriers correctos en todas las primitivas

### Fase J — Hardware real (L?)

- [ ] Cross-build para Snapdragon 732G (Poco X3 NFC)
- [ ] Driver UART del SoC real
- [ ] Device Tree parsing
- [ ] Boot por fastboot / cadena de boot del dispositivo

---

## Principios

1. **Cada lección es mínima**: solo lo indispensable para el objetivo
   de esa lección. No adelantar código por "facilitar el futuro".
2. **Cada lección es ejecutable**: el kernel tiene que correr y hacer
   algo observable al final de cada iteración.
3. **Versión mínima primero**: cuando una fase tenga "versión simple"
   y "versión seria", siempre arrancar con la simple, validar
   end-to-end, y refinarla en lecciones posteriores.
4. **Documentar el por qué**: cada lección genera un `docs/NN-tema.md`
   con explicación detallada y referencias a specs (ARM ARM,
   PrimeCell TRMs, etc.).
5. **Snapshot por lección**: el código de cada lección queda
   congelado en `iterations/NN-tema/` para poder volver a verlo.
