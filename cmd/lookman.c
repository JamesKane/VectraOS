// lookman: the pages of the manual about every key given (man(1), docs/12
// §6.1): each record of the index (/lib/man/index) whose name, summary or
// title and keys hold every key, ignoring case, printed once a page (or node)
// as the man command that shows it, with what it is about.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-man/man.c"

static char lower(char c) { return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c; }

// Whether s holds key, ignoring ASCII case.
static bool holds(vx_str s, vx_str key) {
  for (size_t i = 0; i + key.len <= s.len; i++) {
    size_t k = 0;
    while (k < key.len && lower(s.ptr[i + k]) == lower(key.ptr[k])) k++;
    if (k == key.len) return true;
  }
  return false;
}

static char seen[512][80]; // what has been printed, as "sect page node"
static size_t seen_len[512];
static int nseen, found;

static bool each(void *arg, const vx_ndb_record *rec) {
  (void)arg;
  vx_str name = vx_ndb_get(rec, "name"), page = vx_ndb_get(rec, "page"), sect = vx_ndb_get(rec, "sect"),
         node = vx_ndb_get(rec, "node"), about = vx_ndb_get(rec, node.len ? "title" : "summary"),
         keys = vx_ndb_get(rec, "keys");
  for (uint32_t i = 0; i < vx_spawn.argc; i++) {
    vx_str key = vx_spawn.args[i];
    if (!holds(name, key) && !holds(about, key) && !holds(keys, key)) return true;
  }
  char id[80];
  if (sect.len + page.len + node.len + 3 > sizeof id) return true;
  size_t n = 0;
  memcpy(id + n, sect.ptr, sect.len), n += sect.len, id[n++] = ' ';
  memcpy(id + n, page.ptr, page.len), n += page.len;
  if (node.len) id[n++] = ' ', memcpy(id + n, node.ptr, node.len), n += node.len;
  id[n] = 0;
  for (int k = 0; k < nseen; k++)
    if (seen_len[k] == n && memcmp(seen[k], id, n) == 0) return true;
  if (nseen < (int)(sizeof seen / sizeof seen[0])) memcpy(seen[nseen], id, n), seen_len[nseen++] = n;
  vx_print(VX_STR("man "));
  vx_print((vx_str){id, n});
  vx_print(VX_STR(" # "));
  vx_print(about);
  vx_print(VX_STR("\n"));
  found++;
  return true;
}

const char *vx_main(void) {
  static vx_ns ns;
  if (!vx_spawn.argc) {
    vx_eprint(VX_STR("lookman: "));
    vx_eprint(vx_cstr(VX_USAGE));
    vx_eprint(VX_STR("\n"));
    return VX_USAGE;
  }
  if (vx_ns_from_spawn(&ns) != VX_OK) return "the namespace is incomplete";
  if (!vx_man_index(&ns, each, nullptr)) {
    vx_eprint(VX_STR("lookman: cannot read /lib/man/index\n"));
    return "no index";
  }
  return found ? nullptr : "not found";
}
