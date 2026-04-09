# Lección 03 — Separar `_start` de `kmain`

**Objetivo**: refactorizar el kernel para que `_start` contenga solo el
*código de arranque* (la parte que corre en condiciones especiales) y
mover toda la lógica del kernel a una función `kmain`, todavía escrita
en assembler. El output sigue siendo exactamente `Martin Bocanegra`.

Archivos:
[boot.S](../iterations/03-kmain/boot.S),
[linker.ld](../iterations/03-kmain/linker.ld),
[Makefile](../iterations/03-kmain/Makefile).

---

## 1. Motivación

Hasta la lección 02, `_start` hacía dos cosas mezcladas:
1. **Setup del entorno**: inicializar el stack pointer.
2. **Lógica del kernel**: llamar a `puts` con el mensaje, halt loop.

Esas dos tareas son conceptualmente muy distintas y corren en condiciones
muy distintas:

| Aspecto | Código de arranque (startup) | Código del kernel |
|---|---|---|
| ¿Cuándo corre? | Una sola vez, al principio del tiempo | Todo el resto de la vida del sistema |
| Estado al entrar | SP basura, registros basura, caches off | SP válido, entorno normal |
| Qué puede hacer | Solo lo mínimo indispensable | Todo: llamar funciones, usar el stack, etc. |
| En qué lenguaje conviene | Assembler (no hay opción) | Assembler hoy, Rust mañana |

Mezclarlas hace que la frontera quede borrosa. Separarlas tiene varios
beneficios:

- **El código de arranque es identificable y aislable.** Todo lo que hay
  que mirar para entender "cómo arranca el sistema" vive en `_start`, y
  es la mínima cantidad posible.
- **`kmain` puede cambiar de lenguaje sin que `_start` cambie.** En la
  lección 05 vamos a hacer que `kmain` pase a ser una función de Rust.
  Cuando ese día llegue, la única modificación en `boot.S` va a ser:
  "el símbolo `kmain` ahora lo provee el crate de Rust, no este archivo".
  `_start` en sí queda intacto.
- **`kmain` puede asumir un entorno sano.** No tiene que preocuparse de
  setear el SP, de estar en qué exception level, de si hay stack, nada.
  Eso ya fue resuelto antes de que la llamen.

Esta lección no agrega ninguna funcionalidad nueva. Es un **refactor
puro**: el mismo programa, reorganizado para que el próximo paso sea
barato.

---

## 2. El cambio en `boot.S`

### Antes (lección 02)

```asm
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    adr     x0, msg
    bl      puts
halt:
    wfe
    b       halt
```

`_start` mezclaba el setup (`ldr`/`mov sp`) con la lógica (`adr`/`bl puts`)
y con la finalización (`wfe`/`b halt`).

### Después (lección 03)

```asm
.global _start
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    b       kmain

kmain:
    adr     x0, msg
    bl      puts
halt:
    wfe
    b       halt
```

Dos bloques netamente separados. `_start` tiene tres líneas: cargar
`stack_top` a un registro general, moverlo a `SP`, y saltar a `kmain`.
Punto. `kmain` tiene toda la lógica.

---

## 3. Por qué `b kmain` y no `bl kmain`

Esta fue una decisión chica pero importante. Las dos opciones eran:

### Opción A — `bl kmain`

```asm
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    bl      kmain
    // si kmain vuelve por alguna razón, halt:
halt:
    wfe
    b       halt

kmain:
    str     x30, [sp, #-16]!   // ← kmain tiene que preservar x30
    adr     x0, msg
    bl      puts
    ldr     x30, [sp], #16
    ret
```

En esta versión, `_start` trata a `kmain` como una subrutina normal: la
llama con `bl`, `kmain` tiene prólogo y epílogo para preservar `x30`, y
vuelve con `ret`. Si vuelve, `_start` cae en el halt.

### Opción B — `b kmain` (la que elegimos)

```asm
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    b       kmain

kmain:
    adr     x0, msg
    bl      puts
halt:
    wfe
    b       halt
```

Acá `_start` cede el control con un **branch incondicional sin link**.
No guarda dirección de retorno en `x30`, no espera volver, y `kmain`
no tiene obligación de preservar nada: ni el `x30` de `_start` (que
nunca existió como "dirección de retorno útil") ni ningún otro registro.

### ¿Por qué B es mejor?

Tres razones, ordenadas de más concreta a más filosófica:

1. **Menos código**. `kmain` se ahorra el prólogo y el epílogo (no tiene
   que hacer `str x30, ...` ni `ldr x30, ...`). `_start` puede tener (o
   no) el halt, pero de todos modos más abajo ya había que poner el halt
   en algún lado.

2. **El halt pertenece a `kmain`, no a `_start`.** Cuando `kmain` termine
   de hacer su trabajo, el sistema se queda sin nada que hacer y entra en
   halt. Eso es responsabilidad *del kernel*, no del código de arranque.
   Con la opción B, el halt vive al final de `kmain`, donde conceptualmente
   corresponde.

