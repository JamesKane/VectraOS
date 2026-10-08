// dltest_b: libdltestb.so, the library dltest's other library needs (M6 step
// 6f1a, ADR-0047): data, thread-local storage and a constructor, needing
// nothing itself.

#include "dltest.h"

thread_local int b_tls = 7;
int b_value = 40;
int b_inits;

[[gnu::constructor]] static void b_init(void) { b_inits++; }

int b_add(int x) { return x + b_value; }

int b_tls_bump(void) { return ++b_tls; }
