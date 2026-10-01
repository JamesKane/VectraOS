// check.h: the host tests' one assertion. A failed check is reported and
// counted, and the test goes on, so one run shows every failure.
#pragma once

#include <stdio.h>

static int check_failures;

#define CHECK(cond) check_at((cond), #cond, __FILE__, __LINE__)

static void check_at(bool ok, const char *what, const char *file, int line) {
  if (ok) return;
  fprintf(stderr, "%s:%d: check failed: %s\n", file, line, what);
  check_failures++;
}

static int check_result(void) { return check_failures ? 1 : 0; }
