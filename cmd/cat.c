// cat: prints each file named, in its namespace, or standard input without
// arguments.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

static uint8_t buf[4096];

const char *vx_main(void) {
  static vx_ns ns;
  const char *status = nullptr;
  if (vx_spawn.argc == 0) {
    int64_t n;
    while ((n = vx_read(buf, sizeof buf)) > 0) vx_print((vx_str){(const char *)buf, (size_t)n});
    return n < 0 ? "read error" : nullptr;
  }
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  for (uint32_t i = 0; i < vx_spawn.argc; i++) {
    vx_ns_file f;
    vx_status st = vx_ns_open(&ns, vx_spawn.args[i], P9_OREAD, &f);
    int64_t n = st;
    while (st == VX_OK && (n = vx_ns_read(&f, buf, sizeof buf)) > 0)
      vx_print((vx_str){(const char *)buf, (size_t)n});
    if (st == VX_OK) vx_ns_close(&f);
    if (n < 0) {
      vx_eprint(VX_STR("cat: "));
      vx_eprint(vx_spawn.args[i]);
      vx_eprint(VX_STR(": "));
      vx_eprint(p9_error_text((vx_status)n));
      vx_eprint(VX_STR("\n"));
      status = "error";
    }
  }
  return status;
}
