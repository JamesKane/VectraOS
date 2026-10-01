// ns: prints the namespace it was given, its parent's, as a script of mount
// and bind lines that would rebuild it (02 §2).

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

int vx_main(void) {
  static vx_ns ns;
  static char text[8192];
  if (vx_ns_from_spawn(&ns) != VX_OK) return 1;
  size_t n = vx_ns_print(&ns, text, sizeof text);
  vx_print((vx_str){text, n});
  return n ? 0 : 1;
}
