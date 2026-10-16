// Coroutines for RingCheck, over ucontext. C because Swift can't call
// makecontext (it is variadic). Host only.

#define _GNU_SOURCE
#include "check_context.h"

#include <stdlib.h>
#include <ucontext.h>

struct check_fiber {
  ucontext_t context;
  ucontext_t *caller;
  void (*entry)(void *);
  void *argument;
  void *stack;
  _Bool finished;
};

static _Thread_local check_fiber *current;
static _Thread_local check_fiber *starting;  // makecontext passes no pointer portably

static void trampoline(void) {
  check_fiber *fiber = starting;
  fiber->entry(fiber->argument);
  fiber->finished = 1;
  // Returning resumes uc_link: the caller of the last resume.
}

check_fiber *check_fiber_new(size_t stack_size, void (*entry)(void *), void *argument) {
  check_fiber *fiber = calloc(1, sizeof *fiber);
  fiber->stack = malloc(stack_size);
  fiber->entry = entry;
  fiber->argument = argument;
  getcontext(&fiber->context);
  fiber->context.uc_stack.ss_sp = fiber->stack;
  fiber->context.uc_stack.ss_size = stack_size;
  fiber->caller = calloc(1, sizeof(ucontext_t));
  fiber->context.uc_link = fiber->caller;
  makecontext(&fiber->context, trampoline, 0);
  return fiber;
}

_Bool check_fiber_resume(check_fiber *fiber) {
  if (fiber->finished) return 1;
  check_fiber *previous = current;
  current = fiber;
  starting = fiber;
  swapcontext(fiber->caller, &fiber->context);
  current = previous;
  return fiber->finished;
}

void check_fiber_yield(void) {
  check_fiber *fiber = current;
  swapcontext(&fiber->context, fiber->caller);
}

void check_fiber_free(check_fiber *fiber) {
  free(fiber->caller);
  free(fiber->stack);
  free(fiber);
}
