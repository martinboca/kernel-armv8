# Lección 10 — Transición de EL2 a EL1

**Objetivo**: correr el kernel en EL1 (el nivel de privilegio propio
de un kernel) en vez de EL2 (reservado para hypervisors). Para lograrlo
forzamos a QEMU a arrancar en EL2 con `-machine virt,virtualization=on`,
configuramos los system registers que describen el estado deseado
para EL1, y ejecutamos `eret` para hacer el cambio de nivel.

---

## Qué hicimos

1. **Makefile**: agregar `virtualization=on` a la flag `-machine` para
   que QEMU arranque en EL2 en vez de EL1.
   ```make
   QEMU_FLAGS := -machine virt,virtualization=on -cpu cortex-a72 -nographic -kernel kernel.elf
   ```

2. **boot.S**: habilitar FP/SIMD en EL2 (limpiando `CPTR_EL2.TFP`)
   además de EL1 (`CPACR_EL1.FPEN`). Ahora el UART se usa en EL2
   antes del `eret`, así que la ruta NEON de `core::fmt` también
   falla si no limpiamos el bit en EL2.

3. **kmain.rs**: nueva función `_start_rust` que corre en EL2,
   configura 5 system registers y ejecuta `eret`. `kmain` queda
   como la primera función que corre en EL1.

## La mecánica de `eret`

`eret` (Exception Return) hace tres cosas atómicas, leyendo del
estado guardado del EL actual:

```
PC     ← ELR_ELn    (a dónde saltar)
PSTATE ← SPSR_ELn   (modo + flags + máscaras de interrupciones)
SP     ← SP_ELm     (stack del EL de destino)
```

Donde `n` es el EL actual (2 en nuestro caso) y `m` es el EL de
destino (1). Originalmente `eret` fue diseñada para volver de una
excepción: el CPU toma una excepción, salva el estado, el handler
corre, y `eret` restaura el estado. Nosotros la usamos al revés:
fabricamos un estado "como si viniéramos de EL1" y hacemos `eret`
para caer ahí por primera vez.

Antes del `eret` hay que dejar los registros fuente con los valores
correctos. Son 5:

1. `HCR_EL2` — configuración del hypervisor (¿EL1 es 64 o 32 bit?).
2. `SCTLR_EL1` — estado inicial de los controles del sistema en EL1.
3. `SPSR_EL2` — el PSTATE que va a tener EL1 (modo + máscaras).
4. `ELR_EL2` — PC de destino (`kmain`).
5. `SP_EL1` — stack pointer de EL1.

## Decodificando las direcciones mágicas

Los valores hexadecimales en el `asm!` no son arbitrarios — cada bit
tiene un significado documentado en el ARM ARM. Los repasamos uno
por uno.

### `HCR_EL2 = 1 << 31`

`HCR_EL2` (Hypervisor Configuration Register) define cómo se comporta
EL1/EL0 desde el punto de vista de EL2. Casi todos sus bits habilitan
traps (p. ej. "cuando EL1 escriba a SCTLR, trapeame a EL2"). Como no
estamos haciendo virtualización, los queremos todos en 0.

El bit 31 es especial:

- **Bit 31 (`RW`)**: Execution state de EL1.
  - `1` → EL1 corre en AArch64.
  - `0` → EL1 corre en AArch32.

Lo ponemos en 1 para seguir en 64-bit después del `eret`. El resto
queda en 0.

### `SCTLR_EL1 = 0x30D00800`

`SCTLR_EL1` (System Control Register) controla MMU, caches,
alignment checking y otros comportamientos básicos de EL1. Queremos
arrancar con todo **deshabilitado** (MMU apagada, sin caches), pero
no podemos escribir ceros: el registro tiene **bits RES1** (reserved,
should be 1) que la spec ARMv8-A requiere que estén en 1 aunque no
cambien nada funcional.

El valor `0x30D00800` es exactamente esos RES1 bits:

```
0x30D00800 = 0011 0000 1101 0000 0000 1000 0000 0000
             │└┬┘ └──┬────────────────┘ │
             │ │     │                  └── bit 11 (RES1)
             │ │     └── bits 23, 22, 20 (RES1)
             │ └── bits 29, 28 (RES1)
             └── (bit 31, RES0)
```

Bits activos: **29, 28, 23, 22, 20, 11**. Los demás controles
(MMU `M` en bit 0, D-cache `C` en bit 2, I-cache `I` en bit 12,
alignment `A` en bit 1) quedan en 0 — que es lo que queremos.

