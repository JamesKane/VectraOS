# Vectra orchestration.
#
# Every recipe delegates to build.odin -- this file exists to give the common
# invocations short names, not to hold build logic. If a recipe here starts
# growing flags, the flag belongs in build.odin instead.

_default: run

# Compile and link the kernel.
kernel *ARGS:
    odin run build.odin -file -out:.vectra-build -- kernel {{ARGS}}

# Stage the bootable EFI system partition under build/esp.
esp *ARGS:
    odin run build.odin -file -out:.vectra-build -- esp {{ARGS}}

# Boot under QEMU, headless, serial on stdio. Ctrl-A X to quit.
run *ARGS:
    odin run build.odin -file -out:.vectra-build -- run {{ARGS}}

# Boot with a QEMU window so you can see the chassis.
gui *ARGS:
    odin run build.odin -file -out:.vectra-build -- run --gfx {{ARGS}}

# Boot halted, waiting for gdb on :1234.
debug *ARGS:
    odin run build.odin -file -out:.vectra-build -- debug {{ARGS}}

# Attach gdb to a `just debug` session.
gdb:
    gdb build/vectra.elf -ex 'target remote :1234'

# Optimised, bounds checks off.
release:
    odin run build.odin -file -out:.vectra-build -- run --release

clean:
    odin run build.odin -file -out:.vectra-build -- clean

# Regenerate the baked-in console font from the host's PTMono.
font:
    python3 tools/genfont.py > sys/libfont/font_data.odin

# Type-check the kernel and every program without emitting anything.
# `just check --arch=arm64` checks a port.
check *ARGS:
    odin run build.odin -file -out:.vectra-build -- check {{ARGS}}
    odin check build.odin -file
