// constest: the console test, run as a service in the cons scenario
// (tests/qemu/cons.ndb). It reads cooked lines from the console driver and
// prints each back in brackets; "flood" makes it print more than the driver's
// output queue holds, so writes must wait for the UART; end of file ends it.

#include "../../lib/vx-rt/rt.c"

const char *vx_main(void) {
  vx_print(VX_STR("constest: ready\n"));
  char line[300];
  for (;;) {
    int64_t n = vx_console_read(line, sizeof line);
    if (n == 0) break;
    if (n < 0) {
      vx_print(VX_STR("constest: FAILED to read the console\n"));
      return "cannot read the console";
    }
    size_t len = (size_t)n;
    if (len && line[len - 1] == '\n') len--;
    vx_print(VX_STR("constest: got ["));
    vx_print((vx_str){line, len});
    vx_print(VX_STR("]\n"));
    if (len == 5 && memcmp(line, "flood", 5) == 0) {
      for (uint64_t i = 0; i < 300; i++) {
        vx_print(VX_STR("constest: line "));
        vx_print_u64(i);
        vx_print(VX_STR(" ......................................\n"));
      }
      vx_print(VX_STR("constest: flood done\n"));
    }
  }
  vx_print(VX_STR("constest: end of file\n"));
  return nullptr;
}
