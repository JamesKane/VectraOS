// vx-rt: the user runtime for first-party programs (docs/04 §2): the entry
// point, syscall stubs, the spawn message, console output and the stack
// protector. A program includes this file, as its unity build, and defines
// vx_main.

#pragma once

#include "rt.h"
#if defined(VX_RT_LIBC) && !defined(VX_RT_SHARED)
#include "../vx-mem/mem.h" // libvx.a (6e2b): the C library linked with it has the four
#elifdef VX_RT_SHARED
// libvx.so (6f1b1): its own four, hidden, as the program's C library keeps
// its own hidden and cannot give them to a shared library.
#pragma GCC visibility push(hidden)
#include "../vx-mem/mem.c"
#pragma GCC visibility pop
#else
#include "../vx-mem/mem.c"
#endif
#include "base.c"
#include "stdio.c"
#include "note.c"
#include "thread.c"
#include "heap.c"
#include "arena.c"
#include "proc.c"
#include "loop.c"

// --- Start-up and the end: the start file (crt1.c, M6 step 6e2a) ---

#include "crt1.c"