3. **Coincide con el contrato de la `kmain` de Rust futura.** En la
   lección 05, `kmain` va a ser una función de Rust declarada con tipo
   de retorno `-> !` (el tipo "never", que significa "esta función no
   retorna"). Rust garantiza en compile time que una función `-> !` no
   puede hacer `return`. Entonces el contrato desde `_start` tiene que
   ser "salto y no espero volver", que es exactamente `b kmain`.

   Si hoy usáramos `bl kmain`, cuando llegara la lección 05 tendríamos
   que cambiarlo a `b kmain` porque ya no habría `ret` del lado de Rust.
   Mejor dejar el contrato correcto de entrada.

---

## 4. Cómo queda `kmain`

```asm
kmain:
    adr     x0, msg
    bl      puts
halt:
    wfe
    b       halt
```

`kmain` tiene tres características importantes que la distinguen de las
funciones "normales" que definimos en L02:

- **No tiene prólogo ni epílogo**. No hace `stp`/`ldp` del link register,
  porque nadie la va a llamar esperando que vuelva. El `x30` que tenga
  al entrar es basura que podemos pisar sin miedo.
- **Nunca retorna**. No hay `ret` al final. En su lugar hay un loop de
  halt (`wfe` + `b`).
- **Puede usar `bl` libremente** (como hace con `bl puts`) porque no le
  importa que le sobreescriban `x30` — no lo iba a usar de todos modos.

Es, en términos de Rust, una función con tipo `fn kmain() -> !`. No es
una subrutina: es *el* programa que va a correr después del boot.

`puts` y `putc` se quedan exactamente como estaban en L02. Son funciones
normales, con sus prólogos/epílogos, que `kmain` puede llamar.

---

## 5. El "mapa" del nuevo `boot.S`

El archivo queda organizado en tres capas conceptuales:

```
┌──────────────────────────────────────────────┐
│  _start  (startup code)                      │  ← corre una vez con el
│    - setea SP                                │    mundo en estado bruto
│    - b kmain                                 │
├──────────────────────────────────────────────┤
│  kmain   (kernel entry point, nunca vuelve)  │  ← la "lógica" del kernel
│    - adr x0, msg                             │    asume entorno sano
│    - bl puts                                 │
│    - halt loop                               │
├──────────────────────────────────────────────┤
│  puts, putc  (subrutinas del kernel)         │  ← funciones normales que
│    - prólogo/epílogo normales                │    kmain puede llamar
│    - ret                                     │
└──────────────────────────────────────────────┘
```

Cada capa tiene reglas distintas sobre qué puede asumir del estado del
mundo y qué obligaciones tiene con quien la llama. Que esas tres capas
estén claramente separadas en el archivo es el verdadero producto de
esta lección.

---

## 6. Recorrido de ejecución

Desde el encendido hasta el halt, ahora:

1. QEMU salta a `_start` con `PC = 0x40000000`, `SP` basura.
2. `_start` pone `SP = stack_top`.
3. `_start` hace `b kmain` — salto directo, sin guardar dirección de
   retorno. `_start` efectivamente deja de existir.
4. `kmain` empieza a ejecutar. El entorno ya es "normal": SP válido,
   puede usar el stack, puede llamar funciones.
5. `kmain` hace `adr x0, msg` + `bl puts`. `puts` es una función normal,
   con su prólogo y su loop, llamando a `putc` por cada byte.
6. `puts` retorna a la instrucción siguiente a `bl puts` dentro de `kmain`.
7. `kmain` cae en el halt loop: `wfe` duerme el core, `b halt` lo vuelve
   a dormir si despierta por algo.

El output en la consola serial es `Martin Bocanegra\n` y después el core
queda dormido en `wfe` para siempre.

---

## 7. Qué preparó esta lección

Esta lección no se ve desde afuera — el output es idéntico al de la 02.
Pero lo que cambió internamente es lo que nos va a permitir avanzar:

- **`_start` ya está en su versión "final" o casi**. En las próximas
  lecciones le vamos a agregar el cereado de `.bss` (L04), y después va
  a quedar estable. Los cambios sucesivos del kernel van a ocurrir todos
  en `kmain`, no en `_start`.

- **Hay una frontera explícita entre "startup" y "kernel"**. En la
  lección 05, cuando `kmain` pase a ser Rust, la frontera va a ser
  literalmente la frontera entre assembler y Rust. Hoy la frontera es
  solo conceptual, pero ya está trazada en el código.

- **`kmain` tiene el contrato correcto (`-> !`)**. No va a haber que
  cambiarlo el día que `kmain` se reescriba en Rust.

---

## 8. Referencias consultadas

- **Arm A64 Instruction Set Architecture** — diferencia entre `b`
  (unconditional branch) y `bl` (branch with link). `b` no toca `x30`;
  `bl` lo sobreescribe con `PC + 4`.
  https://developer.arm.com/documentation/ddi0596/latest/

- **Rust Reference — the `!` "never" type** — el tipo de retorno de
  funciones que no vuelven. Es lo que tendrá `kmain` cuando pase a Rust
  en la lección 05.
  https://doc.rust-lang.org/reference/types/never.html
