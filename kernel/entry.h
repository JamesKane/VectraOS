// entry.h: the kernel's external symbols, the ones reached by name from outside
// C: by the bootloader, the entry assembly, the linker script or the compiler.
// Everything else in the kernel is static, in one translation unit (04 §1.1).
#pragma once

#include "vx/abi.h"

typedef struct thread thread;
struct trap_frame;

// Limine enters _start, which moves to the boot stack and calls kernel_main.
// It starts each other CPU at ap_start, which moves to that CPU's idle stack
// and calls ap_main with its index.
struct limine_mp_info;
[[noreturn]] void _start(void);
[[noreturn]] void kernel_main(void);
[[noreturn]] void ap_start(struct limine_mp_info *info);
[[noreturn]] void ap_main(uint32_t index);

// The entry assembly: traps land in the architecture's handler; a new thread's
// first C function is thread_entry; arch_context_switch switches kernel stacks;
// arch_enter_frame returns through a trap frame built in memory.
#ifdef __x86_64__
void x86_trap(struct trap_frame *f);
#else
void aarch64_trap(struct trap_frame *f, uint64_t index);
#endif
[[noreturn]] void thread_entry(thread *t);
void arch_context_switch(uint64_t *save_sp, uint64_t load_sp);
[[noreturn]] void arch_enter_frame(struct trap_frame *f);

// The stack protector's guard and its failure handler, used by compiled code.
extern uintptr_t __stack_chk_guard;
[[noreturn]] void __stack_chk_fail(void);
