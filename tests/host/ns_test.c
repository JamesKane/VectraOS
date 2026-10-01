// ns_test.c: lib/vx-ns against two in-memory 9P servers: lexical path
// cleaning, mount and bind with each flag, union directories (walks and
// reads), longest-prefix matching at component boundaries, unmount, and ns
// output that replays.
//
//   boot server:  /bin/  /boot/bin/ls  /boot/bin/cat  /dev/  /readme
//   dev server:   /cons  /null

#include <string.h>

#include "check.h"
#include "../../lib/vx-9p/server.c"
#include "../../lib/vx-ns/ns.c"

typedef struct tnode {
  uint64_t parent;
  const char *name;
  bool dir;
  const char *data;
} tnode;

typedef struct tree {
  const tnode *nodes;
  uint64_t count;
} tree;

static const tnode BOOT[] = {
    {},
    {0, "/", true, nullptr},
    {1, "bin", true, nullptr},
    {1, "boot", true, nullptr},
    {3, "bin", true, nullptr},
    {4, "ls", false, "ls!"},
    {4, "cat", false, "cat!"},
    {1, "dev", true, nullptr},
    {1, "readme", false, "hello"},
};
static const tnode DEV[] = {
    {}, {0, "/", true, nullptr}, {1, "cons", false, "console"}, {1, "null", false, ""}};
static tree boot_tree = {BOOT, sizeof BOOT / sizeof BOOT[0]}, dev_tree = {DEV, sizeof DEV / sizeof DEV[0]};

static vx_status t_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = 1;
  return VX_OK;
}

static vx_status t_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  const tree *t = ctx;
  for (uint64_t i = 2; i < t->count; i++)
    if (t->nodes[i].parent == dir && strlen(t->nodes[i].name) == name.len &&
        memcmp(t->nodes[i].name, name.ptr, name.len) == 0) {
      *child = i;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status t_parent(void *ctx, uint64_t node, uint64_t *parent) {
  const tree *t = ctx;
  *parent = t->nodes[node].parent ? t->nodes[node].parent : 1;
  return VX_OK;
}

static vx_status t_stat(void *ctx, uint64_t node, p9_stat *out) {
  const tree *t = ctx;
  const tnode *n = &t->nodes[node];
  *out = (p9_stat){.qid = {n->dir ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = n->dir ? P9_DMDIR | 0555 : 0444,
                   .length = n->data ? strlen(n->data) : 0,
                   .name = {n->name, strlen(n->name)}};
  return VX_OK;
}

static vx_status t_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx, (void)node;
  return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
}

static vx_status t_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  const tree *t = ctx;
  size_t len = strlen(t->nodes[node].data);
  uint32_t n = offset >= len ? 0 : (uint32_t)(len - offset);
  if (n > *count) n = *count;
  memcpy(buf, t->nodes[node].data + (n ? offset : 0), n);
  *count = n;
  return VX_OK;
}

