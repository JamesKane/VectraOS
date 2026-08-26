# Vendored Limine

Prebuilt UEFI bootloader binaries from the Limine `limine-binary` release
tarball, upstream tag **v12.6.1**.

    https://github.com/limine-bootloader/limine/releases/tag/v12.6.1

Only the UEFI applications are vendored. Vectra boots via UEFI on every
supported architecture, so the BIOS stage (`limine-bios.sys`, `limine-bios-*.bin`)
and the `limine` deployment tool are not needed -- `build.odin` stages an EFI
system partition directly and never installs a boot sector.

`kernel/boot/limine/limine.odin` must stay in step with the protocol version
these binaries implement. Vectra requests **base revision 6**; if that number
moves, re-read `limine-protocol/PROTOCOL.md` in the matching source tarball
before touching the bindings.

Licensed BSD-2-Clause; see `LICENSE`.
