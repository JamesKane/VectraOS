// starttest: vx-rt's start file (M6 step 6e2a, lib/vx-rt/crt1.c), run by
// rctest (tests/user/rctest.rc). Its first argument says what to do:
//   order   prints its constructors' and destructors' order around vx_main
//   args    prints its C argv, a word a line
//   exit N  ends with vx_exit(N)
//   abort   ends with vx_abort, a trap: procfs saves a crash directory
//   guard   prints its stack guard in hex: each process's its own

#include "../../lib/vx-rt/rt.c"

static char order[64];
static size_t order_len;

static void mark(const char *s) {
  vx_str t = vx_cstr(s);
  if (order_len + t.len + 1 < sizeof order) memcpy(order + order_len, t.ptr, t.len), order_len += t.len;
  order[order_len++] = ' ';
}

[[gnu::constructor(101)]] static void init_first(void) { mark("init1"); }
[[gnu::constructor(102)]] static void init_second(void) { mark("init2"); }
static bool show_fini; // order's only: the other requests print just their own

[[gnu::destructor(102)]] static void fini_second(void) {
  if (show_fini) vx_print(VX_STR("fini2\n"));
}
[[gnu::destructor(101)]] static void fini_first(void) {
  if (show_fini) vx_print(VX_STR("fini1\n"));
}

static bool is(vx_str a, const char *b) { return a.len == vx_cstr(b).len && !memcmp(a.ptr, b, a.len); }

const char *vx_main(void) {
  if (!vx_spawn.argc) return "usage: starttest order|args|exit N|abort|guard";
  vx_str what = vx_spawn.args[0];
  if (is(what, "order")) {
    mark("main");
    show_fini = true;
    vx_print((vx_str){order, order_len});
    vx_print(VX_STR("\n")); // then the destructors, after vx_main returns
    return nullptr;
  }
  if (is(what, "args")) {
    char **argv = vx_argv();
    for (int i = 0; i < vx_argc(); i++) vx_print(vx_cstr(argv[i])), vx_print(VX_STR("\n"));
    if (argv[vx_argc()]) return "argv not null-terminated";
    return nullptr;
  }
  if (is(what, "exit") && vx_spawn.argc > 1) {
    int n = 0;
    bool neg = vx_spawn.args[1].len && vx_spawn.args[1].ptr[0] == '-';
    for (size_t i = neg; i < vx_spawn.args[1].len; i++) n = n * 10 + (vx_spawn.args[1].ptr[i] - '0');
    vx_exit(neg ? -n : n);
  }
  if (is(what, "abort")) vx_abort();
  if (is(what, "guard")) {
    char hex[17];
    for (int i = 0; i < 16; i++) hex[i] = "0123456789abcdef"[(__stack_chk_guard >> (60 - 4 * i)) & 15];
    hex[16] = '\n';
    vx_print((vx_str){hex, 17});
    return nullptr;
  }
  return "unknown request";
}
