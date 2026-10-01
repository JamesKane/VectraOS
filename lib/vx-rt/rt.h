// rt.h: vx-rt's external symbols, the ones reached by name from outside C.
#pragma once

#include "../../abi/vx/abi.h"

// The kernel enters _start, which calls vx_start, which calls the program's vx_main.
[[noreturn]] void _start(void);
[[noreturn]] void vx_start(vx_handle self_task);
int vx_main(vx_handle self_task);

// The stack protector's guard and its failure handler, used by compiled code.
extern uintptr_t __stack_chk_guard;
[[noreturn]] void __stack_chk_fail(void);
