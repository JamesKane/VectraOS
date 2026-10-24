set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CROI_SWIFT_TRIPLE aarch64-none-none-elf)
set(CROI_CLANG_TRIPLE aarch64-unknown-none-elf)
# No FP/SIMD register use in the kernel.
set(CROI_ARCH_CFLAGS -mgeneral-regs-only)
# User mode (K6c split): the baseline, Armv8.2-A with FP16, the dot
# product and RCpc (D53; FP/SIMD saved since K6d), which the loader
# checks (boot/Loader/Baseline.swift). BTI landing pads (K14r): lld marks
# a program whose objects all have them, and the loaders map its code
# guarded.
set(CROI_USER_CFLAGS -march=armv8.2-a+fp16+dotprod+rcpc -mbranch-protection=bti)
set(CROI_EFI_BOOT_NAME BOOTAA64.EFI)
# Link address of the kernel image (a PIE; the loader may relocate it).
set(CROI_KERNEL_BASE 0xffffffff80000000)
