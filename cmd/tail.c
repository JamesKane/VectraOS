// tail [-N] [file]: prints the last N lines (10 unless given) of the file, or
// of standard input.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

static char text[64 * 1024]; // the end of the input, as a ring
static uint64_t total;

static void take(const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++) text[total++ % sizeof text] = (char)p[i];
}

const char *vx_main(void) {
  uint64_t lines = 10;
  uint32_t arg = 0;
  if (vx_spawn.argc > 0 && vx_spawn.args[0].len > 1 && vx_spawn.args[0].ptr[0] == '-') {
    lines = 0;
    for (size_t i = 1; i < vx_spawn.args[0].len; i++) {
      char c = vx_spawn.args[0].ptr[i];
      if (c < '0' || c > '9' || lines > 100000) {
        vx_eprint(VX_STR("usage: tail [-N] [file]\n"));
        return "usage";
      }
      lines = lines * 10 + (uint64_t)(c - '0');
    }
    arg = 1;
  }
  static uint8_t buf[4096];
  int64_t n;
  if (arg < vx_spawn.argc) {
    static vx_ns ns;
    vx_ns_file f;
    if (vx_ns_from_spawn(&ns) != VX_OK || vx_ns_open(&ns, vx_spawn.args[arg], P9_OREAD, &f) != VX_OK) {
      vx_eprint(VX_STR("tail: cannot open it\n"));
      return "cannot open";
    }
    while ((n = vx_ns_read(&f, buf, sizeof buf)) > 0) take(buf, (size_t)n);
    vx_ns_close(&f);
  } else {
    while ((n = vx_read(buf, sizeof buf)) > 0) take(buf, (size_t)n);
  }

  // Back from the end to the start of the last `lines` lines: past that many
  // newlines, not counting one that ends the input.
  uint64_t floor = total < sizeof text ? 0 : total - sizeof text, start = total, seen = 0;
  while (lines && start > floor) {
    if (start != total && text[(start - 1) % sizeof text] == '\n' && ++seen == lines) break;
    start--;
  }
  for (uint64_t i = start; i < total; i++) vx_print((vx_str){&text[i % sizeof text], 1});
  return nullptr;
}
