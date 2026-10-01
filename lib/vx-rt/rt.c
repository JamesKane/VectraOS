// vx-rt: the user runtime for first-party programs (docs/04 §2): the entry
// point, syscall stubs, the spawn message, console output and the stack
// protector. A program includes this file, as its unity build, and defines
// vx_main.

#pragma once

#include "rt.h"
#include "../vx-mem/mem.c"
#include "base.c"
#include "stdio.c"

// --- Start-up ---

uintptr_t __stack_chk_guard = 0x2e0f5b3c9d81a647; // to come from the kernel's entropy (M2)

// A smashed stack ends the task: the trap is reported by the kernel.
[[noreturn]] void __stack_chk_fail(void) { __builtin_trap(); }

// Called by _start with the bootstrap channel. The thread ends with vx_main's
// return value as its exit status; what it printed without a newline goes out
// first.
[[noreturn]] void vx_start(vx_handle bootstrap) {
  vx_read_spawn(bootstrap);
  vx_handle console = vx_spawn_take("console");
  if (console && vx_console_attach(console) != VX_OK) vx_print(VX_STR("vx-rt: cannot open the console\n"));
  vx_stdio.in = vx_spawn_take("stdin");
  vx_stdio.out = vx_spawn_take("stdout");
  if (vx_stdio.out) vx_print_hook = vx_stdout_print;
  int status = vx_main();
  if (vx_print_hook == vx_stdout_print)
    vx_stdout_flush();
  else if (vx_print_hook)
    vx_console_flush();
  if (vx_stdio.out) vx_handle_close(vx_stdio.out); // the end of the file, before the exit is seen
  vx_thread_exit(status);
}

#ifdef __x86_64__
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("endbr64\n\t"
          "xorl %ebp, %ebp\n\t"
          "andq $-16, %rsp\n\t"
          "call vx_start\n\t" // the argument is already in rdi
          "ud2");
}
#else
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("hint #34\n\t" // bti c
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "bl vx_start\n\t" // the argument is already in x0
          "brk #0");
}
#endif
