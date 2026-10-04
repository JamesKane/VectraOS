// distd: the content store and the releases in it, served as /dist (docs/06
// §4, §11; M5 step 9b). The store is files on the system volume's store
// branch, mounted in distd's namespace at /n (its manifest's mount=, over
// bootfs at /): objects as b2/xx/<hex>, release records as records/*.ndb.
//
//   service=distd program=/boot/bin/distd post=dist console
//   mount=/ srv=bootfs
//   mount=/n srv=fsd aname=store
//
// It serves:
//
//   /dist/status              state=idle releases=N arch=ARCH
//   /dist/ctl                 (write) rescan: the records read again
//   /dist/releases/N/record   the release's record, as it is in the store
//   /dist/releases/N/status   state=fetched missing=0 (or state=seen missing=M)
//   /dist/releases/N/tree/    the release's base tree for this architecture,
//                             read-only, every block checked against its
//                             file's index, and the index against its name,
//                             before a byte of it is returned (verified reads)
//   /dist/store/              the objects, read-only, as they are: what peers read
//
// A block that does not match is an IO error, said once on the console with
// the file's path; nothing of it is returned. The running system's base
// stays bootfs's: serving from the store, not switching to it (06 §3.1;
// decided 2026-10-04).

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-ns/spawn.c"
#include "../../lib/vx-store/store.c"

#ifdef __x86_64__
static const char ARCH[] = "x86_64";
#else
static const char ARCH[] = "aarch64";
#endif

static vx_ns ns;

