AS    := clang
LD    := ld.lld
RUSTC := rustc

RUSTLIB := $(shell $(RUSTC) --print sysroot)/lib/rustlib/aarch64-unknown-none/lib
LIBCORE := $(wildcard $(RUSTLIB)/libcore-*.rlib)
LIBCB   := $(wildcard $(RUSTLIB)/libcompiler_builtins-*.rlib)


ASFLAGS    := --target=aarch64-none-elf -c
RUSTCFLAGS := --target aarch64-unknown-none --edition 2021 --emit=obj -C opt-level=0
LDFLAGS    := -T linker.ld

QEMU       := qemu-system-aarch64
QEMU_FLAGS := -machine virt -cpu cortex-a72 -nographic -kernel kernel.elf

.PHONY: all run clean rust-analyzer

all: kernel.elf

boot.o: boot.S
	$(AS) $(ASFLAGS) -o $@ $<

kmain.o: kmain.rs
	$(RUSTC) $(RUSTCFLAGS) -o $@ $<

kernel.elf: boot.o kmain.o linker.ld
	$(LD) $(LDFLAGS) -o $@ boot.o kmain.o $(LIBCORE) $(LIBCB)

run: kernel.elf
	$(QEMU) $(QEMU_FLAGS)

rust-analyzer:
	@echo "{" > rust-project.json
	@echo "  \"sysroot_src\": \"$$(rustc --print sysroot)/lib/rustlib/src/rust/library\"," >> rust-project.json
	@echo "  \"crates\": [" >> rust-project.json
	@echo "    {" >> rust-project.json
	@echo "      \"root_module\": \"kmain.rs\"," >> rust-project.json
	@echo "      \"edition\": \"2021\"," >> rust-project.json
	@echo "      \"deps\": []," >> rust-project.json
	@echo "      \"cfg\": [\"no_std\"]" >> rust-project.json
	@echo "    }" >> rust-project.json
	@echo "  ]" >> rust-project.json
	@echo "}" >> rust-project.json
	@echo "rust-project.json generado. Reiniciá rust-analyzer"

clean:
	rm -f *.o kernel.elf rust-project.json
