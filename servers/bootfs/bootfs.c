// bootfs: the boot image as a read-only 9Px tree (docs/01 §10, 04 §5 M2).
//
// svcd gives it the boot image (bootfs.tar, a read-only VMO) and a listen
// channel, which it posts as /srv/bootfs. bootfs maps the image, makes a node
// for each entry (and for any directory the archive only implies), and serves
// the tree over rings. Nothing is copied: a read comes straight from the
// mapped archive. Every file is read-only, whatever the archive says.
//
// An aname attaches below the root: "boot/bin" serves only that directory.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-tar/tar.c"
#include "../../lib/vx-9p/ring_server.c"

static constexpr uint32_t MAX_NODES = 1024;
static constexpr uint64_t ROOT = 1;

typedef struct node {
  vx_str name;
  uint64_t parent, first_child, next_sibling;
  bool dir;
  uint32_t mode;
  const uint8_t *data;
  uint64_t size;
} node;

static node nodes[MAX_NODES]; // 0 is unused, so a zero link means none
static uint32_t node_count = 2;
static char names[64 * 1024];
static size_t names_used;

[[noreturn]] static void fail(const char *what) {
  vx_print(VX_STR("bootfs: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
  vx_thread_exit(-1);
}

static uint64_t child_named(uint64_t dir, vx_str name) {
  for (uint64_t c = nodes[dir].first_child; c; c = nodes[c].next_sibling)
    if (nodes[c].name.len == name.len && memcmp(nodes[c].name.ptr, name.ptr, name.len) == 0) return c;
  return 0;
}

// The node for `name` in dir, made if it is not there yet. Children keep the
// archive's order.
static uint64_t add_child(uint64_t dir, vx_str name, bool is_dir) {
  uint64_t c = child_named(dir, name);
  if (c) return nodes[c].dir == is_dir ? c : 0; // a file and a directory of one name
  if (node_count == MAX_NODES || name.len > sizeof names - names_used)
    fail("the boot image has too many entries");
  memcpy(names + names_used, name.ptr, name.len);
  c = node_count++;
  nodes[c] = (node){.name = {names + names_used, name.len}, .parent = dir, .dir = is_dir, .mode = 0555};
  names_used += name.len;
  uint64_t *link = &nodes[dir].first_child;
  while (*link) link = &nodes[*link].next_sibling;
  *link = c;
  return c;
}

static void load(const uint8_t *image, size_t size) {
  nodes[ROOT] = (node){.name = VX_STR("/"), .dir = true, .mode = 0555};
  vx_tar t = vx_tar_open(image, size);
  vx_tar_entry e;
  vx_status st;
  while ((st = vx_tar_next(&t, &e)) == VX_OK) {
    uint64_t at = ROOT;
    size_t start = 0;
    for (size_t i = 0; i <= e.path.len; i++) {
      if (i < e.path.len && e.path.ptr[i] != '/') continue;
      bool last = i == e.path.len;
      at = add_child(at, (vx_str){e.path.ptr + start, i - start}, last ? e.dir : true);
      if (!at) fail("the boot image has a file and a directory with one name");
      start = i + 1;
    }
    if (!e.dir) nodes[at].data = e.data, nodes[at].size = e.size;
    nodes[at].mode = e.mode & 0555; // read-only
  }
  if (st == VX_ERR_INVALID) fail("the boot image is malformed");
}

// --- The file system ---

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  *child = child_named(dir, name);
  return *child ? VX_OK : VX_ERR_NOT_FOUND;
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  uint64_t at = ROOT;
  size_t start = 0;
  for (size_t i = 0; i <= aname.len; i++) {
    if (i < aname.len && aname.ptr[i] != '/') continue;
    vx_str part = {aname.ptr + start, i - start};
    start = i + 1;
    if (part.len == 0) continue;
    if (!p9_good_name(part) || (part.len == 2 && part.ptr[0] == '.' && part.ptr[1] == '.') ||
        fs_walk(ctx, at, part, &at) != VX_OK)
      return VX_ERR_NOT_FOUND;
  }
  if (!nodes[at].dir) return VX_ERR_NOT_FOUND;
  *root = at;
  return VX_OK;
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx;
  *parent = n == ROOT ? ROOT : nodes[n].parent;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *out) {
  (void)ctx;
  const node *x = &nodes[n];
  *out = (p9_stat){.qid = {x->dir ? P9_QTDIR : P9_QTFILE, 0, n},
                   .mode = (x->dir ? P9_DMDIR : 0) | x->mode,
                   .length = x->size,
                   .name = x->name,
                   .uid = VX_STR("boot"),
                   .gid = VX_STR("boot"),
                   .muid = VX_STR("boot")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx, (void)n;
  bool writes = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR || (mode & (P9_OTRUNC | P9_ORCLOSE));
  return writes ? VX_ERR_ACCESS : VX_OK;
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  const node *x = &nodes[n];
  uint64_t left = offset < x->size ? x->size - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  if (*count) memcpy(buf, x->data + offset, *count);
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  uint64_t c = nodes[dir].first_child;
  while (c && index--) c = nodes[c].next_sibling;
  *child = c;
  return c ? VX_OK : VX_ERR_NOT_FOUND;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir},
    .name = VX_STR("bootfs"),
};

int vx_main(void) {
  vx_handle image = vx_spawn_take("bootimage");
  server.listen = vx_spawn_take("listen");
  vx_ndb_record rec;
  uint64_t size = 0, base = 0;
  if (!image || !server.listen || !vx_spawn_record("bootimage", &rec) || !vx_ndb_get_u64(&rec, "size", &size))
    fail("no boot image or listen channel in the spawn message");
  if (vx_as_map(vx_self, image, 0, (size + 4095) & ~4095ull, 0, &base) != VX_OK)
    fail("cannot map the boot image");
  vx_handle_close(image); // the mapping keeps it
  load((const uint8_t *)base, size);

  uint32_t files = 0, dirs = 0;
  for (uint32_t i = ROOT; i < node_count; i++) nodes[i].dir ? dirs++ : files++;
  vx_print(VX_STR("bootfs: serving "));
  vx_print_u64(files);
  vx_print(VX_STR(" files in "));
  vx_print_u64(dirs);
  vx_print(VX_STR(" directories\n"));
  return p9_ring_serve(&server);
}
