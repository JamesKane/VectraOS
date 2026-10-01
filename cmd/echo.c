// echo: prints its arguments, separated by spaces, and a newline.

#include "../lib/vx-rt/rt.c"

int vx_main(void) {
  for (uint32_t i = 0; i < vx_spawn.argc; i++) {
    if (i) vx_print(VX_STR(" "));
    vx_print(vx_spawn.args[i]);
  }
  vx_print(VX_STR("\n"));
  return 0;
}
