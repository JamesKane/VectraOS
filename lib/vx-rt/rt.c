// vx-rt: the user runtime for first-party programs (docs/04 §2): the entry
// point, syscall stubs, the spawn message, console output and the stack
// protector. A program includes this file, as its unity build, and defines
// vx_main.

#pragma once

#include "rt.h"
#include "../vx-mem/mem.c"
#include "base.c"
#include "stdio.c"
#include "note.c"

// --- Start-up ---

uintptr_t __stack_chk_guard = 0x2e0f5b3c9d81a647; // to come from the kernel's entropy (M2)

// A smashed stack ends the task: the trap is reported by the kernel.
[[noreturn]] void __stack_chk_fail(void) { __builtin_trap(); }

// Ends the program with msg as its exit string (empty: success), as Plan 9's
// exits does. What it printed goes out first, and its pipes close, so a
// reader sees the end of its input before the exit is seen.
[[noreturn]] static void vx_exit_str(vx_str msg) {
  if (vx_print_hook == vx_stdout_print)
    vx_stdout_flush();
  else if (vx_print_hook)
    vx_console_flush();
  vx_stderr_flush();
  if (vx_console.len) vx_console_flush();
  if (vx_stdio.out) vx_handle_close(vx_stdio.out);
  if (vx_stdio.err) vx_handle_close(vx_stdio.err);
  msg.len = vx_utf_cut(msg.ptr, msg.len, VX_ERRMAX); // whole runes (ADR-0013)
  vx_task_kill(vx_self, msg);                        // every thread: the program ends, not just this one
  vx_thread_exit();
}

// The same with a C string; nullptr is success too.
[[noreturn]] [[maybe_unused]] static void vx_exits(const char *msg) {
  vx_exit_str(msg ? vx_cstr(msg) : (vx_str){});
}

// Called by _start with the bootstrap channel. The program ends with vx_main's
// exit string.
[[noreturn]] void vx_start(vx_handle bootstrap) {
  vx_read_spawn(bootstrap);
  vx_handle console = vx_spawn_take("console");
  if (console && vx_console_attach(console) != VX_OK) vx_print(VX_STR("vx-rt: cannot open the console\n"));
  vx_stdio.in = vx_spawn_take("stdin");
  vx_stdio.out = vx_spawn_take("stdout");
  vx_stdio.err = vx_spawn_take("stderr");
  if (vx_stdio.out) vx_print_hook = vx_stdout_print;
  vx_note_exit = vx_exit_str; // a note the program's handler does not take ends it the same way
  vx_exits(vx_main());
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
