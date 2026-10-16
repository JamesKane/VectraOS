// Coroutines for RingCheck (lib/ring/check): each model thread runs on a
// stack of its own, and the checker switches between them at every memory
// operation, all on one OS thread. Host only.
#pragma once
#include <stddef.h>

typedef struct check_fiber check_fiber;

// A fiber that will run entry(argument) on a stack of `stack_size` bytes
// the first time it is resumed.
check_fiber *check_fiber_new(size_t stack_size, void (*entry)(void *), void *argument);

// Runs the fiber until it yields or its entry returns. True if it finished.
_Bool check_fiber_resume(check_fiber *fiber);

// From inside a fiber: back to whoever resumed it.
void check_fiber_yield(void);

// Frees a fiber, finished or not (an unfinished one's stack is dropped
// as it stands).
void check_fiber_free(check_fiber *fiber);
