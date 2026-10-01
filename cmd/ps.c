// ps: one line per task in /proc: its id, then its status record.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

int vx_main(void) {
  static vx_ns ns;
  if (vx_ns_from_spawn(&ns) != VX_OK) return 1;
  vx_ns_file dir;
  if (vx_ns_open(&ns, VX_STR("/proc"), P9_OREAD, &dir) != VX_OK) {
    vx_print(VX_STR("ps: cannot read /proc\n"));
    return 1;
  }
  static uint8_t buf[4096];
  int64_t n;
  while ((n = vx_ns_read(&dir, buf, sizeof buf)) > 0) {
    for (int64_t off = 0; off + 2 <= n;) {
      uint32_t size = buf[off] | (uint32_t)buf[off + 1] << 8;
      p9_stat entry;
      if (p9_stat_decode(buf + off, size + 2, &entry) != VX_OK) break;
      off += size + 2;
      char path[64] = "/proc/";
      if (entry.name.len > sizeof path - 14) continue;
      memcpy(path + 6, entry.name.ptr, entry.name.len);
      static const char status_file[7] = {'/', 's', 't', 'a', 't', 'u', 's'}; // a path piece, not a C string
      memcpy(path + 6 + entry.name.len, status_file, sizeof status_file);
      vx_ns_file f;
      char status[256];
      int64_t got = 0;
      if (vx_ns_open(&ns, (vx_str){path, 13 + entry.name.len}, P9_OREAD, &f) == VX_OK) {
        got = vx_ns_read(&f, status, sizeof status);
        vx_ns_close(&f);
      }
      if (got <= 0) continue; // it has gone meanwhile
      vx_print(VX_STR("id="));
      vx_print(entry.name);
      vx_print(VX_STR(" "));
      vx_print((vx_str){status, (size_t)got});
    }
  }
  vx_ns_close(&dir);
  return 0;
}
