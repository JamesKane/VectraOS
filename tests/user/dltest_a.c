// dltest_a: libdltesta.so, the library dltest links (M6 step 6f1a, ADR-0047),
// which needs libdltestb.so: a call into it through a pointer bound at load,
// pointers in its data (relative relocations), data the program copies,
// thread-local storage, and a constructor that runs after b's.

#include "dltest.h"

thread_local int a_tls = 100;
int a_counter = 5;
int (*a_fn)(int) = b_add;
static const char *const a_names[] = {"one", "two"};
int a_inits_seen = -1;

[[gnu::constructor]] static void a_init(void) { a_inits_seen = b_inits; }

int a_compute(int x) { return a_fn(x) * 2; }

int a_tls_bump(void) { return ++a_tls; }

int a_b_tls(void) { return b_tls_bump(); }

const char *a_name(int i) { return a_names[i & 1]; }
