# ADR-0002: Limine

Status: proposed, 2026-09-30. Vendored and building; accepted when the review below is done.

## Context

D9 chooses Limine on both architectures: it gives the memory map, framebuffer, modules, SMP start-up and the RSDP or DTB, and boots from UEFI and BIOS.

## Decision

- **Release:** Limine 12.9.1 (2026-09-26), `limine-12.9.1.tar.xz`, sha256 `c1096fdd506487fbd92c113baa9e153a9973cf766483cc3928e13fd29b976b32`. Its signature verifies against Mintsuki's key `05D29860D0A0668AAEFB9D691F3C021BECA23821`.
- **Vendored unchanged:** `third_party/limine/` is the whole tarball, byte for byte, so the tree can be checked against the release. `third_party/VENDOR.ndb` records it.
- **Built by `build`, not by Limine's build.** Limine ships autoconf and GNU make plus `gensyms.sh` (objdump, sort, grep, awk, sed). None of those enter our build (D10, 04 §3.1):
  - `ports/limine/port.ndb` gives the source sets and flags for the two UEFI targets we use, `uefi-x86_64` and `uefi-aarch64`. The flags are the ones Limine's configure chose for the pinned clang, captured once at vendoring, with `config.h`, configure's other output.
  - `build` compiles in parallel, preprocesses the linker script, links without the symbol map, writes the map itself (the `gensyms.sh` step, in C), links again, and turns the ELF into the loader with `llvm-objcopy -O binary`, padded to 4 KiB.
  - The result was checked against Limine's own build of the same release with the same toolchain: `BOOTAA64.EFI` is byte-identical.
- **Not built:** the BIOS stages, the ISO images and the `limine` host tool. A BIOS-bootable hybrid ISO is optional (04 §3.2) and would bring them in.
- The kernel uses Limine's `limine.h`, from `third_party/limine/limine-protocol/include/`.
- **Review:** `reviewed.by=pending` in `VENDOR.ndb` until the owner has reviewed the parts we build: `common/`, `picoefi/` (the x86_64 and aarch64 parts), `flanterm/src`, `libfdt/src`, `freestanding-c-hdrs/` and `limine-protocol/`.

## Consequences

- The x86_64 loader needs `nasm` for its 10 `.asm_*` files; the aarch64 one does not. `build` names the package if `nasm` is missing, and checks its version against the pin in ADR-0001.
- On every Limine upgrade: verify the signature, replace the tree, capture `configure`'s flags and `config.h` again, compare `common/common.mk` with `port.ndb`, and repeat the byte-for-byte comparison.
- Limine is never linked into the kernel; it is a separate image on the ESP.
