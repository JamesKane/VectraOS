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
  vx_status st = vxfs_rename(&w->v, &w->br->t, &from, nodes[i].name, &dest, name, ++w->now);
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
  // Everything removed, deepest first: the space all comes back.
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
  CHECK(c.trees <= 8); // the trees' roots, and little else
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
  CHECK(vxfs_rename(&v, &br->t, &a, "b", &root, "b2", 10) == VX_OK);
  CHECK(vxfs_walk_path(&v, &br->t, "/b2/../a", &f) == VX_OK && f.d.qid_path == a.d.qid_path);
  CHECK(vxfs_walk_path(&v, &br->t, "/b2", &b) == VX_OK && vxfs_walk(&v, &br->t, &b, "..", &up) == VX_OK &&
        up.d.qid_path == root.d.qid_path);
  CHECK(vxfs_remove(&v, &br->t, &root, "..", 11) == VX_ERR_INVALID);
  CHECK(vxfs_commit(&v) == VX_OK);
  vxfs_check c;
  CHECK(vxfs_check_volume(&v, &c) == VX_OK);
  vxfs_unmount(&v);
  free(d.bytes);
}

int main(void) {
  test_names();
  for (uint64_t seed = 1; seed <= 3; seed++) test_random(seed * 0x9E3779B97F4A7C15ull, 900);
  for (uint32_t i = 0; i < MAXN; i++) drop_node(i);
  return check_result();
}
