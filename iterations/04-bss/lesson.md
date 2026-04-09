# Lección 04 — Inicialización de `.bss`

**Objetivo**: agregar al kernel el paso de arranque que pone en cero la
sección `.bss`. Es un requisito que cualquier lenguaje de alto nivel
(C, Rust) impone sobre el código de startup, y es el último prerrequisito
antes de poder saltar a Rust en la lección 05.

Archivos:
[boot.S](../iterations/04-bss/boot.S),
[linker.ld](../iterations/04-bss/linker.ld),
[Makefile](../iterations/04-bss/Makefile).

---

## 1. ¿Qué es `.bss` y por qué hay que ponerla a cero?

`.bss` es una de las secciones estándar de los formatos ejecutables tipo
ELF. El nombre es un acrónimo histórico (*Block Started by Symbol*) que
hoy nadie usa por su significado original; en la práctica es
simplemente "el lugar donde van las variables globales/estáticas cuyo
valor inicial es todo ceros".

### Qué cosas van a `.bss`

El criterio que usan los compiladores para mandar una variable a `.bss`
es: **el valor inicial de la variable es puramente ceros**. Si no,
termina en `.data` o `.rodata`.

En C:

```c
int contador;              // → .bss
                           //   (sin inicializador; en C eso equivale a
                           //    "inicializá en 0", que el compilador
                           //    resuelve mandándolo a .bss)
int activos = 0;           // → .bss
int buffer[1024];          // → .bss (mismo motivo)
int configurado = 1;       // → .data (el valor inicial no es cero)
```

Acá conviene aclarar un punto importante del modelo de C: el estándar
dice explícitamente que las variables con **duración de almacenamiento
estática** (globals, `static` dentro de funciones) que no tienen
inicializador **valen cero** al arrancar el programa. No es casualidad
que terminen en `.bss`: el lenguaje garantiza que arrancan en 0, y el
compilador aprovecha eso para no gastar bytes en el ejecutable.

En **Rust** el modelo es distinto:

```rust
static CONTADOR: u32 = 0;            // → .bss
static BUFFER: [u8; 1024] = [0; 1024]; // → .bss
static CONFIGURADO: u32 = 1;          // → .data

static NO_INICIALIZADO: u32;          // ❌ error de compilación
```

Rust **no tiene** variables estáticas sin inicializador. Toda `static`
debe llevar un inicializador explícito — el lenguaje te obliga a
escribirlo. Entonces no hay un concepto de "valor default a cero" como
en C; si querés que una variable arranque en 0, la escribís con `= 0`,
punto.

¿Y por qué, entonces, Rust igual termina mandando cosas a `.bss`?
Porque rustc (a través de LLVM) detecta cuando un static tiene valor
inicial todo ceros y lo coloca en `.bss` como **optimización de
tamaño** — exactamente la misma optimización que hace el compilador de
C. No es una semántica del lenguaje Rust; es una decisión del backend
del compilador. El efecto práctico es el mismo: hay un rango de memoria
marcado como `.bss` en el ELF, con algún tamaño, y el código asume que
al arrancar el programa ese rango está lleno de ceros.

### Lo que esto implica para nuestro startup

La consecuencia es la misma en ambos lenguajes, aunque por caminos
distintos: **el código compilado asume que la región `.bss` vale cero
cuando empieza a correr**. Si nosotros no nos aseguramos de que lo
esté, `static CONTADOR: u32 = 0;` podría leer basura la primera vez en
lugar del `0` que el código espera, y el programa está mal.

### Por qué `.bss` no ocupa espacio en el ELF

Si todas las variables de `.bss` empiezan en cero, no tiene caso gastar
bytes en el archivo ejecutable guardando ceros. El formato ELF tiene un
truco para esto: la sección `.bss` aparece en el header con un
**tamaño** (`sh_size`) pero con un **offset de archivo inválido** y tipo
`SHT_NOBITS`, que significa literalmente "no hay bytes que cargar".

El loader (en nuestro caso QEMU) lee ese header y entiende:
> "Tenés que reservar tantos bytes de memoria empezando en esta dirección,
> pero no hay nada que copiar desde el archivo."

Es una optimización muy vieja y muy útil. Imaginate un programa con un
buffer global de 1 MiB de datos — si ese buffer fuera a `.data` en vez
de `.bss`, el ejecutable tendría 1 MiB de ceros innecesarios adentro.
Con `.bss`, el ejecutable no crece nada.

### El problema: nadie pone los ceros

Ahora bien — si el archivo no contiene los ceros, ¿quién los pone?

En un **sistema operativo normal** (Linux, macOS, Windows), el kernel
hace esto por vos: cuando lanza un proceso, mmapea la región de `.bss` a
**páginas de cero anónimas** (literalmente un truco de la MMU que
entrega páginas inicializadas en cero al primer acceso). El programa
nunca ve memoria no inicializada; `.bss` ya está en cero cuando arranca.

En **bare-metal**, ese servicio no existe. Nadie pone los ceros por
nosotros. La memoria que dejó QEMU al iniciarse tiene algún valor — en
realidad, QEMU la inicializa a cero cuando arma la máquina, pero en
hardware real sería basura, y no podemos depender de eso. La convención
universal en bare-metal es: **el código de startup tiene la obligación
de cerar `.bss` antes de transferir el control a código que asuma los
ceros**.

