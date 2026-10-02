// rt.h: vx-rt's external symbols, the ones reached by name from outside C.
#pragma once

#include "../../abi/vx/abi.h"

// The kernel enters _start with the task's bootstrap channel. vx_start reads
// the spawn message from it (vx_spawn, vx_self) and calls the program's
// vx_main, which returns its exit string, as Plan 9's exits takes one:
// nullptr or "" for success, else why it failed (ADR-0010).
[[noreturn]] void _start(void);
[[noreturn]] void vx_start(vx_handle bootstrap);
const char *vx_main(void);

// The stack protector's guard and its failure handler, used by compiled code.
extern uintptr_t __stack_chk_guard;
[[noreturn]] void __stack_chk_fail(void);
