AS    := clang
LD    := ld.lld
RUSTC := rustc

ASFLAGS    := --target=aarch64-none-elf -c
RUSTCFLAGS := --target aarch64-unknown-none --edition 2021 --emit=obj -C opt-level=0
LDFLAGS    := -T linker.ld

QEMU       := qemu-system-aarch64
QEMU_FLAGS := -machine virt -cpu cortex-a72 -nographic -kernel kernel.elf

.PHONY: all run clean

all: kernel.elf

boot.o: boot.S
	$(AS) $(ASFLAGS) -o $@ $<

kmain.o: kmain.rs
	$(RUSTC) $(RUSTCFLAGS) -o $@ $<

kernel.elf: boot.o kmain.o linker.ld
	$(LD) $(LDFLAGS) -o $@ boot.o kmain.o

run: kernel.elf
	$(QEMU) $(QEMU_FLAGS)

clean:
	rm -f *.o kernel.elf
