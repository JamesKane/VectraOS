# Vectra orchestration, for machines without `just` installed.
#
# Mirrors the justfile one-for-one; both are thin wrappers over build.odin,
# which holds the actual build logic.

BUILD := odin run build.odin -file -out:.vectra-build --

.PHONY: all kernel esp run gui debug gdb release clean font check

all: run

kernel:
	$(BUILD) kernel $(ARGS)

esp:
	$(BUILD) esp $(ARGS)

run:
	$(BUILD) run $(ARGS)

gui:
	$(BUILD) run --gfx $(ARGS)

debug:
	$(BUILD) debug $(ARGS)

gdb:
	gdb build/vectra.elf -ex 'target remote :1234'

release:
	$(BUILD) run --release

clean:
	$(BUILD) clean

font:
	python3 tools/genfont.py > kernel/drivers/console/font_data.odin

check:
	odin check kernel -collection:kernel=kernel -collection:vsys=sys \
		-target:freestanding_amd64_sysv -no-entry-point -default-to-nil-allocator \
		-vet -strict-style
	odin check build.odin -file
