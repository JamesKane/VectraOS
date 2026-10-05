// sig: the C declarations of the functions named, from the SYNOPSIS of their
// section 2 pages (man(1), docs/12 §6.1), for pasting into code, as Plan 9's
// sig prints them. A name is a page's (futex_wait) or its C function's
// (vx_futex_wait).

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-guide/guide.c"
#include "../lib/vx-man/man.c"

static bool ident(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

// Whether the declaration d declares `name` (or vx_name): it is the
// identifier just before the first (.
static bool declares(vx_str d, vx_str name) {
  size_t p = 0;
  while (p < d.len && d.ptr[p] != '(') p++;
  size_t e = p;
  while (e && d.ptr[e - 1] == ' ') e--;
  size_t s = e;
  while (s && ident(d.ptr[s - 1])) s--;
  vx_str id = {d.ptr + s, e - s};
  if (p == d.len || !id.len) return false;
  return vx_man_eq(id, name) || (id.len == name.len + 3 && memcmp(id.ptr, "vx_", 3) == 0 &&
                                 memcmp(id.ptr + 3, name.ptr, name.len) == 0);
}

// Each declaration of the fence (up to a ;) that declares name, printed on one line.
static int print_decls(vx_str fence, vx_str name) {
  int n = 0;
  for (size_t at = 0; at < fence.len;) {
    size_t end = at;
    while (end < fence.len && fence.ptr[end] != ';') end++;
    vx_str d = {fence.ptr + at, end - at};
    while (d.len && (d.ptr[0] == ' ' || d.ptr[0] == '\n')) d.ptr++, d.len--;
    if (end < fence.len && declares(d, name)) {
      static char one[1024];
      size_t k = 0;
      for (size_t i = 0; i < d.len && k + 2 < sizeof one; i++) {
        bool space = d.ptr[i] == ' ' || d.ptr[i] == '\n';
        if (space && (!k || one[k - 1] == ' ')) continue;
        one[k++] = space ? ' ' : d.ptr[i];
      }
      one[k++] = ';', one[k++] = '\n';
      vx_print((vx_str){one, k});
      n++;
    }
    at = end + 1;
  }
  return n;
}

static int sig(vx_ns *ns, vx_str name) {
  static char page[256 * 1024], path[96];
  static const int two[] = {2};
  size_t len = vx_man_read(ns, name, two, 1, page, sizeof page, path, sizeof path);
  if (!len && name.len > 3 && memcmp(name.ptr, "vx_", 3) == 0)
    len = vx_man_read(ns, (vx_str){name.ptr + 3, name.len - 3}, two, 1, page, sizeof page, path, sizeof path);
  static vx_guide g;
  if (!len || !vx_guide_open(&g, (vx_str){page, len})) return 0;
  vx_guide_block b;
  bool synopsis = false;
  int n = 0;
  while (vx_guide_next(&g, &b) > VX_GUIDE_END) {
    if (b.kind == VX_GUIDE_HEADING || b.kind == VX_GUIDE_NODE)
      synopsis = b.kind == VX_GUIDE_HEADING && vx_man_eq(b.text, VX_STR("SYNOPSIS"));
    if (synopsis && b.kind == VX_GUIDE_FENCE && vx_man_eq(b.fence, VX_STR("c")))
      n += print_decls(b.text, name);
  }
  return n;
}

const char *vx_main(void) {
  static vx_ns ns;
  if (!vx_spawn.argc) {
    vx_eprint(VX_STR("sig: "));
    vx_eprint(vx_cstr(VX_USAGE));
    vx_eprint(VX_STR("\n"));
    return VX_USAGE;
  }
  if (vx_ns_from_spawn(&ns) != VX_OK) return "the namespace is incomplete";
  const char *status = nullptr;
  for (uint32_t i = 0; i < vx_spawn.argc; i++)
    if (!sig(&ns, vx_spawn.args[i])) {
      vx_eprint(VX_STR("sig: no declaration of "));
      vx_eprint(vx_spawn.args[i]);
      vx_eprint(VX_STR("\n"));
      status = "not found";
    }
  return status;
}
