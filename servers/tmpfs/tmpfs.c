// tmpfs: a file system in memory (02 §5), posted as /srv/tmpfs and mounted on
// /tmp by the POSIX template (/lib/ns/posix).
//
// Files and directories are made, written, truncated and removed as 9P has
// them, and renamed, changed (mode, size, times) and linked symbolically as
// the posix and xattr extensions have them (docs/proto/posix.md). A file's
// bytes are in a mapping of its own that grows by doubling; a symbolic
// link's are its target.
// A file removed while it is open keeps its bytes until the last fid that
// opened it lets go, as POSIX has it; a node id names one node only, so a fid
// to a removed one finds nothing. What it holds lives only in it, and is
// limited to TMPFS_MAX_BYTES and TMPFS_MAX_NODES.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"

static constexpr uint32_t TMPFS_MAX_NODES = 1024;
static constexpr uint64_t TMPFS_MAX_BYTES = 128ull << 20, TMPFS_MAX_FILE = 64ull << 20;
static constexpr uint32_t TMPFS_MAX_NAME = 128;
static constexpr uint32_t ROOT = 1;

typedef struct node {
  bool used, dir, removed, link;
  uint32_t gen; // with the slot, the node's id: a removed node's id names nothing
  char name[TMPFS_MAX_NAME];
  uint8_t name_len;
  uint32_t parent, first_child, next_sibling;
  uint32_t mode, atime, mtime, version;
  uint32_t opens; // fids that opened it: a removed file keeps its bytes until 0
  uint8_t *data;
  uint64_t size, cap;
} node;

static node nodes[TMPFS_MAX_NODES]; // 0 is unused, so a zero link means none
static uint64_t bytes_used;

static uint64_t id_of(uint32_t slot) { return (uint64_t)nodes[slot].gen << 32 | slot; }

static node *node_at(uint64_t id, uint32_t *slot) {
  uint32_t s = (uint32_t)id;
  if (s == 0 || s >= TMPFS_MAX_NODES || !nodes[s].used || nodes[s].gen != (uint32_t)(id >> 32))
    return nullptr;
  if (slot) *slot = s;
  return &nodes[s];
}