[[noreturn]] static void fail(const char *what, vx_status st) {
  vx_print(VX_STR("distd: FAILED: "));
  vx_print(vx_cstr(what));
  if (st != VX_OK) {
    vx_print(VX_STR(": "));
    vx_print(p9_error_text(st));
  }
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

// --- Objects, from the store branch ---

static constexpr uint32_t OBJ_MAX =
    VX_STORE_BLOCK + 4096; // a block; an index or directory of a few thousand entries
static constexpr uint32_t CACHE = 24;

typedef struct cached {
  vx_hash name;
  uint64_t last;
  uint32_t len;
  bool valid;
  uint8_t data[OBJ_MAX];
} cached;

static cached cache[CACHE];
static uint64_t tick;

// An object's bytes, read whole from the store (/n): nullptr and *st if it cannot be.
// What comes back is the store's as it is; its caller checks it against its
// name, and only checked objects are kept (check()).
static const uint8_t *object(const vx_hash *name, uint32_t *len, vx_status *st) {
  for (uint32_t i = 0; i < CACHE; i++)
    if (cache[i].valid && vx_hash_eq(&cache[i].name, name)) {
      cache[i].last = ++tick;
      *len = cache[i].len;
      return cache[i].data;
    }
  uint32_t victim = 0;
  for (uint32_t i = 0; i < CACHE; i++)
    if (!cache[i].valid || cache[i].last < cache[victim].last) victim = i;
  cached *c = &cache[victim];
  char path[3 + 71] = "/n/";
  vx_store_path(name, path + 3);
  vx_ns_file f;
  if ((*st = vx_ns_open(&ns, vx_cstr(path), P9_OREAD, &f)) != VX_OK) return nullptr;
  uint32_t n = 0;
  int64_t got;
  while (n < OBJ_MAX && (got = vx_ns_read(&f, c->data + n, OBJ_MAX - n > 65536 ? 65536 : OBJ_MAX - n)) > 0)
    n += (uint32_t)got;
  vx_ns_close(&f);
  if (n == OBJ_MAX) {
    *st = VX_ERR_RANGE; // larger than any object distd reads whole
    return nullptr;
  }
  c->valid = false; // until it is checked
  c->name = *name, c->len = n, c->last = ++tick;
  *len = n;
  return c->data;
}

// The object just read, kept: it was checked against its name.
static void keep(const vx_hash *name) {
  for (uint32_t i = 0; i < CACHE; i++)
    if (!cache[i].valid && cache[i].len && vx_hash_eq(&cache[i].name, name)) cache[i].valid = true;
}

static bool is_kept(const vx_hash *name) {
  for (uint32_t i = 0; i < CACHE; i++)
    if (cache[i].valid && vx_hash_eq(&cache[i].name, name)) return true;
  return false;
}

static void said_bad(const char *what, vx_str path) {
  vx_print(VX_STR("distd: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR(" does not match its hash: "));
  vx_print(path);
  vx_print(VX_STR(" (refused)\n"));
}

// A directory object, checked.
static const uint8_t *dir_object(const vx_hash *name, uint32_t *len, vx_status *st) {
  bool kept = is_kept(name);
  const uint8_t *d = object(name, len, st);
  if (!d || kept) return d;
  if (vx_store_dir_check(name, d, *len) != VX_OK) {
    *st = VX_ERR_IO;
    return nullptr;
  }
  keep(name);
  return d;
}

// --- Releases ---

typedef struct release {
  uint64_t seq;
  vx_hash tree; // this architecture's base tree
  char record[16384];
  uint32_t record_len;
} release;

static release releases[16];
static uint32_t nreleases;

static void rescan(void) {
  nreleases = 0;
  vx_ns_file dir;
  if (vx_ns_open(&ns, VX_STR("/n/records"), P9_OREAD, &dir) != VX_OK) return;
  static uint8_t listing[8192];
  int64_t n;
  while ((n = vx_ns_read(&dir, listing, sizeof listing)) > 0) {
    p9_stat e;
    for (size_t off = 0; p9_dir_next(listing, (size_t)n, &off, &e) && nreleases < 16;) {
      if (e.name.len < 5 || memcmp(e.name.ptr + e.name.len - 4, ".ndb", 4) != 0 || e.length > 16384) continue;
      char path[96] = "/n/records/";
      if (e.name.len > sizeof path - 12) continue;
      memcpy(path + 11, e.name.ptr, e.name.len);
      path[11 + e.name.len] = 0;
      release *r = &releases[nreleases];
      vx_ns_file f;
      if (vx_ns_open(&ns, vx_cstr(path), P9_OREAD, &f) != VX_OK) continue;
      uint32_t len = 0;
      int64_t got;
      while (len < 16384 && (got = vx_ns_read(&f, r->record + len, 16384 - len)) > 0) len += (uint32_t)got;
      vx_ns_close(&f);
      r->record_len = len;
      // release=N ...; set=base arch=ARCH tree=b2:...
      static char scratch[16384];
      vx_ndb_reader rd = {.src = {r->record, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
      vx_ndb_record rec;
      bool have_seq = false, have_tree = false;
      while (vx_ndb_next(&rd, &rec) == VX_NDB_RECORD) {
        rd.scratch_used = 0;
        if (vx_ndb_has(&rec, "release")) have_seq = vx_ndb_get_u64(&rec, "release", &r->seq);
        vx_str set = vx_ndb_get(&rec, "set"), arch = vx_ndb_get(&rec, "arch");
        if (set.len == 4 && memcmp(set.ptr, "base", 4) == 0 && arch.len == sizeof ARCH - 1 &&
            memcmp(arch.ptr, ARCH, arch.len) == 0)
          have_tree = vx_store_parse(vx_ndb_get(&rec, "tree"), &r->tree);
      }
      if (have_seq && have_tree) nreleases++;
    }
  }
  vx_ns_close(&dir);
}

static release *release_of(uint64_t seq) {
  for (uint32_t i = 0; i < nreleases; i++)
    if (releases[i].seq == seq) return &releases[i];
  return nullptr;
}

// --- Nodes ---
//
// /dist's files, the releases' directories, and every tree entry and store
// object a walk or a listing reaches, each a slot here, found again by its
// parent and name. Never let go: a long-running distd fills it (a known gap).

enum kind : uint8_t {
  K_ROOT = 1,
  K_STATUS,
  K_CTL,
  K_RELEASES,
  K_RELEASE,
  K_RECORD,
  K_RSTATUS,
  K_TREE,   // an entry of a release's tree (or the tree's root)
  K_STORE,  // /dist/store and its directories
  K_OBJECT, // an object under it
};

typedef struct node {
  uint8_t kind;
  uint32_t parent;
  uint64_t seq;     // its release's
  vx_store_entry e; // a tree entry's (its strings in name and target below)
  char name[256];   // a tree entry's, or a store path component
  char target[256]; // a link's
  char path[80];    // a store directory's or object's path under /store ("b2/9f")
} node;

static constexpr uint32_t MAX_NODES = 8192;
static node nodes[MAX_NODES];
static uint32_t nnodes;

static bool same(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

static uint32_t add_node(node n) {
  for (uint32_t i = 1; i < nnodes; i++)
    if (nodes[i].kind == n.kind && nodes[i].parent == n.parent && nodes[i].seq == n.seq &&
        same(nodes[i].name, n.name) && same(nodes[i].path, n.path))
      return i;
  if (nnodes == MAX_NODES) return 0;
  nodes[nnodes] = n;
  return nnodes++;
}

static node *node_of(uint64_t id) { return id && id < nnodes ? &nodes[id] : nullptr; }

static uint32_t fixed(uint8_t kind, uint32_t parent, uint64_t seq, const char *name) {
  node n = {.kind = kind, .parent = parent, .seq = seq};
  memcpy(n.name, name, vx_cstr(name).len + 1);
  return add_node(n);
}

// A tree entry as a node under parent.
static uint32_t tree_node(uint32_t parent, uint64_t seq, const vx_store_entry *e) {
  node n = {.kind = K_TREE, .parent = parent, .seq = seq, .e = *e};
  if (e->name.len >= sizeof n.name || e->link.len >= sizeof n.target) return 0;
  memcpy(n.name, e->name.ptr, e->name.len);
  memcpy(n.target, e->link.ptr, e->link.len);
  n.e.name = (vx_str){}, n.e.link = (vx_str){}; // they pointed into a scratch buffer
  return add_node(n);
}

static bool is_dir(const node *n) {
  if (n->kind == K_TREE) return vx_store_is_dir(&n->e);
  if (n->kind == K_OBJECT) return false;
  return n->kind == K_ROOT || n->kind == K_RELEASES || n->kind == K_RELEASE || n->kind == K_STORE;
}

// The path of a tree node, for what distd says ("/dist/releases/1/tree/bin/ls").
static void tree_path(uint32_t id, char *out, size_t cap) {
  uint32_t chain[64];
  int depth = 0;
  for (uint32_t i = id; i && nodes[i].kind == K_TREE && depth < 64; i = nodes[i].parent) chain[depth++] = i;
  size_t n = 0;
  for (int d = depth - 1; d >= 0 && n + 2 < cap; d--) {
    const char *nm = nodes[chain[d]].name;
    if (d == depth - 1 && !*nm) continue; // the tree's root
    out[n++] = '/';
    for (size_t k = 0; nm[k] && n + 1 < cap; k++) out[n++] = nm[k];
  }
  out[n] = 0;
}

// --- 9Px ---

static uint32_t root_id, status_id, ctl_id, releases_id, store_id;

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = root_id;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  node *d = node_of(dir);
  if (!d || !is_dir(d) || name.len >= 256) return VX_ERR_NOT_FOUND;
  char nm[256];
  memcpy(nm, name.ptr, name.len);
  nm[name.len] = 0;
  uint32_t id = 0;
  switch (d->kind) {
  case K_ROOT:
    if (same(nm, "status")) id = status_id;
    if (same(nm, "ctl")) id = ctl_id;
    if (same(nm, "releases")) id = releases_id;
    if (same(nm, "store")) id = store_id;
    break;
  case K_RELEASES: {
    uint64_t seq = 0;
    bool digits = name.len && name.len < 20 && (name.ptr[0] != '0' || name.len == 1);
    for (size_t i = 0; i < name.len && digits; i++) {
      digits = name.ptr[i] >= '0' && name.ptr[i] <= '9';
      seq = seq * 10 + (uint64_t)(name.ptr[i] - '0');
    }
    if (digits && release_of(seq)) id = fixed(K_RELEASE, (uint32_t)dir, seq, nm);
    break;
  }
  case K_RELEASE:
    if (same(nm, "record")) id = fixed(K_RECORD, (uint32_t)dir, d->seq, nm);
    if (same(nm, "status")) id = fixed(K_RSTATUS, (uint32_t)dir, d->seq, nm);
    if (same(nm, "tree")) {
      release *r = release_of(d->seq);
      vx_store_entry e = {.mode = 040555, .hash = r ? r->tree : (vx_hash){}};
      node n = {.kind = K_TREE, .parent = (uint32_t)dir, .seq = d->seq, .e = e};
      if (r) id = add_node(n);
    }
    break;
  case K_TREE: {
    uint32_t len;
    vx_status st;
    const uint8_t *text = dir_object(&d->e.hash, &len, &st);
    if (!text) return st;
    static char scratch[16384];
    vx_store_entry e;
    st = vx_store_dir_find(text, len, name, scratch, sizeof scratch, &e);
    if (st != VX_OK) return st == VX_ERR_INVALID ? VX_ERR_IO : st;
    id = tree_node((uint32_t)dir, d->seq, &e);
    break;
  }
  case K_STORE: {
    // b2, then two hex digits, then the object's 64: as the store has them.
    node n = {.kind = K_STORE, .parent = (uint32_t)dir};
    size_t plen = vx_cstr(d->path).len;
    if (plen + 1 + name.len >= sizeof n.path) return VX_ERR_NOT_FOUND;
    memcpy(n.path, d->path, plen);
    if (plen) n.path[plen++] = '/';
    memcpy(n.path + plen, name.ptr, name.len);
    memcpy(n.name, nm, name.len + 1);
    bool object_level = plen == 6; // "b2/xx/"
    if (object_level) n.kind = K_OBJECT;
    char full[96] = "/n/";
    memcpy(full + 3, n.path, vx_cstr(n.path).len + 1);
    p9_client *c;
    uint32_t fid;
    vx_status st = vx_ns_walk(&ns, vx_cstr(full), &c, &fid);
    if (st != VX_OK) return st;
    p9c_clunk(c, fid);
    id = add_node(n);
    break;
  }
  default: break;
  }
  if (!id) return VX_ERR_NOT_FOUND;
  *child = id;
  return VX_OK;
}

static vx_status fs_parent(void *ctx, uint64_t id, uint64_t *parent) {
  (void)ctx;
  node *n = node_of(id);
  if (!n) return VX_ERR_NOT_FOUND;
  *parent = n->parent ? n->parent : root_id;
  return VX_OK;
}

// A tree file's index, checked against its name.
static vx_status index_of(const node *n, uint64_t *size, const uint8_t **hashes, uint64_t *count) {
  uint32_t len;
  vx_status st;
  bool kept = is_kept(&n->e.hash);
  const uint8_t *idx = object(&n->e.hash, &len, &st);
  if (!idx) return st;
  st = vx_store_index_check(&n->e.hash, idx, len, size, hashes, count);
  if (st != VX_OK) return VX_ERR_IO;
  if (!kept) keep(&n->e.hash);
  return *size == n->e.size ? VX_OK : VX_ERR_IO; // the directory's size and the index's agree
}

static char text[16384]; // status files, made when read

static size_t status_text(const node *n) {
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  if (n->kind == K_STATUS) {
    vx_ndb_put(&w, "state", VX_STR("idle"));
    vx_ndb_put_u64(&w, "releases", nreleases);
    vx_ndb_put(&w, "arch", vx_cstr(ARCH));
    vx_ndb_end(&w);
  } else { // a release's: is every object of its tree here?
    release *r = release_of(n->seq);
    uint64_t missing = 0;
    // Only the root directory's objects and its files' indexes are looked for:
    // presence, not soundness (reads check that).
    uint32_t len;
    vx_status st;
    const uint8_t *t = r ? dir_object(&r->tree, &len, &st) : nullptr;
    if (!t) missing++;
    vx_ndb_put(&w, "state", missing ? VX_STR("seen") : VX_STR("fetched"));
    vx_ndb_put_u64(&w, "missing", missing);
    vx_ndb_end(&w);
  }
  return w.failed ? 0 : w.len;
}

static vx_status fs_stat(void *ctx, uint64_t id, p9_stat *out) {
  (void)ctx;
  node *n = node_of(id);
  if (!n) return VX_ERR_NOT_FOUND;
  bool dir = is_dir(n);
  uint32_t mode = dir ? P9_DMDIR | 0555 : 0444;
  uint64_t length = 0;
  const char *name = n->name;
  if (n->kind == K_ROOT) name = "/";
  if (n->kind == K_CTL) mode = 0220;
  if (n->kind == K_RECORD) {
    release *r = release_of(n->seq);
    length = r ? r->record_len : 0;
  }
  if (n->kind == K_TREE) {
    if (vx_store_is_link(&n->e))
      mode = P9_DMSYMLINK | 0777;
    else if (!dir)
      mode = n->e.mode & 0777, length = n->e.size;
    if (!*n->name) name = "tree";
  }
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, id},
                   .mode = mode,
                   .length = length,
                   .name = vx_cstr(name),
                   .uid = VX_STR("dist"),
                   .gid = VX_STR("dist"),
                   .muid = VX_STR("dist")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t id, uint8_t mode) {
  (void)ctx;
  node *n = node_of(id);
  if (!n) return VX_ERR_NOT_FOUND;
  if (n->kind == K_CTL) return (mode & 3) == P9_OWRITE ? VX_OK : VX_ERR_ACCESS;
  return (mode & 3) == P9_OREAD && !(mode & (P9_OTRUNC | P9_ORCLOSE)) ? VX_OK : VX_ERR_ACCESS;
}

static void give(const uint8_t *src, size_t len, uint64_t offset, uint8_t *buf, uint32_t *count) {
  uint64_t left = offset < len ? len - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  if (*count) memcpy(buf, src + offset, *count);
}

static vx_status fs_read(void *ctx, uint64_t id, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  node *n = node_of(id);
  if (!n) return VX_ERR_NOT_FOUND;
  if (is_dir(n)) return VX_ERR_INVALID;
  if (n->kind == K_STATUS || n->kind == K_RSTATUS) {
    give((const uint8_t *)text, status_text(n), offset, buf, count);
    return VX_OK;
  }
  if (n->kind == K_RECORD) {
    release *r = release_of(n->seq);
    if (!r) return VX_ERR_NOT_FOUND;
    give((const uint8_t *)r->record, r->record_len, offset, buf, count);
    return VX_OK;
  }
  if (n->kind == K_OBJECT) { // as the store has it: peers check it themselves
    char full[96] = "/n/";
    memcpy(full + 3, n->path, vx_cstr(n->path).len + 1);
    vx_ns_file f;
    vx_status st = vx_ns_open(&ns, vx_cstr(full), P9_OREAD, &f);
    if (st != VX_OK) return st;
    f.offset = offset;
    int64_t got = vx_ns_read(&f, buf, *count);
    vx_ns_close(&f);
    if (got < 0) return (vx_status)got;
    *count = (uint32_t)got;
    return VX_OK;
  }
  if (n->kind != K_TREE || vx_store_is_link(&n->e)) return VX_ERR_INVALID;
  // A verified read: the index, then each block the range touches.
  uint64_t size = 0, nblocks = 0;
  const uint8_t *hashes = nullptr;
  vx_status st = index_of(n, &size, &hashes, &nblocks);
  char where[512];
  if (st != VX_OK) {
    tree_path(id, where, sizeof where);
    said_bad("a file's index", vx_cstr(where));
    return st;
  }
  // The index may move in the cache as blocks come in: keep its hashes.
  static uint8_t hashes_copy[32 * 1024];
  uint64_t first = offset / VX_STORE_BLOCK, last = offset + *count > size ? size : offset + *count;
  if (offset >= size) {
    *count = 0;
    return VX_OK;
  }
  uint64_t lastb = (last - 1) / VX_STORE_BLOCK;
  if ((lastb - first + 1) * VX_STORE_HASH > sizeof hashes_copy) return VX_ERR_RANGE;
  memcpy(hashes_copy, hashes + first * VX_STORE_HASH, (lastb - first + 1) * VX_STORE_HASH);
  uint32_t done = 0;
  for (uint64_t b = first; b <= lastb; b++) {
    vx_hash bh;
    memcpy(bh.b, hashes_copy + (b - first) * VX_STORE_HASH, VX_STORE_HASH);
    bool kept = is_kept(&bh);
    uint32_t len;
    const uint8_t *data = object(&bh, &len, &st);
    if (!data) return st;
    if (!kept) {
      uint64_t want = b + 1 < nblocks ? VX_STORE_BLOCK : size - b * VX_STORE_BLOCK;
      vx_hash got;
      vx_store_leaf(data, len, &got);
      if (len != want || !vx_hash_eq(&got, &bh)) {
        tree_path(id, where, sizeof where);
        said_bad("a block", vx_cstr(where));
        return VX_ERR_IO;
      }
      keep(&bh);
    }
    uint64_t from = b == first ? offset % VX_STORE_BLOCK : 0;
    uint64_t to = b == lastb ? (last - 1) % VX_STORE_BLOCK + 1 : len;
    memcpy(buf + done, data + from, to - from);
    done += (uint32_t)(to - from);
  }
  *count = done;
  return VX_OK;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t id, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  node *n = node_of(id);
  if (!n || n->kind != K_CTL) return VX_ERR_ACCESS;
  vx_str cmd = {(const char *)buf, *count};
  while (cmd.len && (cmd.ptr[cmd.len - 1] == '\n' || cmd.ptr[cmd.len - 1] == ' ')) cmd.len--;
  if (cmd.len == 6 && memcmp(cmd.ptr, "rescan", 6) == 0) {
    rescan();
    return VX_OK;
  }
  return VX_ERR_INVALID; // fetch, apply, rollback and the rest: steps 9c and 9d
}

static vx_status fs_readlink(void *ctx, uint64_t id, vx_str *target) {
  (void)ctx;
  node *n = node_of(id);
  if (!n || n->kind != K_TREE || !vx_store_is_link(&n->e)) return VX_ERR_INVALID;
  *target = vx_cstr(n->target);
  return VX_OK;
}

// A listing, index by index.
static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  node *d = node_of(dir);
  if (!d || !is_dir(d)) return VX_ERR_INVALID;
  uint32_t id = 0;
  if (d->kind == K_ROOT) {
    uint32_t list[] = {status_id, ctl_id, releases_id, store_id};
    if (index >= 4) return VX_ERR_NOT_FOUND;
    id = list[index];
  } else if (d->kind == K_RELEASES) {
    if (index >= nreleases) return VX_ERR_NOT_FOUND;
    char nm[24];
    size_t n = 0;
    char digits[20];
    int nd = 0;
    uint64_t v = releases[index].seq;
    do digits[nd++] = (char)('0' + v % 10);
    while ((v /= 10) && nd < 20);
    while (nd) nm[n++] = digits[--nd];
    nm[n] = 0;
    id = fixed(K_RELEASE, (uint32_t)dir, releases[index].seq, nm);
  } else if (d->kind == K_RELEASE) {
    static const char *const names[] = {"record", "status", "tree"};
    if (index >= 3) return VX_ERR_NOT_FOUND;
    uint64_t c = 0;
    vx_status st = fs_walk(ctx, dir, vx_cstr(names[index]), &c);
    if (st != VX_OK) return st;
    id = (uint32_t)c;
  } else if (d->kind == K_TREE) {
    uint32_t len;
    vx_status st;
    const uint8_t *t = dir_object(&d->e.hash, &len, &st);
    if (!t) return st;
    static char scratch[16384];
    vx_ndb_reader r = {.src = {(const char *)t, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
    vx_ndb_record rec;
    for (uint32_t i = 0;; i++) {
      r.scratch_used = 0;
      if (vx_ndb_next(&r, &rec) != VX_NDB_RECORD) return VX_ERR_NOT_FOUND;
      if (i < index) continue;
      vx_store_entry e;
      if (vx_store_dir_entry(&rec, &e) != VX_OK) return VX_ERR_IO;
      id = tree_node((uint32_t)dir, d->seq, &e);
      break;
    }
  } else if (d->kind == K_STORE) { // as the store branch lists it
    char full[96] = "/n/";
    memcpy(full + 3, d->path, vx_cstr(d->path).len + 1);
    if (!*d->path) full[2] = 0; // "/n"
    vx_ns_file f;
    vx_status st = vx_ns_open(&ns, vx_cstr(full), P9_OREAD, &f);
    if (st != VX_OK) return st;
    static uint8_t listing[8192];
    int64_t n;
    uint32_t i = 0;
    while ((n = vx_ns_read(&f, listing, sizeof listing)) > 0) {
      p9_stat e;
      for (size_t off = 0; p9_dir_next(listing, (size_t)n, &off, &e);) {
        bool shown =
            *d->path || (e.name.len == 2 && memcmp(e.name.ptr, "b2", 2) == 0); // the objects, not records/
        if (!shown || i++ < index) continue;
        vx_ns_close(&f);
        return fs_walk(ctx, dir, e.name, child) == VX_OK ? VX_OK : VX_ERR_IO;
      }
    }
    vx_ns_close(&f);
    return VX_ERR_NOT_FOUND;
  }
  if (!id) return VX_ERR_NO_MEMORY;
  *child = id;
  return VX_OK;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .write = fs_write,
           .readdir = fs_readdir,
           .readlink = fs_readlink},
    .name = VX_STR("distd"),
    .supported = P9_EXT_POSIX | P9_EXT_XATTR, // Treadlink; Tgetattr, for stat
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) fail("no listen channel (post=)", VX_OK);
  vx_status st = vx_ns_from_spawn(&ns);
  if (st != VX_OK) fail("no namespace", st);
  nnodes = 1; // 0 is no node
  root_id = fixed(K_ROOT, 0, 0, "");
  status_id = fixed(K_STATUS, root_id, 0, "status");
  ctl_id = fixed(K_CTL, root_id, 0, "ctl");
  releases_id = fixed(K_RELEASES, root_id, 0, "releases");
  store_id = fixed(K_STORE, root_id, 0, "store");
  rescan();
  vx_print(VX_STR("distd: "));
  vx_print_u64(nreleases);
  vx_print(VX_STR(" releases for "));
  vx_print(vx_cstr(ARCH));
  vx_print(VX_STR("; serving /srv/dist\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
