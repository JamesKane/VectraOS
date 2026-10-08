// dltest: a dynamic program (M6 step 6f1a, ADR-0047), linked against
// libdltesta.so, which needs libdltestb.so. /lib/ld-vx loads and binds the
// three, and vx-rt runs the libraries' constructors and lays out every
// object's thread-local storage, in a second thread too.

#include "../../lib/vx-rt/rt.c"
#include "dltest.h"

static thread_local int exe_tls = 3;
static int checks, failures;

static void check(bool ok, const char *what) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("dltest: FAILED "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

static bool eq(const char *a, const char *b) {
  vx_str x = vx_cstr(a), y = vx_cstr(b);
  return x.len == y.len && memcmp(x.ptr, y.ptr, x.len) == 0;
}

// Each thread's own copies: as the images set them, then bumped once.
static void tls_round(void *arg) {
  int *ok = arg;
  *ok = exe_tls == 3 && a_tls_bump() == 101 && a_b_tls() == 8;
}

const char *vx_main(void) {
  vx_print(VX_STR("dltest: hello from a dynamic program\n"));
  check(vx_dl && vx_dl->object_count == 3, "three objects loaded");
  check(vx_dl && eq(vx_dl->objects[1].name, "libdltesta.so") && eq(vx_dl->objects[2].name, "libdltestb.so"),
        "loaded breadth first");
  check(a_compute(2) == 84, "a call through a pointer bound at load");
  check(a_counter == 5, "data copied into the program");
  a_counter = 6;
  check(a_counter == 6, "the copy is the program's to change");
  check(a_greeting && eq(a_greeting, "hello"), "a copied pointer, relocated in its library first");
  check(eq(a_name(1), "two"), "relative relocations");
  check(a_inits_seen == 1, "b's constructor before a's");
  int ok = 0;
  tls_round(&ok);
  check(ok, "TLS in the first thread");
  check(a_tls_bump() == 102 && exe_tls == 3, "TLS kept");
  vx_thread t;
  int ok2 = 0;
  check(vx_thread_spawn(&t, tls_round, &ok2, 0) == VX_OK, "a second thread");
  vx_thread_join(&t);
  check(ok2, "TLS in a second thread: fresh copies");
  vx_print(VX_STR("dltest: "));
  vx_print_u64((uint64_t)checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64((uint64_t)failures);
  vx_print(VX_STR(" failed\n"));
  return failures ? "dltest: FAILED" : nullptr;
}
