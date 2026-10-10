// plumb: sends a plumb message for each argument, or for standard input
// with -i, to the plumber (plumb(1), plumber(4); M7 step 7g3b), as 9front's
// plumb does: from src plumb, in the current directory, of type text.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/nsapi.c"
#include "../lib/vx-plumb/plumb.c"

static const char *usage(void) {
  vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n"));
  return "usage";
}

static char *dup_str(vx_str s) {
  char *p = vx_plumb_alloc(s.len + 1);
  if (p) memcpy(p, s.ptr, s.len), p[s.len] = 0;
  return p;
}

const char *vx_main(void) {
  char wd[VX_WD_MAX];
  size_t nwd = vx_getwd(wd, sizeof wd - 1);
  wd[nwd] = 0;
  vx_plumb_msg *m = vx_plumb_msg_new("plumb", "", wd, "text", "", 0);
  if (!m) return "no memory";
  vx_str file = VX_STR("/mnt/plumb/send");
  bool input = false;
  uint32_t i = 0;
  for (; i < vx_spawn.argc; i++) {
    vx_str a = vx_spawn.args[i];
    if (a.len != 2 || a.ptr[0] != '-') break;
    char opt = a.ptr[1];
    if (opt == 'i') {
      input = true;
      continue;
    }
    if (i + 1 == vx_spawn.argc || !vp_has("adtkpsw", opt)) return vx_plumb_free(m), usage();
    vx_str v = vx_spawn.args[++i];
    char *s = dup_str(v), **field = nullptr;
    if (!s) return vx_plumb_free(m), "no memory";
    switch (opt) {
    case 'a': m->attr = vx_plumb_add_attr(m->attr, vx_plumb_unpack_attr(s)), vx_plumb_dealloc(s); break;
    case 'p': file = v, vx_plumb_dealloc(s); break;
    case 'd': field = &m->dst; break;
    case 's': field = &m->src; break;
    case 'w': field = &m->wdir; break;
    default: field = &m->type; break; // t, and k, its old name
    }
    if (field) vx_plumb_dealloc(*field), *field = s;
  }
  if (input == (i < vx_spawn.argc)) return vx_plumb_free(m), usage();
  vx_fd fd = vx_open(file, VX_OWRITE);
  if (fd < 0) {
    vx_eprintf("plumb: can't open plumb file: %.*s\n", VX_FMT(vx_errstr()));
    return vx_plumb_free(m), "open";
  }
  if (input) { // standard input, whole, as one message: action=showdata unless one is given
    size_t cap = 8192, n = 0;
    char *data = vx_plumb_alloc(cap + 1);
    int64_t got = 1;
    while (data && got > 0) {
      if (n == cap) {
        char *more = vx_plumb_alloc(cap * 2 + 1);
        if (more) memcpy(more, data, n);
        vx_plumb_dealloc(data);
        data = more, cap *= 2;
        if (!data) break;
      }
      got = vx_stdin_read((uint8_t *)data + n, (uint32_t)(cap - n));
      if (got > 0) n += (size_t)got;
    }
    if (!data || got < 0) {
      vx_eprint(VX_STR("plumb: i/o error on input\n"));
      vx_plumb_dealloc(data), vx_plumb_free(m);
      return "read";
    }
    vx_plumb_dealloc(m->data);
    m->data = data, m->ndata = n, data[n] = 0;
    if (!vx_plumb_lookup(m->attr, "action"))
      m->attr = vx_plumb_add_attr(m->attr, vx_plumb_unpack_attr("action=showdata"));
  }
  const char *failed = nullptr;
  for (uint32_t k = i; (input && k == i) || k < vx_spawn.argc; k++) {
    if (!input) {
      vx_plumb_dealloc(m->data);
      if (!(m->data = dup_str(vx_spawn.args[k]))) return vx_plumb_free(m), "no memory";
      m->ndata = vx_spawn.args[k].len;
    }
    size_t n = 0;
    char *packed = vx_plumb_pack(m, &n);
    int64_t wrote = packed ? vx_write(fd, (vx_str){packed, n}) : -1;
    vx_plumb_dealloc(packed);
    if (wrote != (int64_t)n) {
      vx_eprintf("plumb: can't send message: %.*s\n", VX_FMT(vx_errstr()));
      failed = "error";
      break;
    }
    if (input) break;
  }
  vx_close(fd);
  vx_plumb_free(m);
  return failed;
}
