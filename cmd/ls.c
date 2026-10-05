// ls: lists each directory named (or /), its names sorted and on one line, two
// spaces apart; a file is listed as its own name.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

static char names[8192];
static vx_str list[512];

static int compare(vx_str a, vx_str b) {
  size_t n = a.len < b.len ? a.len : b.len;
  int c = memcmp(a.ptr, b.ptr, n);
  return c ? c : (a.len > b.len) - (a.len < b.len);
}

static bool ls(vx_ns *ns, vx_str path) {
  p9_client *c;
  uint32_t fid;
  p9_stat st;
  vx_status e = vx_ns_walk(ns, path, &c, &fid);
  if (e == VX_OK) {
    e = p9c_stat(c, fid, &st, nullptr);
    p9c_clunk(c, fid);
  }
  if (e != VX_OK) {
    vx_eprint(VX_STR("ls: "));
    vx_eprint(path);
    vx_eprint(VX_STR(": "));
    vx_eprint(p9_error_text(e));
    vx_eprint(VX_STR("\n"));
    return false;
  }
  if (!(st.mode & P9_DMDIR)) {
    vx_print(path);
    vx_print(VX_STR("\n"));
    return true;
  }
  vx_ns_file f;
  if (vx_ns_open(ns, path, P9_OREAD, &f) != VX_OK) return false;
  static uint8_t buf[4096];
  size_t used = 0, count = 0;
  int64_t n;
  while ((n = vx_ns_read(&f, buf, sizeof buf)) > 0) {
    p9_stat entry;
    for (size_t off = 0; p9_dir_next(buf, (size_t)n, &off, &entry);) {
      if (count == sizeof list / sizeof list[0] || entry.name.len > sizeof names - used) continue;
      memcpy(names + used, entry.name.ptr, entry.name.len);
      vx_str name = {names + used, entry.name.len};
      used += entry.name.len;
      size_t at = count++;
      for (; at > 0 && compare(list[at - 1], name) > 0; at--) list[at] = list[at - 1]; // insertion sort
      list[at] = name;
    }
  }
  vx_ns_close(&f);
  for (size_t i = 0; i < count; i++) {
    if (i) vx_print(VX_STR("  "));
    vx_print(list[i]);
  }
  vx_print(VX_STR("\n"));
  return n == 0;
}

const char *vx_main(void) {
  static vx_ns ns;
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  if (vx_spawn.argc == 0) return ls(&ns, VX_STR("/")) ? nullptr : "error";
  const char *status = nullptr;
  for (uint32_t i = 0; i < vx_spawn.argc; i++)
    if (!ls(&ns, vx_spawn.args[i])) status = "error";
  return status;
}
