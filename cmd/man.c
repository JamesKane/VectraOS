// man: prints a page of the manual (man(1), docs/12-manual.md §6.1): the page
// `title`, or one node of it, from the first section that has it, refilled
// to 80 columns by lib/vx-guide. A title with no file of its own is found
// through the index, so `man lookman` prints man(1). -t prints the page's
// contents, its headings and nodes; -w its path.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-guide/guide.c"
#include "../lib/vx-man/man.c"

static char out[8192];
static size_t nout;

static void flush(void) {
  if (nout) vx_print((vx_str){out, nout});
  nout = 0;
}

static void put(void *ctx, const char *s, size_t n) {
  (void)ctx;
  for (size_t i = 0; i < n; i++) {
    if (nout == sizeof out) flush();
    out[nout++] = s[i];
  }
}

static void line(const char *lead, vx_str a, const char *mid, vx_str b) {
  vx_str l = vx_cstr(lead), m = vx_cstr(mid);
  put(nullptr, l.ptr, l.len), put(nullptr, a.ptr, a.len);
  put(nullptr, m.ptr, m.len), put(nullptr, b.ptr, b.len);
  put(nullptr, "\n", 1);
}

// -t: the headings, subheadings and nodes, one a line; a node as @id and its title.
static const char *contents(vx_str text) {
  static vx_guide g;
  if (!vx_guide_open(&g, text)) return "bad page";
  vx_guide_block b;
  vx_guide_kind k;
  while ((k = vx_guide_next(&g, &b)) > VX_GUIDE_END) {
    if (k == VX_GUIDE_HEADING) line("", b.text, "", (vx_str){});
    if (k == VX_GUIDE_SUBHEADING) line("  ", b.text, "", (vx_str){});
    if (k == VX_GUIDE_NODE) line("@", b.node, b.title.len ? " " : "", b.title);
  }
  return k == VX_GUIDE_ERROR ? "bad page" : nullptr;
}

static const char *fail(const char *why, vx_str what) {
  flush();
  vx_eprint(VX_STR("man: "));
  vx_eprint(vx_cstr(why));
  vx_eprint(what);
  vx_eprint(VX_STR("\n"));
  return why;
}

const char *vx_main(void) {
  static vx_ns ns;
  static char page[256 * 1024], path[96], node[64];
  bool toc = false, where = false;
  uint32_t i = 0;
  for (; i < vx_spawn.argc && vx_spawn.args[i].len > 1 && vx_spawn.args[i].ptr[0] == '-'; i++)
    for (size_t k = 1; k < vx_spawn.args[i].len; k++) {
      char f = vx_spawn.args[i].ptr[k];
      if (f != 't' && f != 'w') return fail(VX_USAGE, VX_STR(""));
      toc = toc || f == 't', where = where || f == 'w';
    }
  int sects[8], nsect = 0;
  while (i < vx_spawn.argc && nsect < 8 && vx_spawn.args[i].len == 1 && vx_spawn.args[i].ptr[0] >= '1' &&
         vx_spawn.args[i].ptr[0] <= '8')
    sects[nsect++] = vx_spawn.args[i++].ptr[0] - '0';
  if (i == vx_spawn.argc || vx_spawn.argc - i > 2) return fail(VX_USAGE, VX_STR(""));
  if (!nsect)
    for (int k = 1; k <= 8; k++) sects[nsect++] = k;
  if (vx_ns_from_spawn(&ns) != VX_OK) return fail("the namespace is incomplete", VX_STR(""));
  vx_str title = vx_spawn.args[i];
  size_t len = vx_man_read(&ns, title, sects, nsect, page, sizeof page, path, sizeof path);
  if (!len) return fail("no page for ", title);
  const char *status = nullptr;
  if (where) {
    line("", vx_cstr(path), "", (vx_str){});
  } else if (toc) {
    status = contents((vx_str){page, len});
  } else {
    vx_str want = i + 1 < vx_spawn.argc ? vx_spawn.args[i + 1] : (vx_str){};
    if (want.len >= sizeof node) return fail("no such node: ", want);
    memcpy(node, want.ptr, want.len);
    node[want.len] = 0;
    vx_guide_out o = {.write = put, .width = 80};
    const char *error;
    size_t at;
    if (!vx_guide_render((vx_str){page, len}, want.len ? node : nullptr, &o, &error, &at))
      return fail(error, VX_STR(""));
  }
  flush();
  return status;
}