static uint32_t now_seconds(void) { return (uint32_t)(vx_clock_read() / 1'000'000'000); }

static void free_data(node *n) {
  if (n->data) vx_as_unmap(vx_self, (uint64_t)n->data, n->cap);
  bytes_used -= n->cap;
  n->data = nullptr;
  n->size = n->cap = 0;
}

static void free_node(node *n) {
  free_data(n);
  uint32_t gen = n->gen;
  *n = (node){.gen = gen + 1};
}

// Room for `size` bytes: a mapping twice as large as before, the old copied.
static vx_status reserve(node *n, uint64_t size) {
  if (size <= n->cap) return VX_OK;
  if (size > TMPFS_MAX_FILE) return VX_ERR_NO_MEMORY;
  uint64_t cap = n->cap ? n->cap : 4096;
  while (cap < size) cap *= 2;
  if (bytes_used - n->cap + cap > TMPFS_MAX_BYTES) return VX_ERR_NO_MEMORY;
  vx_handle vmo;
  uint64_t at = 0;
  vx_status st = vx_vmo_create(cap, 0, &vmo);
  if (st == VX_OK) {
    st = vx_as_map(vx_self, vmo, 0, cap, VX_MAP_WRITE, &at);
    vx_handle_close(vmo); // the mapping keeps it
  }
  if (st != VX_OK) return st;
  if (n->data) memcpy((void *)at, n->data, n->size);
  uint64_t size_was = n->size;
  free_data(n);
  n->data = (uint8_t *)at;
  n->cap = cap;
  n->size = size_was;
  bytes_used += cap;
  return VX_OK;
}

static void append_child(uint32_t dir, uint32_t s); // below, with remove

static uint32_t child_named(uint32_t dir, vx_str name) {
  for (uint32_t c = nodes[dir].first_child; c; c = nodes[c].next_sibling)
    if (nodes[c].name_len == name.len && memcmp(nodes[c].name, name.ptr, name.len) == 0) return c;
  return 0;
}

// --- The file system ---

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = id_of(ROOT);
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  uint32_t d;
  if (!node_at(dir, &d) || !nodes[d].dir) return VX_ERR_NOT_FOUND;
  uint32_t c = child_named(d, name);
  if (!c) return VX_ERR_NOT_FOUND;
  *child = id_of(c);
  return VX_OK;
}

static vx_status fs_parent(void *ctx, uint64_t id, uint64_t *parent) {
  (void)ctx;
  const node *n = node_at(id, nullptr);
  // A removed directory has no parent to go back to (its slot may hold
  // another node by now): ENOENT, as Linux answers .. in one.
  if (!n || n->removed) return VX_ERR_NOT_FOUND;
  *parent = id_of(n->parent ? n->parent : ROOT);
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t id, p9_stat *out) {
  (void)ctx;
  uint32_t s;
  const node *n = node_at(id, &s);
  if (!n) return VX_ERR_NOT_FOUND;
  *out = (p9_stat){.qid = {n->dir ? P9_QTDIR : P9_QTFILE, n->version, id},
                   .mode = (n->dir ? P9_DMDIR : 0) | (n->link ? P9_DMSYMLINK : 0) | n->mode,
                   .atime = n->atime,
                   .mtime = n->mtime,
                   .length = n->dir ? 0 : n->size,
                   .name = s == ROOT ? VX_STR("/") : (vx_str){n->name, n->name_len},
                   .uid = VX_STR("posix"),
                   .gid = VX_STR("posix"),
                   .muid = VX_STR("posix")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t id, uint8_t mode) {
  (void)ctx;
  node *n = node_at(id, nullptr);
  if (!n || (n->removed && !(mode & P9_OJOIN))) return VX_ERR_NOT_FOUND; // a join: open still, removed or not
  bool writes = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR || (mode & P9_OTRUNC);
  if (n->dir && writes) return VX_ERR_ACCESS;
  if (mode & P9_OTRUNC) {
    n->size = 0;
    n->mtime = now_seconds();
    n->version++;
  }
  n->opens++;
  return VX_OK;
}

static void fs_clunk(void *ctx, uint64_t id, bool opened) {
  (void)ctx;
  node *n = node_at(id, nullptr);
  if (!n || !opened) return;
  if (n->opens) n->opens--;
  if (n->removed && !n->opens) free_node(n); // the last of a removed file
}

static vx_status fs_read(void *ctx, uint64_t id, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  const node *n = node_at(id, nullptr);
  if (!n) return VX_ERR_NOT_FOUND;
  uint64_t left = offset < n->size ? n->size - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  if (*count) memcpy(buf, n->data + offset, *count);
  return VX_OK;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t id, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx;
  node *n = node_at(id, nullptr);
  if (!n || n->dir) return VX_ERR_ACCESS;
  uint64_t end;
  if (ckd_add(&end, offset, (uint64_t)*count)) return VX_ERR_RANGE;
  vx_status st = reserve(n, end);
  if (st != VX_OK) return st;
  if (offset > n->size) memset(n->data + n->size, 0, offset - n->size); // a hole reads as zeros
  memcpy(n->data + offset, buf, *count);
  if (end > n->size) n->size = end;
  n->mtime = now_seconds();
  n->version++;
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  uint32_t d;
  if (!node_at(dir, &d)) return VX_ERR_NOT_FOUND;
  uint32_t c = nodes[d].first_child;
  while (c && index--) c = nodes[c].next_sibling;
  if (!c) return VX_ERR_NOT_FOUND;
  *child = id_of(c);
  return VX_OK;
}

static vx_status fs_create(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode, uint64_t *out) {
  (void)ctx;
  uint32_t d;
  if (!node_at(dir, &d) || !nodes[d].dir || nodes[d].removed) return VX_ERR_NOT_FOUND;
  if (!name.len || name.len >= TMPFS_MAX_NAME) return VX_ERR_RANGE;
  if (child_named(d, name)) return VX_ERR_EXISTS;
  uint32_t s = ROOT + 1;
  while (s < TMPFS_MAX_NODES && nodes[s].used) s++;
  if (s == TMPFS_MAX_NODES) return VX_ERR_NO_MEMORY;
  node *n = &nodes[s];
  *n = (node){.used = true,
              .dir = perm & P9_DMDIR,
              .gen = n->gen,
              .name_len = (uint8_t)name.len,
              .parent = d,
              .mode = perm & 0777,
              .mtime = now_seconds(),
              .opens = 1}; // create opens it
  memcpy(n->name, name.ptr, name.len);
  if (n->dir && (mode & 3) != P9_OREAD) {
    *n = (node){.gen = n->gen};
    return VX_ERR_ACCESS;
  }
  append_child(d, s);
  *out = id_of(s);
  return VX_OK;
}

static void unlink_child(uint32_t s) {
  node *n = &nodes[s];
  for (uint32_t *link = &nodes[n->parent].first_child; *link; link = &nodes[*link].next_sibling)
    if (*link == s) {
      *link = n->next_sibling;
      break;
    }
  nodes[n->parent].mtime = now_seconds();
  n->next_sibling = 0;
}

static void append_child(uint32_t dir, uint32_t s) { // children in the order they came
  uint32_t *link = &nodes[dir].first_child;
  while (*link) link = &nodes[*link].next_sibling;
  *link = s;
  nodes[s].parent = dir;
  nodes[dir].mtime = now_seconds();
}

// A directory only when empty. The node leaves its directory at once; a file
// still open keeps its bytes until it is not (fs_clunk).
static vx_status fs_remove(void *ctx, uint64_t id) {
  (void)ctx;
  uint32_t s;
  node *n = node_at(id, &s);
  if (!n || n->removed) return VX_ERR_NOT_FOUND;
  if (s == ROOT) return VX_ERR_ACCESS;
  if (n->dir && n->first_child) return VX_ERR_EXISTS; // not empty
  unlink_child(s);
  n->removed = true;
  if (!n->opens) free_node(n);
  return VX_OK;
}

// --- The posix and xattr extensions ---

static vx_status fs_setattr(void *ctx, uint64_t id, const p9_setattr *a) {
  (void)ctx;
  node *n = node_at(id, nullptr);
  if (!n || n->removed) return VX_ERR_NOT_FOUND;
  if (a->valid & P9_SETATTR_SIZE) {
    if (n->dir || n->link) return VX_ERR_INVALID;
    vx_status st = reserve(n, a->size);
    if (st != VX_OK) return st;
    if (a->size > n->size) memset(n->data + n->size, 0, a->size - n->size);
    n->size = a->size;
    n->version++;
  }
  if (a->valid & P9_SETATTR_MODE) n->mode = a->mode & 07777;
  uint32_t now = now_seconds();
  if (a->valid & P9_SETATTR_ATIME) n->atime = a->valid & P9_SETATTR_ATIME_SET ? (uint32_t)a->atime_sec : now;
  if (a->valid & P9_SETATTR_MTIME) n->mtime = a->valid & P9_SETATTR_MTIME_SET ? (uint32_t)a->mtime_sec : now;
  if (a->valid & P9_SETATTR_SIZE && !(a->valid & P9_SETATTR_MTIME)) n->mtime = now;
  return VX_OK; // owners are not kept: uid and gid change nothing
}

// Moves olddir's entry to newdir as newname, replacing what is there as
// POSIX's rename does: a file by a file, an empty directory by a directory.
static vx_status fs_rename(void *ctx, uint64_t olddir, vx_str oldname, uint64_t newdir, vx_str newname) {
  (void)ctx;
  uint32_t from, to;
  if (!node_at(olddir, &from) || !node_at(newdir, &to) || !nodes[to].dir || nodes[to].removed)
    return VX_ERR_NOT_FOUND;
  if (newname.len >= TMPFS_MAX_NAME) return VX_ERR_RANGE;
  uint32_t s = child_named(from, oldname);
  if (!s) return VX_ERR_NOT_FOUND;
  for (uint32_t up = to; up; up = up == ROOT ? 0 : nodes[up].parent)
    if (up == s) return VX_ERR_INVALID; // into itself
  uint32_t there = child_named(to, newname);
  if (there == s) return VX_OK;
  if (there) {
    node *t = &nodes[there];
    if (t->dir != nodes[s].dir) return t->dir ? VX_ERR_EXISTS : VX_ERR_INVALID;
    if (t->dir && t->first_child) return VX_ERR_EXISTS; // not empty
    unlink_child(there);
    t->removed = true;
    if (!t->opens) free_node(t);
  }
  unlink_child(s);
  memcpy(nodes[s].name, newname.ptr, newname.len);
  nodes[s].name_len = (uint8_t)newname.len;
  append_child(to, s);
  return VX_OK;
}

static vx_status fs_symlink(void *ctx, uint64_t dir, vx_str name, vx_str target, uint64_t *out) {
  if (!target.len) return VX_ERR_INVALID;
  vx_status st = fs_create(ctx, dir, name, 0777, P9_OREAD, out);
  if (st != VX_OK) return st;
  node *n = node_at(*out, nullptr);
  n->opens = 0; // made, not opened
  n->link = true;
  st = reserve(n, target.len);
  if (st == VX_OK) {
    memcpy(n->data, target.ptr, target.len);
    n->size = target.len;
  } else {
    fs_remove(ctx, *out);
  }
  return st;
}

static vx_status fs_readlink(void *ctx, uint64_t id, vx_str *target) {
  (void)ctx;
  const node *n = node_at(id, nullptr);
  if (!n || !n->link) return VX_ERR_INVALID;
  *target = (vx_str){(const char *)n->data, n->size};
  return VX_OK;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir,
           .write = fs_write,
           .create = fs_create,
           .remove = fs_remove,
           .clunk = fs_clunk,
           .setattr = fs_setattr,
           .rename = fs_rename,
           .symlink = fs_symlink,
           .readlink = fs_readlink},
    .name = VX_STR("tmpfs"),
    .supported = P9_EXT_POSIX | P9_EXT_XATTR,
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("tmpfs: no listen channel\n"));
    return "no listen channel";
  }
  nodes[ROOT] = (node){.used = true, .dir = true, .mode = 0777, .mtime = now_seconds()};
  vx_print(VX_STR("tmpfs: serving /srv/tmpfs\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
