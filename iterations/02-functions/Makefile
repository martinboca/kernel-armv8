AS := clang
LD := ld.lld

ASFLAGS := --target=aarch64-none-elf -c
LDFLAGS := -T linker.ld

QEMU       := qemu-system-aarch64
QEMU_FLAGS := -machine virt -cpu cortex-a72 -nographic -kernel kernel.elf

.PHONY: all run clean

all: kernel.elf

boot.o: boot.S
	$(AS) $(ASFLAGS) -o $@ $<

kernel.elf: boot.o linker.ld
	$(LD) $(LDFLAGS) -o $@ boot.o

run: kernel.elf
	$(QEMU) $(QEMU_FLAGS)

clean:
	rm -f *.o kernel.elf