Si escribiéramos `0` en vez de `0x30D00800`, el comportamiento es
UNPREDICTABLE según la spec.

### `SPSR_EL2 = 0x3C5`

`SPSR_EL2` (Saved Program Status Register) guarda el PSTATE que va a
tener el CPU **después** del `eret`. Es lo que normalmente salvaría
el hardware al tomar una excepción; acá lo fabricamos.

```
0x3C5 = 0b0011_1100_0101
```

Campos relevantes:

- **Bits 9:6 (`DAIF`) = `0b1111`**: máscaras de interrupciones.
  - `D` (bit 9): Debug exceptions enmascaradas.
  - `A` (bit 8): SError enmascarado.
  - `I` (bit 7): IRQ enmascarado.
  - `F` (bit 6): FIQ enmascarado.

  Arrancamos EL1 con todas las interrupciones enmascaradas porque
  todavía no instalamos una vector table. Si llega una interrupción
  sin handler el CPU entra en loop infinito de excepciones.

- **Bits 3:0 (`M`) = `0b0101` = `EL1h`**: el modo de destino.
  - `0b0000` = EL0t (EL0 usando SP_EL0).
  - `0b0100` = EL1t (EL1 usando SP_EL0).
  - `0b0101` = EL1h (EL1 usando SP_EL1). ← esto queremos.
  - `0b1001` = EL2h, `0b1101` = EL3h.

  La `t` vs `h` es "thread" vs "handler": `h` significa que el modo
  usa su propio stack pointer (`SP_ELn`), `t` significa que comparte
  `SP_EL0`. Para un kernel queremos `EL1h` para tener stack dedicado.

El resto de bits (condition flags NZCV, etc.) quedan en 0 — no
importan al arrancar.

### `ELR_EL2 = kmain as u64`

`ELR_EL2` (Exception Link Register) es el PC que el `eret` va a
cargar. Apunta a `kmain` — la primera instrucción que va a ejecutar
el CPU en EL1.

### `SP_EL1 = &stack_top`

Cada EL tiene su propio `SP_ELn`. El `SP_EL2` con el que estamos
corriendo ahora se descarta después del `eret`. Seteamos `SP_EL1`
al tope del stack definido en `linker.ld` (símbolo `stack_top`).

Rust lee el símbolo del linker con:
```rust
extern "C" { static stack_top: u8; }
// ...
addr_of!(stack_top) as u64
```

`addr_of!` evita crear una referencia al símbolo (que sería UB — no
hay un `u8` real en esa dirección, es solo una marca del linker).

## El asm! block

Los 5 `msr` seguidos por `eret`, todo en un solo bloque `asm!` con
`options(noreturn)` porque `eret` no vuelve. Rust garantiza que los
5 inputs están listos en registros antes de empezar las `msr`.

```rust
asm!(
    "msr hcr_el2, {hcr}",
    "msr sctlr_el1, {sctlr}",
    "msr spsr_el2, {spsr}",
    "msr elr_el2, {elr}",
    "msr sp_el1, {sp}",
    "eret",
    hcr   = in(reg) 1_u64 << 31,
    sctlr = in(reg) 0x30D00800_u64,
    spsr  = in(reg) 0x3C5_u64,
    elr   = in(reg) kmain as *const () as u64,
    sp    = in(reg) addr_of!(stack_top) as u64,
    options(noreturn),
);
```

## Verificación

```sh
make clean && make && make run
```

Output:
```
Arrancando en EL2, transicionando a EL1...
Ahora corriendo en EL1
Martín Bocanegra
```

## Lo que queda preparado para L11

- ✅ Kernel corriendo en EL1 (el nivel "correcto" para un kernel).
- ⚠️ Interrupciones enmascaradas: no tenemos vector table todavía.
  Cualquier excepción (page fault, svc, IRQ) cuelga el CPU.
- Siguiente: instalar una vector table en `VBAR_EL1` y desenmascarar
  interrupciones de a una.

---

## Referencias consultadas

- **ARM ARM — D1.6 "Process state, PSTATE"**: formato de SPSR, campo
  `M[3:0]`, significado de `h` vs `t`.

- **ARM ARM — D13.2.37 SCTLR_EL1**: layout del registro y lista de
  bits RES1.

- **ARM ARM — D13.2.47 HCR_EL2**: campos, especialmente `RW` (bit 31).

- **ARM ARM — C6.2.97 ERET**: semántica exacta del `eret`.

- **ARM Cortex-A Programmer's Guide for ARMv8-A, cap. 10
  "Exception handling"**: tutorial más accesible sobre EL transitions.