Es decir: antes de saltar a `kmain` (y más adelante, a código de Rust),
nosotros mismos tenemos que recorrer el rango `[bss_start, bss_end)` y
ponerlo a cero.

---

## 2. El cambio en `linker.ld`

```ld
.bss : ALIGN(8) {
    bss_start = .;
    *(.bss)
    *(.bss.*)
    *(COMMON)
    . = ALIGN(8);
    bss_end = .;
}
```

Lo que cada línea hace:

- **`.bss : ALIGN(8) { ... }`**: declara una output section llamada
  `.bss`. `ALIGN(8)` antes del `{` le dice al linker "alineá el location
  counter a 8 bytes antes de empezar a colocar esta sección". Esto
  asegura que `bss_start` sea una dirección múltiplo de 8. Lo queremos
  así para que el loop que pone la sección a cero, al escribir de a 8
  bytes con `str xzr`, no tenga que preocuparse por un inicio
  desalineado.

- **`bss_start = .;`**: define el símbolo `bss_start` apuntando a la
  dirección actual (el comienzo de la sección). El linker lo exporta en
  la tabla de símbolos y `boot.S` lo puede referenciar con `ldr x0, =bss_start`.

- **`*(.bss)`**: mete en esta output section todas las input sections
  llamadas `.bss` de cualquier archivo objeto. Hoy no hay ninguna
  (`boot.S` no declara nada en `.bss`), así que no aporta nada. Mañana,
  cuando Rust emita variables `static mut`, las va a emitir en una
  sección llamada `.bss` o `.bss.NOMBRE`.

- **`*(.bss.*)`**: mete también input sections con nombres como
  `.bss.NOMBRE`. Rust y algunos compiladores de C generan una sección
  separada por cada variable de `.bss` (con nombres como `.bss.mi_var`),
  para poder hacer garbage collection de variables no usadas. Este
  wildcard las captura a todas.

- **`*(COMMON)`**: `COMMON` es una pseudo-sección histórica usada por C
  para variables globales declaradas sin `extern` en múltiples archivos.
  Es prácticamente obsoleta con C moderno, pero la incluimos por hábito
  porque no cuesta nada.

- **`. = ALIGN(8);`**: alineamos el location counter a 8 bytes *antes*
  de capturar `bss_end`. Esto garantiza que `bss_end - bss_start` sea un
  múltiplo de 8, así el loop termina en el borde exacto sin
  sobrescribir nada más allá del final.

- **`bss_end = .;`**: define el símbolo `bss_end` apuntando al final de
  la sección.

### Ubicación de `.bss` en el layout

El orden dentro del `SECTIONS { ... }` es intencional:

```
0x40000000  ┌────────────────┐
            │    .text       │   ← código + literales (msg vive acá hoy)
            ├────────────────┤
            │    .bss        │   ← vacía hoy, crecerá con Rust
            ├────────────────┤
            │  (padding)     │   ← ALIGN(16)
            │                │
            │    stack       │   ← 4 KiB de stack reservados
            │                │
stack_top → └────────────────┘
```

`.bss` queda inmediatamente después del `.text` y antes del stack. Esa
posición importa: el loop que pone `.bss` a cero recorre
`[bss_start, bss_end)`, y si el stack estuviera en medio del rango, lo
borraría cada vez que rebooteáramos. Poniendo el stack *después* del
`bss_end`, está protegido.

---

## 3. El cambio en `boot.S`

`_start` gana una sección nueva en el medio. Antes era:

```asm
_start:
    ldr     x0, =stack_top
    mov     sp, x0
    b       kmain
```

Ahora es:

```asm
_start:
    // 1. Stack pointer
    ldr     x0, =stack_top
    mov     sp, x0

    // 2. Zero .bss en chunks de 8 bytes
    ldr     x0, =bss_start
    ldr     x1, =bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:

    // 3. Transferir el control al kernel
    b       kmain
```

### El registro `xzr`

ARMv8-A tiene un registro especial llamado **zero register** con dos
nombres: `xzr` (vista de 64 bits) y `wzr` (vista de 32 bits). Es el
registro "número 31" en el encoding de las instrucciones, pero:

- **Cuando lo usás como fuente**, siempre vale 0. No importa qué haya
  pasado antes: lee 0.
- **Cuando lo usás como destino**, las escrituras se descartan. Podés
  escribir en él sin efecto.

Es una comodidad muy común en ISAs RISC: te permite emitir una constante
cero sin gastar un registro real ni una instrucción previa de
"poné un 0 en tal lado". Nosotros lo usamos para escribir ceros en
`.bss`:

```asm
str     xzr, [x0], #8
```

"Guardá el valor de `xzr` (o sea, 0) en la dirección `[x0]`, y después
incrementá `x0` en 8". Esto escribe 8 bytes de cero en memoria por
instrucción.

### El control de loop con `cmp` y `b.hs`

```asm
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:
```

