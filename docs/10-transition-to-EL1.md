# Lección 10 — Transición de EL2 a EL1

**Objetivo**: correr el kernel en EL1 (el nivel de privilegio propio
de un kernel) en vez de EL2 (reservado para hypervisors). Para lograrlo
forzamos a QEMU a arrancar en EL2 con `-machine virt,virtualization=on`,
configuramos los system registers que describen el estado deseado para
EL1, y ejecutamos `eret` para hacer el cambio de nivel.

Archivos:
[boot.S](../iterations/10-transition-to-EL1/boot.S),
[kmain.rs](../iterations/10-transition-to-EL1/kmain.rs),
[linker.ld](../iterations/10-transition-to-EL1/linker.ld),
[Makefile](../iterations/10-transition-to-EL1/Makefile).

---

## 1. Por qué bajar a EL1

Un kernel corre en EL1: es el nivel con privilegio suficiente para
configurar MMU, vector table, page tables, y manejar excepciones de
EL0 (userspace). EL2 existe para hypervisors — tiene registros y
controles que un kernel normal no necesita.

En hardware real, el bootloader (U-Boot, EDK2) suele dejarnos en
EL2 y espera que nosotros bajemos a EL1. Esta lección practica esa
transición en QEMU para tenerla lista cuando portemos a hardware.

## 2. `-machine virt,virtualization=on`

Por default QEMU `virt` arranca el kernel en EL1 (lo vimos en L08).
Para ejercitar la transición pedimos que arranque en EL2:

```make
QEMU_FLAGS := -machine virt,virtualization=on -cpu cortex-a72 -nographic -kernel kernel.elf
```

`virtualization=on` habilita EL2 en la máquina virtual. Sin este flag
no se puede entrar a EL2 — los registros `HCR_EL2`, `ELR_EL2`, etc.
no existen.

## 3. `eret` como mecanismo de bajada

`eret` (Exception Return) fue diseñada para volver de una excepción:
el CPU salva PC y PSTATE al tomar la excepción, el handler corre, y
`eret` restaura ese estado. La instrucción hace tres asignaciones
atómicas:

```
PC     ← ELR_ELn
PSTATE ← SPSR_ELn
SP     ← SP_ELm   (del EL de destino)
```

Nosotros la usamos al revés: fabricamos un estado "como si viniéramos
de EL1" y hacemos `eret` para caer ahí por primera vez. El truco es
que a `eret` no le importa si el estado es genuino o construido a
mano — si los registros son consistentes, salta.

## 4. Los 5 registros a configurar

Antes del `eret` dejamos 5 registros con valores específicos. La
lección tiene el desglose bit por bit; acá un resumen:

| Registro    | Valor          | Qué define                                     |
|-------------|----------------|------------------------------------------------|
| `HCR_EL2`   | `1 << 31`      | EL1 corre en AArch64 (bit `RW`)                |
| `SCTLR_EL1` | `0x30D00800`   | Estado inicial EL1 (solo RES1 bits, MMU off)   |
| `SPSR_EL2`  | `0x3C5`        | PSTATE post-eret: DAIF=1111, modo=EL1h         |
| `ELR_EL2`   | `&kmain`       | PC destino                                     |
| `SP_EL1`    | `&stack_top`   | Stack de EL1                                   |

Los valores `0x30D00800` y `0x3C5` no son arbitrarios: son
combinaciones de bits documentadas en el ARM ARM. Los RES1 de
SCTLR_EL1 son obligatorios (escribir 0 es UNPREDICTABLE), y `0x3C5`
codifica "todas las interrupciones enmascaradas + modo EL1h".

Ver [lesson.md](../iterations/10-transition-to-EL1/lesson.md) para
el análisis bit por bit.

## 5. `_start_rust`: setup + eret en Rust

Movimos el setup de los system registers a una función Rust
(`_start_rust`) que corre en EL2 antes del `eret`. La elección de
Rust sobre asm responde a dos razones:

- Los valores "mágicos" quedan como constantes con comentarios al
  lado, no números hardcodeados en una `.S`.
- `println!` funciona en EL2 (después de habilitar FP/SIMD), así que
  podemos imprimir "arrancando en EL2..." antes de la transición
  y "corriendo en EL1" después. Útil para debug.

```rust
#[no_mangle]
pub extern "C" fn _start_rust() -> ! {
    println!("Arrancando en EL{}, transicionando a EL1...", read_el());
    unsafe {
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
    }
}
```

El `options(noreturn)` le dice a Rust que el bloque no retorna — `eret`
cambia el PC y el CPU nunca vuelve a ejecutar la instrucción siguiente.

## 6. FP/SIMD en EL2

`boot.S` tuvo que sumar una habilitación de FP/SIMD en EL2. En L08
activamos `CPACR_EL1.FPEN`, pero ahora estamos usando `println!`
desde EL2 (antes del `eret`), y las precondiciones NEON de
`core::ptr::write_volatile` también fallan en EL2 si no limpiamos
`CPTR_EL2.TFP`:

```asm
mrs     x0, cptr_el2
bic     x0, x0, #(1 << 10)
msr     cptr_el2, x0
```

Sin esto, el primer `println!("Arrancando en EL...")` genera un trap
a EL2 y el kernel cuelga antes de llegar a imprimir nada.

## 7. Verificación

```sh
make clean && make && make run
```

Output:
```
Arrancando en EL2, transicionando a EL1...
Ahora corriendo en EL1
Martín Bocanegra
```

## 8. Lo que queda preparado para L11

- ✅ Kernel corriendo en EL1 con stack dedicado (`SP_EL1`).
- ✅ Procedimiento de transición documentado, listo para reusar en
  hardware real.
- ⚠️ Interrupciones enmascaradas (`DAIF=1111`). Cualquier excepción
  sincrónica (page fault, svc, instrucción inválida) cuelga el CPU
  porque `VBAR_EL1` apunta a 0.
- Siguiente: instalar una vector table en `VBAR_EL1` con handlers
  mínimos, y empezar a atrapar excepciones.

---

## 9. Referencias consultadas

- **ARM ARM — D1.6 "Process state, PSTATE"**: formato de SPSR, campo
  `M[3:0]` (target mode), significado de `h` vs `t` stack selector.

- **ARM ARM — D13.2.37 SCTLR_EL1**: layout completo del registro y
  lista de bits RES1 (29, 28, 23, 22, 20, 11).

- **ARM ARM — D13.2.47 HCR_EL2**: descripción del bit `RW` y del resto
  de los bits de trapping.

- **ARM ARM — C6.2.97 ERET**: semántica formal de la instrucción.

- **ARM Cortex-A Programmer's Guide for ARMv8-A — cap. 10
  "Exception handling"**: tutorial accesible sobre EL transitions,
  complementa al ARM ARM.
  https://developer.arm.com/documentation/den0024/a/
