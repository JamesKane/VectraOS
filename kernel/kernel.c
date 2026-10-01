// kernel.c: the unity-build root (docs/04 §1.1). Every other kernel .c file is
// included here, so the kernel is one translation unit.

#include "vx/abi.h"

// What each architecture provides to the rest of the kernel.
static void arch_console_write(vx_str s);
[[noreturn]] static void arch_halt(void);

// What the rest of the kernel provides to the architecture's entry point.
[[noreturn]] static void kernel_main(void);

#if defined(__x86_64__)
#  define VX_ARCH_NAME "x86_64"
#  include "arch/x86_64/arch.c"
#elif defined(__aarch64__)
#  define VX_ARCH_NAME "aarch64"
#  include "arch/aarch64/arch.c"
#else
#  error "unsupported architecture"
#endif

#include "main.c"