- **`cmp x0, x1`**: resta `x1` de `x0` y actualiza las banderas del
  PSTATE (N, Z, C, V), pero no guarda el resultado en ningún registro.
  Es solo para comparar.

- **`b.hs 2f`**: "branch if higher or same" (unsigned). Salta a `2f` si
  `x0 >= x1` interpretando las direcciones como unsigned. Cuando la
  salida del `cmp` indica que `x0` ya alcanzó o superó a `x1`, el loop
  termina.

  ¿Por qué `b.hs` y no `b.ge`? `b.ge` es "branch if greater or equal"
  pero en sentido **signed**. Las direcciones de memoria se deben
  comparar como unsigned, porque una dirección alta como `0xFFFFFFFF`
  en sentido signed es negativa y eso rompería la comparación. En
  nuestro caso concreto las direcciones son chicas (`0x40000000` y
  unos bytes más), así que `b.ge` también funcionaría, pero `b.hs` es
  correcto siempre.

- **`b 1b`**: branch backward a la etiqueta `1`. Vuelve al inicio del
  loop.

### ¿Qué hace hoy este loop?

Literalmente nada. En el estado actual del proyecto, ningún archivo `.o`
emite contenido en `.bss`, así que el linker coloca `bss_start` y
`bss_end` en la misma dirección. El loop entra, compara x0 con x1, ve
que son iguales, `b.hs` es verdadero, y saltamos a `2f` sin haber
escrito nada.

Podemos verificarlo mirando la tabla de símbolos del ELF. Si corrés:

```sh
llvm-objdump -t kernel.elf | grep -E 'bss_(start|end)'
```

vas a ver las dos direcciones pegadas una a la otra (mismo valor, o a lo
sumo separadas por el padding de alineación).

¿Para qué lo agregamos entonces? Por lo que decíamos antes: **la
infraestructura queda probada en vacío**. Cuando en la lección 05 Rust
agregue la primera variable estática (por ejemplo, un panic counter, o
un flag de "ya imprimí algo"), va a emitir una entrada en `.bss`, el
linker va a separar `bss_start` de `bss_end`, y este mismo loop va a
empezar a escribir ceros en el rango correcto. Ni `_start` ni el linker
script van a necesitar cambios.

---

## 4. ¿Por qué L04 es su propia lección?

Podríamos haber hecho todo esto adentro de L05 "primer Rust". La razón
de separarlo es pedagógica:

- L04 toca **conceptos de bare-metal** (qué es `.bss`, por qué hay que
  ponerla a cero, cómo funciona el zero register, cómo escribir un loop
  de memset en asm). Son conocimientos que aplican a cualquier kernel
  de cualquier lenguaje, no específicos de Rust.
- L05 va a tocar **conceptos de integración con Rust** (qué es `no_std`,
  qué es `no_main`, cómo configurar un crate no-estándar, cómo linkear
  Rust con asm, panic handlers). Son conocimientos específicos del
  lenguaje de alto nivel.

Mezclarlas haría que L05 tenga que explicar ambas cosas en un solo
documento y sea el doble de larga. Separándolas, cada lección queda
enfocada en una capa conceptual distinta, y L05 puede dar por sentado
que el kernel ya pone `.bss` a cero en el startup, y concentrarse en
la parte de Rust.

---

## 5. Verificación

- `make clean && make && make run` → imprime `Martin Bocanegra`, como
  siempre. El output no cambia.
- Internamente, `_start` ahora hace el loop que pone `.bss` a cero.
  Como `.bss` está vacía, el loop termina instantáneamente sin escribir
  nada.

Si querés inspeccionar los símbolos para confirmar que `bss_start` y
`bss_end` están definidos:

```sh
llvm-objdump -t kernel.elf | grep bss
```

(o `nm kernel.elf` si tenés `nm` de binutils disponible).

---

## 6. Lo que queda preparado para L05

Después de esta lección, el kernel tiene todo lo que necesita para
recibir código de alto nivel:

- ✅ Stack pointer válido desde el primer instante de `kmain`.
- ✅ `.bss` puesta a cero antes de que corra cualquier código que la use.
- ✅ `kmain` definida como una función `-> !` en términos de contrato
  (ver L03).
- ❌ `.rodata` y `.data` en el linker script — *todavía no*, porque ningún
  archivo `.o` los emite. Los vamos a agregar en L05 cuando Rust los
  necesite.
- ❌ Build system para compilar Rust — *todavía no*, lo montamos en L05.

---

## 7. Referencias consultadas

- **ELF specification — sección SHT_NOBITS**: define formalmente que
  `.bss` tiene tamaño pero no contenido en el archivo.
  https://refspecs.linuxfoundation.org/elf/elf.pdf (§ Section Header
  Table, sh_type)

- **Arm A64 ISA** — `str` con post-indexed writeback, comparación
  unsigned con `b.hs`, el zero register `xzr`/`wzr`.
  https://developer.arm.com/documentation/ddi0596/latest/

- **GNU ld manual — linker script syntax**: `ALIGN()`, asignación a
  símbolos dentro de `SECTIONS`, wildcards de input sections.
  https://sourceware.org/binutils/docs/ld/Scripts.html