static vx_status t_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  const tree *t = ctx;
  for (uint64_t i = 2; i < t->count; i++)
    if (t->nodes[i].parent == dir && index-- == 0) {
      *child = i;
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static p9_server make_server(tree *t) {
  return (p9_server){.fs = {.ctx = t,
                            .attach = t_attach,
                            .walk = t_walk,
                            .parent = t_parent,
                            .stat = t_stat,
                            .open = t_open,
                            .read = t_read,
                            .readdir = t_readdir},
                     .max_msize = 8192};
}

static p9_server boot_srv, dev_srv;
static uint8_t bufs[4][8192];
static p9_client boot_c, dev_c;

static size_t loopback(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  return p9_serve(ctx, req, len, resp, cap);
}

// A client of s whose buffers are bufs[pair] and bufs[pair + 1].
static void connect(p9_client *c, p9_server *s, int pair) {
  *c = (p9_client){.rpc = loopback, .ctx = s, .tbuf = bufs[pair], .rbuf = bufs[pair + 1], .bufsize = 8192};
  CHECK(p9c_version(c, 8192, 0) == VX_OK);
}

static bool exists(vx_ns *ns, const char *path) {
  p9_client *c;
  uint32_t fid;
  if (vx_ns_walk(ns, (vx_str){path, strlen(path)}, &c, &fid) != VX_OK) return false;
  p9c_clunk(c, fid);
  return true;
}

// The names in a directory, as "a b c", reading through the namespace.
static const char *list(vx_ns *ns, const char *path) {
  static char out[256];
  size_t len = 0;
  vx_ns_file f;
  if (vx_ns_open(ns, (vx_str){path, strlen(path)}, P9_OREAD, &f) != VX_OK) return "(cannot open)";
  uint8_t buf[2048];
  int64_t n;
  while ((n = vx_ns_read(&f, buf, sizeof buf)) > 0) {
    for (int64_t off = 0; off + 2 <= n;) {
      uint32_t size = buf[off] | (uint32_t)buf[off + 1] << 8;
      p9_stat st;
      if (p9_stat_decode(buf + off, size + 2, &st) != VX_OK) return "(bad stat)";
      if (len) out[len++] = ' ';
      memcpy(out + len, st.name.ptr, st.name.len);
      len += st.name.len;
      off += size + 2;
    }
  }
  vx_ns_close(&f);
  out[len] = 0;
  return n < 0 ? "(read failed)" : out;
}

static bool clean_is(const char *in, const char *want) {
  char out[64];
  size_t n = vx_ns_clean((vx_str){in, strlen(in)}, out, sizeof out);
  return n == strlen(want) && memcmp(out, want, n) == 0;
}

static void test_clean(void) {
  CHECK(clean_is("/", "/"));
  CHECK(clean_is("//a//b/", "/a/b"));
  CHECK(clean_is("/a/./b/../c", "/a/c"));
  CHECK(clean_is("/../../x", "/x"));
  CHECK(clean_is("/a/..", "/"));
  CHECK(clean_is("/..", "/"));
  char out[8];
  CHECK(vx_ns_clean(VX_STR("relative"), out, sizeof out) == 0);
  CHECK(vx_ns_clean(VX_STR(""), out, sizeof out) == 0);
  CHECK(vx_ns_clean(VX_STR("/abcdefghij"), out, sizeof out) == 0); // does not fit
}

static void test_namespace(void) {
  static vx_ns ns;
  boot_srv = make_server(&boot_tree);
  dev_srv = make_server(&dev_tree);
  connect(&boot_c, &boot_srv, 0);
  connect(&dev_c, &dev_srv, 2);

  CHECK(!exists(&ns, "/")); // empty
  CHECK(vx_ns_mount(&ns, &boot_c, VX_HANDLE_NONE, VX_STR("/srv/bootfs"), VX_STR(""), VX_STR("/bin"), 0) ==
        VX_ERR_NOT_FOUND); // nothing at /bin to mount on yet
  CHECK(vx_ns_mount(&ns, &boot_c, VX_HANDLE_NONE, VX_STR("/srv/bootfs"), VX_STR(""), VX_STR("/"), 0) ==
        VX_OK);
  CHECK(strcmp(list(&ns, "/"), "bin boot dev readme") == 0);
  CHECK(exists(&ns, "/boot/bin/ls") && !exists(&ns, "/bin/ls"));
  CHECK(exists(&ns, "/bin/../boot/bin/../../readme")); // lexical ..
  CHECK(exists(&ns, "/../../../readme"));

  // bind -a: the union of what was at /bin, then /boot/bin.
  CHECK(vx_ns_bind(&ns, VX_STR("/boot/bin"), VX_STR("/bin"), VX_NS_AFTER) == VX_OK);
  CHECK(exists(&ns, "/bin/ls") && exists(&ns, "/bin/cat"));
  CHECK(strcmp(list(&ns, "/bin"), "ls cat") == 0); // the old /bin is empty
  CHECK(!exists(&ns, "/binary") && !exists(&ns, "/bin/nope"));

  // Reading a file through a bind.
  vx_ns_file f;
  char text[16] = {};
  CHECK(vx_ns_open(&ns, VX_STR("/bin/cat"), P9_OREAD, &f) == VX_OK);
  CHECK(vx_ns_read(&f, text, 2) == 2 && vx_ns_read(&f, text + 2, 10) == 2 && vx_ns_read(&f, text, 10) == 0);
  CHECK(memcmp(text, "cat!", 4) == 0);
  vx_ns_close(&f);
  CHECK(vx_ns_open(&ns, VX_STR("/bin/cat"), P9_OWRITE, &f) == VX_ERR_ACCESS);

  // A second server, after what is at /dev; then one before it.
  CHECK(vx_ns_mount(&ns, &dev_c, VX_HANDLE_NONE, VX_STR("/srv/cons"), VX_STR(""), VX_STR("/dev"),
                    VX_NS_AFTER) == VX_OK);
  CHECK(exists(&ns, "/dev/cons") && strcmp(list(&ns, "/dev"), "cons null") == 0);
  CHECK(vx_ns_bind(&ns, VX_STR("/boot"), VX_STR("/dev"), VX_NS_BEFORE) == VX_OK);
  CHECK(strcmp(list(&ns, "/dev"), "bin cons null") == 0);
  CHECK(exists(&ns, "/dev/bin/ls"));

  char out[512];
  size_t n = vx_ns_print(&ns, out, sizeof out);
  static const char want[] = "mount /srv/bootfs /\n"
                             "bind /bin /bin\n"
                             "bind -a /boot/bin /bin\n"
                             "bind /boot /dev\n"
                             "bind -a /dev /dev\n"
                             "mount -a /srv/cons /dev\n";
  CHECK(n == sizeof want - 1 && memcmp(out, want, n) == 0);
  CHECK(vx_ns_print(&ns, out, 10) == 0);

  // unmount one member, then a whole entry; replace with a plain bind.
  CHECK(vx_ns_unmount(&ns, VX_STR("/boot/bin"), VX_STR("/bin")) == VX_OK);
  CHECK(!exists(&ns, "/bin/ls") && exists(&ns, "/bin"));
  CHECK(vx_ns_unmount(&ns, VX_STR("/nothing"), VX_STR("/bin")) == VX_ERR_NOT_FOUND);
  CHECK(vx_ns_unmount(&ns, VX_STR(""), VX_STR("/dev")) == VX_OK);
  CHECK(!exists(&ns, "/dev/cons") && strcmp(list(&ns, "/dev"), "") == 0);
  CHECK(vx_ns_bind(&ns, VX_STR("/boot/bin"), VX_STR("/dev"), VX_NS_REPLACE) == VX_OK);
  CHECK(strcmp(list(&ns, "/dev"), "ls cat") == 0);
  CHECK(vx_ns_bind(&ns, VX_STR("/missing"), VX_STR("/dev"), 0) == VX_ERR_NOT_FOUND);
  CHECK(vx_ns_bind(&ns, VX_STR("relative"), VX_STR("/dev"), 0) == VX_ERR_INVALID);

  // Every fid the namespace dropped was clunked: only the members' own remain.
  uint32_t live = 0;
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++) live += boot_srv.fids[i].used + dev_srv.fids[i].used;
  uint32_t members = 0;
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++)
    if (ns.entries[i].path_len) members += ns.entries[i].count;
  CHECK(live == members);
}

int main(void) {
  test_clean();
  test_namespace();
  return check_result();
}
