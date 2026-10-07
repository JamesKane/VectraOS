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
#include "thread.c"
#include "heap.c"

// --- Start-up and the end: the start file (crt1.c, M6 step 6e2a) ---

#include "crt1.c"
