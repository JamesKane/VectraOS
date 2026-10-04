// vxfs_file_test.c: lib/vx-fs's file layer against a model. Random
// directories, files and symbolic links are made, written (small, so
// inline, and large, in blocks, sparse, across the boundary between the
// two), truncated, renamed (a directory into itself refused, a target
// replaced) and removed. After every few operations every file's contents
// and every directory's listing agree with the model, the checker finds no
// leak (data cleared as files go), and now and then the volume is
// committed, mounted again and compared once more.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fs/check.c"
#include "../../lib/vx-fs/file.c"

typedef struct memdev {
  uint8_t *bytes;
  uint64_t size;
} memdev;

static vx_status md_read(void *ctx, uint64_t addr, void *buf) {
  memcpy(buf, ((memdev *)ctx)->bytes + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status md_write(void *ctx, uint64_t addr, const void *buf) {
  memcpy(((memdev *)ctx)->bytes + addr, buf, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status md_barrier([[maybe_unused]] void *ctx) { return VX_OK; }
static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }
static const vxfs_mem MEM = {.alloc = m_alloc, .free = m_free};

static uint64_t rng = 11;
static uint64_t rnd(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}
static uint32_t below(uint32_t n) { return (uint32_t)(rnd() % n); }

// --- The model ---

static constexpr uint32_t MAXN = 96, MAXLEN = 100'000;
typedef struct node {
  bool used, dir, link;
  uint32_t parent;
  char name[16];
  uint8_t *data;
  uint32_t len;
} node;

static node nodes[MAXN]; // 0 is the root

// NOLINTNEXTLINE(misc-no-recursion): as deep as the model, a few levels
static void path_of(uint32_t i, char *out, size_t cap) {
  if (i == 0) {
    snprintf(out, cap, "/");
    return;
  }
  char up[512];
  path_of(nodes[i].parent, up, sizeof up);
  snprintf(out, cap, "%s%s%s", up, nodes[i].parent ? "/" : "", nodes[i].name);
}

static uint32_t child(uint32_t dir, const char *name) {
  for (uint32_t i = 1; i < MAXN; i++)
    if (nodes[i].used && nodes[i].parent == dir && strcmp(nodes[i].name, name) == 0) return i;
  return 0;
}

static bool has_children(uint32_t dir) {
  for (uint32_t i = 1; i < MAXN; i++)
    if (nodes[i].used && nodes[i].parent == dir) return true;
  return false;
}

static uint32_t pick_node(int want_dir) { // -1: any but the root
  uint32_t c[MAXN], n = 0;
  for (uint32_t i = 0; i < MAXN; i++)
    if (nodes[i].used && (want_dir < 0 ? i != 0 : nodes[i].dir == (want_dir == 1))) c[n++] = i;
  return n ? c[below(n)] : MAXN;
}

static uint32_t free_slot(void) {
  for (uint32_t i = 1; i < MAXN; i++)
    if (!nodes[i].used) return i;
  return 0;
}

static void drop_node(uint32_t i) {
  free(nodes[i].data);
  nodes[i] = (node){};
}

// --- The volume ---

typedef struct world {
  memdev d;
  vxfs_vol v;
  vxfs_branch *br;
  int64_t now;
} world;

static vxfs_dev dev_of(memdev *d) {
  return (vxfs_dev){.ctx = d, .read = md_read, .write = md_write, .barrier = md_barrier, .size = d->size};
}

static vx_status at(world *w, uint32_t i, vxfs_file *f) {
  char p[512];
  path_of(i, p, sizeof p);
  return vxfs_walk_path(&w->v, &w->br->t, p, f);
}

// --- Agreement ---

typedef struct listing {
  uint32_t dir, seen;
  bool ok;
} listing;

static bool listed(void *ctx, const char *name, uint16_t n, const vxfs_dir *d) {
  listing *l = ctx;
  char nm[32];
  if (n >= sizeof nm) {
    l->ok = false;
    return false;
  }
  memcpy(nm, name, n);
  nm[n] = 0;
  uint32_t c = child(l->dir, nm);
  if (!c || nodes[c].dir != ((d->mode & VXFS_DMDIR) != 0) ||
      nodes[c].link != ((d->mode & VXFS_DMSYMLINK) != 0) || (!nodes[c].dir && d->length != nodes[c].len))
    l->ok = false;
  l->seen++;
  return true;
}

static bool agrees(world *w) {
  static uint8_t buf[MAXLEN + 10];
  for (uint32_t i = 0; i < MAXN; i++) {
    if (!nodes[i].used) continue;
    vxfs_file f;
    if (at(w, i, &f) != VX_OK) return false;
    if (nodes[i].dir) {
      listing l = {.dir = i, .ok = true};
      uint32_t want = 0;
      for (uint32_t k = 1; k < MAXN; k++) want += nodes[k].used && nodes[k].parent == i;
      if (vxfs_readdir(&w->v, &w->br->t, &f, listed, &l) != VX_OK || !l.ok || l.seen != want) return false;
      continue;
    }
    uint64_t got = 0;
    if (f.d.length != nodes[i].len || vxfs_read(&w->v, &w->br->t, &f, 0, buf, sizeof buf, &got) != VX_OK ||
        got != nodes[i].len || (got && memcmp(buf, nodes[i].data, got) != 0))
      return false;
    // A read from the middle, too.
    if (nodes[i].len > 10) {
      uint32_t off = below(nodes[i].len);
      if (vxfs_read(&w->v, &w->br->t, &f, off, buf, 7000, &got) != VX_OK ||
          got != (nodes[i].len - off < 7000 ? nodes[i].len - off : 7000) ||
          memcmp(buf, nodes[i].data + off, got) != 0)
        return false;
    }
  }
  return true;
}

static bool clean(world *w) {
  vxfs_check c;
  vx_status st = vxfs_check_volume(&w->v, &c);
  if (st != VX_OK)
    fprintf(stderr, "check: used %llu leaked %llu unalloc %llu damaged %llu\n", (unsigned long long)c.used,
            (unsigned long long)c.leaked, (unsigned long long)c.unallocated, (unsigned long long)c.damaged);
  return st == VX_OK;
}

// --- Operations ---

static void op_create(world *w, bool dir, bool link) {
  uint32_t parent = pick_node(1), s = free_slot();
  if (parent == MAXN || !s) return;
  char name[16];
  char kind = 'f';
  if (dir) kind = 'd';
  if (link) kind = 'l';
  snprintf(name, sizeof name, "%c%u", kind, below(40));
  vxfs_file pf, f;
  CHECK(at(w, parent, &pf) == VX_OK);
  vx_status st =
      link ? vxfs_symlink(&w->v, &w->br->t, &pf, name, "../some/target", 7, 8, ++w->now, &f)
           : vxfs_create(&w->v, &w->br->t, &pf, name, dir ? VXFS_DMDIR | 0755 : 0644, 7, 8, ++w->now, &f);
  if (child(parent, name)) {
    CHECK(st == VX_ERR_EXISTS);
    return;
  }
  CHECK(st == VX_OK);
  nodes[s] = (node){.used = true, .dir = dir, .link = link, .parent = parent};
  memcpy(nodes[s].name, name, sizeof name);
  if (link) {
    nodes[s].data = malloc(14);
    memcpy(nodes[s].data, "../some/target", 14);
    nodes[s].len = 14;
  }
}

static void op_write(world *w) {
  uint32_t i = pick_node(0);
  if (i == MAXN || nodes[i].link) return;
  // Small writes and large, within a file or past its end (sparse).
  uint32_t off = below(4) ? below(nodes[i].len + 1) : below(MAXLEN / 2);
  uint32_t n = below(3) ? 1 + below(300) : 1 + below(40'000);
  if (off + n > MAXLEN) n = MAXLEN - off;
  static uint8_t data[MAXLEN];
  for (uint32_t k = 0; k < n; k++) data[k] = (uint8_t)rnd();
  vxfs_file f;
  CHECK(at(w, i, &f) == VX_OK);
  CHECK(vxfs_write(&w->v, &w->br->t, &f, off, data, n, ++w->now, 9) == VX_OK);
  if (off + n > nodes[i].len) {
    uint8_t *more = realloc(nodes[i].data, off + n);
    if (!more) abort();
    memset(more + nodes[i].len, 0, off + n - nodes[i].len);
    nodes[i].data = more;
    nodes[i].len = off + n;
  }
  memcpy(nodes[i].data + off, data, n);
}

static void op_truncate(world *w) {
  uint32_t i = pick_node(0);
  if (i == MAXN || nodes[i].link) return;
  uint32_t len = below(2) ? below(nodes[i].len + 1) : below(MAXLEN);
  vxfs_file f;
  CHECK(at(w, i, &f) == VX_OK);
  vxfs_attr a = {.valid = VXFS_WSIZE, .length = len};
  CHECK(vxfs_setattr(&w->v, &w->br->t, &f, &a, ++w->now) == VX_OK);
  if (len > nodes[i].len) {
    uint8_t *more = realloc(nodes[i].data, len);
    if (!more) abort();
    memset(more + nodes[i].len, 0, len - nodes[i].len);
    nodes[i].data = more;
  }
  nodes[i].len = len;
}

static void op_remove(world *w) {
  uint32_t i = pick_node(-1);
  if (i == MAXN) return;
  vxfs_file pf;
  CHECK(at(w, nodes[i].parent, &pf) == VX_OK);
  vx_status st = vxfs_remove(&w->v, &w->br->t, &pf, nodes[i].name, ++w->now);
  if (nodes[i].dir && has_children(i)) {
    CHECK(st == VX_ERR_EXISTS);
    return;
  }
  CHECK(st == VX_OK);
  drop_node(i);
}

static bool inside(uint32_t i, uint32_t dir) { // is dir i itself, or under it?
  for (uint32_t up = dir;; up = nodes[up].parent) {
    if (up == i) return true;
    if (up == 0) return false;
  }
}

static void op_rename(world *w) {
  uint32_t i = pick_node(-1), to = pick_node(1);
  if (i == MAXN || to == MAXN) return;
  char name[16];
  if (below(2))
    memcpy(name, nodes[i].name, sizeof name);
  else
    snprintf(name, sizeof name, "%c%u", nodes[i].dir ? 'd' : 'f', below(40));
  vxfs_file from, dest;
  CHECK(at(w, nodes[i].parent, &from) == VX_OK && at(w, to, &dest) == VX_OK);
  vx_status st = vxfs_rename(&w->v, &w->br->t, &from, nodes[i].name, &dest, name, ++w->now, nullptr, nullptr);
  uint32_t there = child(to, name);
  vx_status want = VX_OK;
  if (nodes[i].dir && inside(i, to))
    want = VX_ERR_INVALID;
  else if (there && there != i && nodes[there].dir != nodes[i].dir)
    want = nodes[there].dir ? VX_ERR_EXISTS : VX_ERR_INVALID;
  else if (there && there != i && nodes[there].dir && has_children(there))
    want = VX_ERR_EXISTS;
  CHECK(st == want);
  if (st != VX_OK || there == i) return;
  if (there) drop_node(there);
  nodes[i].parent = to;
  memcpy(nodes[i].name, name, sizeof name);
}

static void remount(world *w) {
  CHECK(vxfs_commit(&w->v) == VX_OK);
  vxfs_unmount(&w->v);
  CHECK(vxfs_mount(&w->v, dev_of(&w->d), MEM, 512) == VX_OK);
  CHECK(vxfs_branch_open(&w->v, "home", &w->br) == VX_OK);
}

static void test_random(uint64_t seed, uint32_t ops) {
  rng = seed;
  for (uint32_t i = 0; i < MAXN; i++) drop_node(i);
  nodes[0] = (node){.used = true, .dir = true};
  static world w;
  w = (world){.d = {.size = 8192ull * VXFS_BLKSZ}};
  w.d.bytes = calloc(1, w.d.size);
  const char *names[] = {"home"};
  CHECK(vxfs_mkfs(&w.v, dev_of(&w.d), MEM, 512, 2, names, 1, 0755, 1, 1, 1) == VX_OK);
  CHECK(vxfs_branch_open(&w.v, "home", &w.br) == VX_OK);
  bool ok = true;
  for (uint32_t k = 0; k < ops && ok; k++) {
    uint32_t op = below(100);
    if (op < 15)
      op_create(&w, true, false);
    else if (op < 35)
      op_create(&w, false, false);
    else if (op < 38)
      op_create(&w, false, true);
    else if (op < 65)
      op_write(&w);
    else if (op < 75)
      op_truncate(&w);
    else if (op < 87)
      op_remove(&w);
    else
      op_rename(&w);
    if (k % 25 == 24) {
      bool a = agrees(&w), c = clean(&w);
      CHECK(a && c);
      ok = a && c && check_failures == 0;
    }
    if (k % 150 == 149) {
      remount(&w);
      ok = ok && agrees(&w) && clean(&w);
      CHECK(ok);
    }
    if (!ok) fprintf(stderr, "seed %llu: wrong at op %u\n", (unsigned long long)seed, k);
  }
  // Everything removed, deepest first.
  for (int pass = 0; pass < 20; pass++)
    for (uint32_t i = 1; i < MAXN; i++)
      if (nodes[i].used && !has_children(i)) {
        vxfs_file pf;
        CHECK(at(&w, nodes[i].parent, &pf) == VX_OK);
        CHECK(vxfs_remove(&w.v, &w.br->t, &pf, nodes[i].name, ++w.now) == VX_OK);
        drop_node(i);
      }
  remount(&w);
  vxfs_check c;
  CHECK(vxfs_check_volume(&w.v, &c) == VX_OK && agrees(&w));
  // Not every block is back yet: the removes are messages buffered in pivots
  // until a flush takes them to the leaves, as in any Bε tree. Clean is what
  // holds: nothing leaked, nothing reachable that should not be.
  vxfs_unmount(&w.v);
  free(w.d.bytes);
}

// By hand: names refused, "..", walking paths, the root's own parent.
static void test_names(void) {
  memdev d = {.size = 2048ull * VXFS_BLKSZ};
  d.bytes = calloc(1, d.size);
  vxfs_vol v;
  const char *names[] = {"cfg"};
  CHECK(vxfs_mkfs(&v, dev_of(&d), MEM, 256, 1, names, 1, 0755, 0, 0, 5) == VX_OK);
  vxfs_branch *br;
  CHECK(vxfs_branch_open(&v, "cfg", &br) == VX_OK);
  vxfs_file root, a, b, f, up;
  CHECK(vxfs_root(&v, &br->t, &root) == VX_OK && (root.d.mode & VXFS_DMDIR) && root.d.btime == 5);
  CHECK(vxfs_create(&v, &br->t, &root, "a", VXFS_DMDIR | 0700, 1, 1, 6, &a) == VX_OK);
  CHECK(vxfs_create(&v, &br->t, &a, "b", VXFS_DMDIR | 0700, 1, 1, 7, &b) == VX_OK);
  CHECK(vxfs_create(&v, &br->t, &b, "file", 0600, 1, 1, 8, &f) == VX_OK);
  static const char *const bad[] = {"", ".", "..", "x/y"};
  for (size_t i = 0; i < 4; i++)
    CHECK(vxfs_create(&v, &br->t, &root, bad[i], 0600, 1, 1, 9, &f) == VX_ERR_INVALID);
  char longname[VXFS_NAMEMAX + 2];
  memset(longname, 'n', sizeof longname - 1);
  longname[sizeof longname - 1] = 0;
  CHECK(vxfs_create(&v, &br->t, &root, longname, 0600, 1, 1, 9, &f) == VX_ERR_RANGE);
  longname[VXFS_NAMEMAX] = 0; // the longest there may be
  CHECK(vxfs_create(&v, &br->t, &root, longname, 0600, 1, 1, 9, &f) == VX_OK);
  CHECK(vxfs_walk_path(&v, &br->t, "/a/b/file", &f) == VX_OK && f.d.mtime == 8);
  CHECK(vxfs_walk_path(&v, &br->t, "a//b/../b/./file", &f) == VX_OK);
  CHECK(vxfs_walk(&v, &br->t, &b, "..", &up) == VX_OK && up.d.qid_path == a.d.qid_path);
  CHECK(vxfs_walk(&v, &br->t, &root, "..", &up) == VX_OK && up.d.qid_path == root.d.qid_path);
  CHECK(vxfs_walk_path(&v, &br->t, "/a/nothing", &f) == VX_ERR_NOT_FOUND);
  CHECK(vxfs_walk_path(&v, &br->t, "/a/b/file/x", &f) == VX_ERR_INVALID); // through a file
  CHECK(vxfs_walk_path(&v, &br->t, "/a", &a) == VX_OK && a.d.mtime == 7); // b's creation touched it
  // A directory moved: its ".." follows it.
  CHECK(vxfs_rename(&v, &br->t, &a, "b", &root, "b2", 10, nullptr, nullptr) == VX_OK);
  CHECK(vxfs_walk_path(&v, &br->t, "/b2/../a", &f) == VX_OK && f.d.qid_path == a.d.qid_path);
  CHECK(vxfs_walk_path(&v, &br->t, "/b2", &b) == VX_OK && vxfs_walk(&v, &br->t, &b, "..", &up) == VX_OK &&
        up.d.qid_path == root.d.qid_path);
  CHECK(vxfs_remove(&v, &br->t, &root, "..", 11) == VX_ERR_INVALID);
  // Entries by qid: a file, a moved directory, the root; and one removed.
  vxfs_file byq;
  CHECK(vxfs_walk_path(&v, &br->t, "/b2/file", &f) == VX_OK);
  CHECK(vxfs_file_by_qid(&v, &br->t, f.d.qid_path, &byq) == VX_OK && byq.nkey == f.nkey &&
        memcmp(byq.key, f.key, f.nkey) == 0);
  CHECK(vxfs_file_by_qid(&v, &br->t, b.d.qid_path, &byq) == VX_OK && byq.d.qid_path == b.d.qid_path);
  CHECK(vxfs_file_by_qid(&v, &br->t, root.d.qid_path, &byq) == VX_OK && byq.nkey == 9);
  CHECK(vxfs_remove(&v, &br->t, &b, "file", 12) == VX_OK);
  CHECK(vxfs_file_by_qid(&v, &br->t, f.d.qid_path, &byq) == VX_ERR_NOT_FOUND);
  // An orphan: removed while open, found by its qid, written, then reaped.
  vxfs_file o, oq;
  CHECK(vxfs_create(&v, &br->t, &root, "open-file", 0600, 1, 1, 13, &o) == VX_OK);
  static uint8_t big[40000];
  memset(big, 0x42, sizeof big);
  CHECK(vxfs_write(&v, &br->t, &o, 0, big, sizeof big, 14, 1) == VX_OK);
  CHECK(vxfs_orphan(&v, &br->t, &root, "open-file", 15) == VX_OK);
  CHECK(vxfs_walk(&v, &br->t, &root, "open-file", &f) == VX_ERR_NOT_FOUND);
  CHECK(vxfs_file_by_qid(&v, &br->t, o.d.qid_path, &oq) == VX_OK && vxfs_is_orphan(&oq) &&
        oq.d.length == sizeof big);
  CHECK(vxfs_write(&v, &br->t, &oq, sizeof big, "tail", 4, 16, 1) == VX_OK);
  uint64_t got = 0;
  uint8_t back[8];
  CHECK(vxfs_file_by_qid(&v, &br->t, o.d.qid_path, &oq) == VX_OK && oq.d.length == sizeof big + 4);
  CHECK(vxfs_read(&v, &br->t, &oq, sizeof big - 2, back, 8, &got) == VX_OK && got == 6 &&
        memcmp(back, "\x42\x42tail", 6) == 0);
  CHECK(vxfs_reap(&v, &br->t, o.d.qid_path) == VX_OK);
  CHECK(vxfs_file_by_qid(&v, &br->t, o.d.qid_path, &oq) == VX_ERR_NOT_FOUND);
  // Orphans a crash left: committed while orphaned, reaped when next opened.
  CHECK(vxfs_create(&v, &br->t, &root, "left", 0600, 1, 1, 17, &o) == VX_OK);
  CHECK(vxfs_write(&v, &br->t, &o, 0, big, sizeof big, 18, 1) == VX_OK);
  CHECK(vxfs_orphan(&v, &br->t, &root, "left", 19) == VX_OK);
  CHECK(vxfs_commit(&v) == VX_OK);
  vxfs_check c;
  CHECK(vxfs_check_volume(&v, &c) == VX_OK);
  uint64_t with_orphan = c.trees;
  vxfs_unmount(&v);
  CHECK(vxfs_mount(&v, dev_of(&d), MEM, 256) == VX_OK && vxfs_branch_open(&v, "cfg", &br) == VX_OK);
  uint32_t n = 0;
  CHECK(vxfs_reap_all(&v, &br->t, &n) == VX_OK && n == 1);
  CHECK(vxfs_file_by_qid(&v, &br->t, o.d.qid_path, &oq) == VX_ERR_NOT_FOUND);
  CHECK(vxfs_commit(&v) == VX_OK && vxfs_check_volume(&v, &c) == VX_OK && c.trees < with_orphan);
  vxfs_unmount(&v);
  free(d.bytes);
}

static bool keep_all([[maybe_unused]] void *ctx, [[maybe_unused]] uint64_t qid) { return true; }

static bool committed_clean(vxfs_vol *v) {
  vxfs_check c;
  return vxfs_commit(v) == VX_OK && vxfs_check_volume(v, &c) == VX_OK && v->fs.err == VX_OK;
}

// The review's cases (docs/milestones.md): a rename over an open file, a
// file of many blocks removed, a rename deep in a tree, a full volume.
static void test_limits(void) {
  memdev d = {.size = 4096ull * VXFS_BLKSZ};
  d.bytes = calloc(1, d.size);
  vxfs_vol v;
  const char *names[] = {"cfg"};
  CHECK(vxfs_mkfs(&v, dev_of(&d), MEM, 256, 2, names, 1, 0755, 0, 0, 5) == VX_OK);
  vxfs_branch *br;
  vxfs_file root, a, b, f, q;
  CHECK(vxfs_branch_open(&v, "cfg", &br) == VX_OK && vxfs_root(&v, &br->t, &root) == VX_OK);
  uint8_t back[16];
  uint64_t got = 0;

  // Renamed over while open: the old file kept, as an orphan, until reaped.
  CHECK(vxfs_create(&v, &br->t, &root, "old", 0600, 1, 1, 6, &a) == VX_OK);
  CHECK(vxfs_write(&v, &br->t, &a, 0, "old data", 8, 6, 1) == VX_OK);
  CHECK(vxfs_create(&v, &br->t, &root, "new", 0600, 1, 1, 7, &b) == VX_OK);
  CHECK(vxfs_write(&v, &br->t, &b, 0, "new data", 8, 7, 1) == VX_OK);
  CHECK(vxfs_rename(&v, &br->t, &root, "new", &root, "old", 8, keep_all, nullptr) == VX_OK);
  CHECK(vxfs_walk(&v, &br->t, &root, "old", &f) == VX_OK && f.d.qid_path == b.d.qid_path);
  CHECK(vxfs_file_by_qid(&v, &br->t, a.d.qid_path, &q) == VX_OK && vxfs_is_orphan(&q));
  CHECK(vxfs_read(&v, &br->t, &q, 0, back, 8, &got) == VX_OK && got == 8 && memcmp(back, "old data", 8) == 0);
  CHECK(vxfs_reap(&v, &br->t, a.d.qid_path) == VX_OK && committed_clean(&v));

  // A file of many blocks (more than one chunk of clear_data's) removed.
  static uint8_t chunk[64 * 1024];
  memset(chunk, 0x77, sizeof chunk);
  CHECK(vxfs_create(&v, &br->t, &root, "big", 0600, 1, 1, 9, &f) == VX_OK);
  for (uint64_t at = 0; at < 600ull * VXFS_BLKSZ; at += sizeof chunk)
    CHECK(vxfs_write(&v, &br->t, &f, at, chunk, sizeof chunk, 9, 1) == VX_OK);
  CHECK(committed_clean(&v) && vxfs_remove(&v, &br->t, &root, "big", 10) == VX_OK && committed_clean(&v));

  // A tree deeper than the old limit of 4096: a rename into its depths is fine.
  vxfs_file dir = root, sub;
  for (uint32_t i = 0; i < 5000; i++) {
    CHECK(vxfs_create(&v, &br->t, &dir, "d", VXFS_DMDIR | 0700, 1, 1, 11, &sub) == VX_OK);
    dir = sub;
  }
  CHECK(vxfs_create(&v, &br->t, &root, "x", 0600, 1, 1, 12, &f) == VX_OK);
  CHECK(vxfs_rename(&v, &br->t, &root, "x", &dir, "x", 13, nullptr, nullptr) == VX_OK && v.fs.err == VX_OK);
  CHECK(committed_clean(&v));

  // Full: a write refused with NO_SPACE, the volume still sound; a remove
  // makes room, and writing works again.
  CHECK(vxfs_create(&v, &br->t, &root, "fill", 0600, 1, 1, 14, &f) == VX_OK);
  vx_status st = VX_OK;
  uint64_t at = 0;
  for (; st == VX_OK && at < d.size; at += sizeof chunk)
    st = vxfs_write(&v, &br->t, &f, at, chunk, sizeof chunk, 15, 1);
  CHECK(st == VX_ERR_NO_SPACE && v.fs.err == VX_OK && at > d.size / 2);
  CHECK(vxfs_commit(&v) == VX_OK); // what was written, kept
  CHECK(vxfs_create(&v, &br->t, &root, "more", 0600, 1, 1, 16, &a) == VX_OK || v.fs.err == VX_OK);
  CHECK(vxfs_remove(&v, &br->t, &root, "fill", 17) == VX_OK); // a remove may dig into the reserve
  CHECK(committed_clean(&v));
  CHECK(vxfs_walk(&v, &br->t, &root, "fill", &f) == VX_ERR_NOT_FOUND);
  CHECK(vxfs_create(&v, &br->t, &root, "after", 0600, 1, 1, 18, &f) == VX_OK);
  CHECK(vxfs_write(&v, &br->t, &f, 0, chunk, sizeof chunk, 18, 1) == VX_OK && committed_clean(&v));
  vxfs_unmount(&v);
  free(d.bytes);
}

// How block 0 of a file is kept: VXFS_VINL (inline), VXFS_VREF (a block), or 0 (none).
static uint8_t block0_kind(vxfs_vol *v, const vxfs_tree *t, uint64_t qid) {
  uint8_t k[17], val[VXFS_INLMAX];
  uint16_t nv = 0;
  return vxfs_lookup(&v->fs, t, k, key_dat(k, qid, 0), val, &nv) == VX_OK && nv ? val[0] : 0;
}

// M5 step 10's close-out of the file layer's review findings: a write of
// nothing does not extend; a size that would wrap when rounded up is
// refused; setattr keeps 11 §3's rule (a file is inline whole, or in
// blocks) both ways; "." and ".." are never removed, and say INVALID;
// only an orphan is reaped; a link's target is inline, at most VXFS_INLINE.
static void test_close_out(void) {
  memdev d = {.size = 1024ull * VXFS_BLKSZ};
  d.bytes = calloc(1, d.size);
  vxfs_vol v;
  const char *names[] = {"cfg"};
  CHECK(vxfs_mkfs(&v, dev_of(&d), MEM, 256, 1, names, 1, 0755, 0, 0, 5) == VX_OK);
  vxfs_branch *br;
  vxfs_file root, f, l, sub;
  CHECK(vxfs_branch_open(&v, "cfg", &br) == VX_OK && vxfs_root(&v, &br->t, &root) == VX_OK);
  CHECK(vxfs_create(&v, &br->t, &root, "f", 0600, 1, 1, 6, &f) == VX_OK);
  CHECK(vxfs_write(&v, &br->t, &f, 0, "hello", 5, 6, 1) == VX_OK && f.d.length == 5);
  CHECK(vxfs_write(&v, &br->t, &f, 1000, "", 0, 7, 1) == VX_OK && f.d.length == 5); // nothing: not extended
  vxfs_attr huge = {.valid = VXFS_WSIZE, .length = UINT64_MAX - 3};
  CHECK(vxfs_setattr(&v, &br->t, &f, &huge, 8) == VX_ERR_RANGE && f.d.length == 5);
  CHECK(block0_kind(&v, &br->t, f.d.qid_path) == VXFS_VINL);
  // Grown by setattr past inline: into a block, the bytes kept and zeros after.
  vxfs_attr grow = {.valid = VXFS_WSIZE, .length = 2000};
  CHECK(vxfs_setattr(&v, &br->t, &f, &grow, 9) == VX_OK &&
        block0_kind(&v, &br->t, f.d.qid_path) == VXFS_VREF);
  uint8_t back[2000];
  uint64_t got = 0;
  CHECK(vxfs_read(&v, &br->t, &f, 0, back, 2000, &got) == VX_OK && got == 2000 &&
        memcmp(back, "hello", 5) == 0 && back[5] == 0 && back[1999] == 0);
  // Shrunk by setattr to inline size: inline again, the bytes kept.
  vxfs_attr shrink = {.valid = VXFS_WSIZE, .length = 3};
  CHECK(vxfs_setattr(&v, &br->t, &f, &shrink, 10) == VX_OK &&
        block0_kind(&v, &br->t, f.d.qid_path) == VXFS_VINL);
  CHECK(vxfs_read(&v, &br->t, &f, 0, back, 100, &got) == VX_OK && got == 3 && memcmp(back, "hel", 3) == 0);
  CHECK(committed_clean(&v)); // no block left behind by either change
  // "." and "..".
  CHECK(vxfs_create(&v, &br->t, &root, "d", VXFS_DMDIR | 0700, 1, 1, 11, &sub) == VX_OK);
  CHECK(vxfs_remove(&v, &br->t, &sub, "..", 12) == VX_ERR_INVALID);
  CHECK(vxfs_remove(&v, &br->t, &sub, ".", 12) == VX_ERR_INVALID);
  // Reaping what is not an orphan: refused, the file untouched.
  CHECK(vxfs_reap(&v, &br->t, f.d.qid_path) == VX_ERR_INVALID);
  CHECK(vxfs_read(&v, &br->t, &f, 0, back, 100, &got) == VX_OK && got == 3);
  // A link's target: inline, so at most VXFS_INLINE bytes.
  static char target[VXFS_INLINE + 2];
  memset(target, 'x', VXFS_INLINE + 1);
  CHECK(vxfs_symlink(&v, &br->t, &root, "long", target, 1, 1, 13, &l) == VX_ERR_RANGE);
  target[VXFS_INLINE] = 0;
  CHECK(vxfs_symlink(&v, &br->t, &root, "max", target, 1, 1, 13, &l) == VX_OK &&
        block0_kind(&v, &br->t, l.d.qid_path) == VXFS_VINL);
  CHECK(committed_clean(&v));
  vxfs_unmount(&v);
  free(d.bytes);
}

int main(void) {
  test_close_out();
  test_names();
  test_limits();
  for (uint64_t seed = 1; seed <= 3; seed++) test_random(seed * 0x9E3779B97F4A7C15ull, 900);
  for (uint32_t i = 0; i < MAXN; i++) drop_node(i);
  return check_result();
}
