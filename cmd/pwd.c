// pwd: prints the current directory (ADR-0039), as 9front's pwd.

#include "../lib/vx-rt/rt.c"

const char *vx_main(void) {
  if (vx_spawn.argc) {
    vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n"));
    return "usage";
  }
  char wd[VX_WD_MAX];
  size_t n = vx_getwd(wd, sizeof wd);
  vx_print((vx_str){wd, n});
  vx_print(VX_STR("\n"));
  return nullptr;
}
