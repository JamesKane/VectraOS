// SPDX-License-Identifier: BSD-3-Clause

// A C shared object for dl-test (M5k), C because a C library is what
// dlopen loads most: a constructor, data pointing at its own strings
// (relative relocations), calls into the program that loaded it
// (dl_host_value, through the PLT) and its heap (malloc).

#include <stdlib.h>

extern int dl_host_value(void);

static int initialized;
__attribute__((constructor)) static void initialize(void) { initialized = 41; }

int dl_initialized(void) { return initialized; }
int dl_add(int a, int b) { return a + b + dl_host_value(); }

static const char *names[] = {"one", "two"};
const char *dl_name(int i) { return names[i]; }

int *dl_numbers(int n) {
  int *p = malloc(n * sizeof(int));
  for (int i = 0; i < n; i++) p[i] = i * i;
  return p;
}
