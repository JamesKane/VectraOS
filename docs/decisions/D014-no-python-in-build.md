# D14. No Python in the build (2026-10-15, decided)

The owner asked for this to cut the build chain's dependencies. croi's
Python tools are rewritten in Swift as `vx` subcommands:
- `elf2efi`, `mkbootfs` and `check-pixels`, over the `ImageFormats`
  library;
- `qemu-monitor`, `todhchai-check`, and `bench --zircon` (was
  `zircon-bench/compare.py`).

CMake builds `vx` with SwiftPM and runs it for its build steps.

- **Checked before removal.** Every output was compared with the Python
  version's: the PE images of all three arches' loaders, every arch's
  `bootfs.img`, the pixel checks, and the names in Todhchai's bootfs
  images. All were byte-identical. Then the Python was removed.
- **What a build needs now:** the Swift toolchain, CMake, Ninja, QEMU and
  bash. `qemu.sh` and `zircon-bench/run.sh` stay as bash.
