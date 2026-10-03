// vxfs_tree_test.c: lib/vx-fs's Bε tree against a model. Random batches of
// messages (inserts, deletes, clobbers, wstats, data blocks set and cleared)
// go to the tree and to a sorted array. After each, lookups and scans must
// agree with the array. The tree's structure is walked: every block checks,
// the height is the same everywhere, each key is in its node's range, the
// fills are right. Space must add up: the arena's used blocks are exactly
// the tree's, the data blocks the values name, and the log's. The tree is
// grown to three levels and emptied back to a leaf; malformed batches are
// refused; damaged messages make errors, not faults.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fs/tree.c"

// --- A device, memory, randomness ---

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

static uint64_t rng = 1;
static uint64_t rnd(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}
static uint32_t below(uint32_t n) { return (uint32_t)(rnd() % n); }

typedef struct world {
  memdev dev;
  vxfs fs;
  vxfs_tree t;
} world;

static constexpr uint64_t ARENA_BLOCKS = 2048;

static void world_open(world *w) {
  w->dev.size = 2 * (ARENA_BLOCKS + 2) * VXFS_BLKSZ;
  w->dev.bytes = calloc(1, w->dev.size);
  vxfs_dev d = {
      .ctx = &w->dev, .read = md_read, .write = md_write, .barrier = md_barrier, .size = w->dev.size};
  CHECK(vxfs_open(&w->fs, d, (vxfs_mem){.alloc = m_alloc, .free = m_free}, 512));
  CHECK(vxfs_arenas(&w->fs, 2));
  for (uint32_t i = 0; i < 2; i++)
    CHECK(vxfs_arena_init(&w->fs, &w->fs.arenas[i], i * (ARENA_BLOCKS + 2) * VXFS_BLKSZ, ARENA_BLOCKS));
  CHECK(vxfs_tree_init(&w->fs, &w->t));
  CHECK(vxfs_end_op(&w->fs));
}

static void world_close(world *w) {
  vxfs_close(&w->fs);
  free(w->dev.bytes);
}

static uint64_t used_blocks(const vxfs *fs) {
  uint64_t n = 0;
  for (uint32_t i = 0; i < fs->narenas; i++) n += fs->arenas[i].used / VXFS_BLKSZ - fs->arenas[i].nlog;
  return n;
}

// --- The model: sorted keys and their values ---

typedef struct entry {
  uint8_t k[VXFS_KEYMAX], v[VXFS_INLMAX];
  uint16_t nk, nv;
} entry;

static entry *model;
static uint32_t nmodel, capmodel;

static uint32_t model_find(const uint8_t *k, uint16_t nk, bool *found) {
  uint32_t lo = 0, hi = nmodel;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (vxfs_keycmp(model[mid].k, model[mid].nk, k, nk) < 0)
      lo = mid + 1;
    else
      hi = mid;
  }
  *found = lo < nmodel && vxfs_keycmp(model[lo].k, model[lo].nk, k, nk) == 0;
  return lo;
}

static void model_set(const uint8_t *k, uint16_t nk, const uint8_t *v, uint16_t nv) {
  bool found;
  uint32_t i = model_find(k, nk, &found);
  if (!found) {
    if (nmodel == capmodel) {
      capmodel = capmodel ? capmodel * 2 : 256;
      entry *more = realloc(model, capmodel * sizeof *model);
      if (!more) abort();
      model = more;
    }
    memmove(&model[i + 1], &model[i], (nmodel - i) * sizeof *model);
    nmodel++;
    memcpy(model[i].k, k, nk);
    model[i].nk = nk;
  }
  if (nv) memcpy(model[i].v, v, nv);
  model[i].nv = nv;
}

static void model_del(const uint8_t *k, uint16_t nk) {
  bool found;
  uint32_t i = model_find(k, nk, &found);
  if (!found) return;
  memmove(&model[i], &model[i + 1], (nmodel - i - 1) * sizeof *model);
  nmodel--;
}

static void model_reset(void) { nmodel = 0; }

// --- The tree's structure ---

typedef struct walk {
  uint64_t blocks, refs; // tree blocks, and data blocks named in values and buffered inserts
  uint32_t leaf_level_seen;
  bool ok;
} walk;

// Node bp at `level`; every key in it, buffered or not, in [lo, hi).
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree is tall
static void walk_node(vxfs *fs, vxfs_bptr bp, uint32_t level, const uint8_t *lo, uint16_t nlo,
                      const uint8_t *hi, uint16_t nhi, uint16_t fill, walk *w) {
  vxfs_blk *b = vxfs_get(fs, bp, level == 1 ? VXFS_TLEAF : VXFS_TPIVOT);
  if (!b) {
    w->ok = false;
    return;
  }
  w->blocks++;
  if (fill != 0xffff && fill != blk_fill(b)) w->ok = false;
  for (uint32_t i = 0; i < b->nval; i++) {
    vxfs_msg v = tab_get(b->data, i, false);
    bool in = (!lo || vxfs_keycmp(v.k, v.nk, lo, nlo) >= 0 || (level > 1 && i == 0)) &&
              (!hi || vxfs_keycmp(v.k, v.nk, hi, nhi) < 0);
    if (!in) w->ok = false;
    if (level == 1 && owns_block(&v)) w->refs++;
  }
  for (uint32_t i = 0; i < b->nbuf; i++) {
    vxfs_msg m = tab_get(b->data + VXFS_PIVSPC, i, true);
    if ((lo && vxfs_keycmp(m.k, m.nk, lo, nlo) < 0) || (hi && vxfs_keycmp(m.k, m.nk, hi, nhi) >= 0))
      w->ok = false;
    if (m.op == VXFS_OINSERT && owns_block(&m)) w->refs++;
  }
  if (level > 1) {
    if (!b->nval) w->ok = false;
    for (uint32_t i = 0; i < b->nval; i++) {
      vxfs_msg v = tab_get(b->data, i, false);
      vxfs_msg n = i + 1 < b->nval ? tab_get(b->data, i + 1, false) : (vxfs_msg){};
      walk_node(fs, vxfs_unpackbp(v.v), level - 1, i ? v.k : lo, i ? v.nk : nlo, n.k ? n.k : hi,
                n.k ? n.nk : nhi, vxfs_get16(v.v + VXFS_PTRSZ), w);
    }
  }
  vxfs_drop(fs, b);
}

// The tree's structure, and every block accounted for.
static bool tree_sane(world *w) {
  walk wk = {.ok = true};
  walk_node(&w->fs, w->t.root, w->t.height, nullptr, 0, nullptr, 0, 0xffff, &wk);
  bool space = used_blocks(&w->fs) == wk.blocks + wk.refs;
  if (!space)
    fprintf(stderr, "used %llu, tree %llu, data %llu\n", (unsigned long long)used_blocks(&w->fs),
            (unsigned long long)wk.blocks, (unsigned long long)wk.refs);
  return wk.ok && space && w->fs.err == VX_OK;
}

// Lookups of every key in the model, and of some that are not.
static bool lookups_agree(world *w) {
  uint8_t v[VXFS_INLMAX];
  uint16_t nv = 0;
  for (uint32_t i = 0; i < nmodel; i++) {
    if (vxfs_lookup(&w->fs, &w->t, model[i].k, model[i].nk, v, &nv) != VX_OK) return false;
    if (nv != model[i].nv || (nv && memcmp(v, model[i].v, nv) != 0)) return false;
  }
  uint8_t k[3] = {VXFS_KORPHAN, 0xff, 0xfe}; // never made
  return vxfs_lookup(&w->fs, &w->t, k, 3, v, &nv) == VX_ERR_NOT_FOUND;
}

static bool model_has_prefix(uint32_t i, const uint8_t *pfx, uint16_t npfx) {
  return i < nmodel && model[i].nk >= npfx && (!npfx || memcmp(model[i].k, pfx, npfx) == 0);
}

static bool scan_agrees(world *w, const uint8_t *pfx, uint16_t npfx) {
  vxfs_scan s;
  vxfs_scan_start(&s, &w->t, pfx, npfx);
  vxfs_kvp kv;
  uint32_t i = 0;
  bool ok = true;
  while (i < nmodel && npfx && vxfs_keycmp(model[i].k, model[i].nk, pfx, npfx) < 0) i++;
  while (vxfs_scan_next(&w->fs, &s, &kv)) {
    bool want = model_has_prefix(i, pfx, npfx);
    if (!want || kv.nk != model[i].nk || memcmp(kv.k, model[i].k, kv.nk) != 0 || kv.nv != model[i].nv ||
        (kv.nv && memcmp(kv.v, model[i].v, kv.nv) != 0)) {
      ok = false;
      break;
    }
    i++;
  }
  bool more = model_has_prefix(i, pfx, npfx);
  vxfs_scan_end(&w->fs, &s);
  return ok && !more && w->fs.err == VX_OK;
}

// --- Random batches ---

typedef struct batch {
  vxfs_msg m[1024];
  uint8_t bytes[64 * 1024];
  uint32_t n, used, size;
} batch;

static uint8_t *batch_bytes(batch *b, uint32_t n) {
  uint8_t *p = b->bytes + b->used;
  b->used += n;
  return p;
}

// A key: a Kent in one of a few directories, a Kdat, or a Kup.
static uint16_t random_key(uint8_t *k) {
  uint32_t kind = below(10);
  if (kind < 6) { // Kent pqid name
    k[0] = VXFS_KENT;
    vxfs_kput64(k + 1, below(4));
    uint16_t n = (uint16_t)(1 + below(below(8) == 0 ? 200 : 12));
    for (uint16_t i = 0; i < n; i++) k[9 + i] = (uint8_t)('a' + below(4));
    return (uint16_t)(9 + n);
  }
  if (kind < 9) { // Kdat qid off
    k[0] = VXFS_KDAT;
    vxfs_kput64(k + 1, below(8));
    vxfs_kput64(k + 9, (uint64_t)below(64) * VXFS_BLKSZ);
    return 17;
  }
  k[0] = VXFS_KUP;
  vxfs_kput64(k + 1, below(64));
  return 9;
}

static bool add(batch *b, uint8_t op, const uint8_t *k, uint16_t nk, const uint8_t *v, uint16_t nv) {
  uint32_t sz = 2 + 1 + 2 + nk + 2 + nv;
  if (b->n == 1024 || b->size + sz > VXFS_BUFSPC || b->used + nk + nv > sizeof b->bytes) return false;
  uint8_t *kp = batch_bytes(b, nk), *vp = batch_bytes(b, nv);
  memcpy(kp, k, nk);
  if (nv) memcpy(vp, v, nv);
  b->m[b->n++] = (vxfs_msg){.op = op, .k = kp, .nk = nk, .v = nv ? vp : nullptr, .nv = nv};
  b->size += sz;
  return true;
}

// A value for key k: an entry for a Kent, a data block or inline bytes for
// a Kdat, anything for the rest.
static uint16_t random_value(world *w, const uint8_t *k, uint8_t *v, bool big) {
  if (k[0] == VXFS_KENT) {
    vxfs_dir d = {.qid_path = rnd(), .mode = 0644, .length = below(1000), .uid = below(5)};
    vxfs_packdir(v, &d);
    return VXFS_DIRSZ;
  }
  if (k[0] == VXFS_KDAT && below(2)) {
    vxfs_blk *b = vxfs_new_block(&w->fs, VXFS_TDAT);
    if (!b) return 0;
    b->data[0] = (uint8_t)rnd();
    vxfs_write_block(&w->fs, b);
    v[0] = VXFS_VREF;
    vxfs_packbp(v + 1, b->bp);
    vxfs_drop(&w->fs, b);
    return 1 + VXFS_PTRSZ;
  }
  uint16_t n = (uint16_t)(below(4) == 0 ? below(VXFS_INLMAX + 1) : below(40));
  if (big) n = VXFS_INLMAX;
  if (k[0] == VXFS_KDAT && n) v[0] = VXFS_VINL;
  for (uint16_t i = k[0] == VXFS_KDAT ? 1 : 0; i < n; i++) v[i] = (uint8_t)rnd();
  return n;
}

// One random batch, to the model and the tree.
static bool run_batch(world *w, uint32_t max) {
  static batch b;
  b = (batch){};
  uint32_t want = 1 + below(max);
  uint8_t k[VXFS_KEYMAX], v[VXFS_INLMAX];
  for (uint32_t i = 0; i < want; i++) {
    uint32_t pick = below(100);
    uint16_t nk = 0;
    bool found = false;
    uint32_t at = 0;
    if (nmodel && pick < 45) { // an existing key
      at = below(nmodel);
      nk = model[at].nk;
      memcpy(k, model[at].k, nk);
      found = true;
    } else {
      nk = random_key(k);
      model_find(k, nk, &found);
      if (found) at = model_find(k, nk, &found);
    }
    uint32_t op = below(100);
    if (op < 55 || !found) {
      if (op >= 90 && !found) { // a clobber or clearb of nothing
        uint8_t o = k[0] == VXFS_KDAT ? VXFS_OCLEARB : VXFS_OCLOBBER;
        if (!add(&b, o, k, nk, nullptr, 0)) break;
        continue;
      }
      uint16_t nv = random_value(w, k, v, false);
      if (!add(&b, VXFS_OINSERT, k, nk, v, nv)) {
        if (nv == 1 + VXFS_PTRSZ && v[0] == VXFS_VREF && k[0] == VXFS_KDAT) { // unused: free it
          CHECK(vxfs_free(&w->fs, vxfs_unpackbp(v + 1)));
        }
        break;
      }
      model_set(k, nk, v, nv);
    } else if (op < 75) {
      if (!add(&b, VXFS_ODELETE, k, nk, nullptr, 0)) break;
      model_del(k, nk);
    } else if (op < 85) {
      uint8_t o = k[0] == VXFS_KDAT ? VXFS_OCLEARB : VXFS_OCLOBBER;
      if (!add(&b, o, k, nk, nullptr, 0)) break;
      model_del(k, nk);
    } else if (k[0] == VXFS_KENT && model[at].nv == VXFS_DIRSZ) {
      uint8_t st[1 + 8 + 4 + 8 + 4], *p = st + 1;
      st[0] = VXFS_WSIZE | VXFS_WMODE | VXFS_WMTIME | VXFS_WMUID;
      uint64_t len = rnd();
      uint32_t mode = (uint32_t)rnd(), muid = below(9);
      int64_t mtime = (int64_t)rnd();
      vxfs_put64(p, len), vxfs_put32(p + 8, mode), vxfs_put64(p + 12, (uint64_t)mtime),
          vxfs_put32(p + 20, muid);
      if (!add(&b, VXFS_OWSTAT, k, nk, st, sizeof st)) break;
      vxfs_dir d = vxfs_unpackdir(model[at].v);
      d.qid_vers++, d.length = len, d.mode = mode, d.qid_type = (uint8_t)(mode >> 24), d.mtime = mtime,
                    d.muid = muid;
      vxfs_packdir(v, &d);
      model_set(k, nk, v, VXFS_DIRSZ);
    }
  }
  vx_status st = vxfs_upsert(&w->fs, &w->t, b.m, b.n);
  CHECK(st == VX_OK);
  CHECK(vxfs_end_op(&w->fs));
  return st == VX_OK;
}

static void test_model(uint64_t seed, uint32_t batches, uint32_t max) {
  rng = seed;
  model_reset();
  world w;
  world_open(&w);
  uint32_t tall = 1;
  bool ok = true;
  for (uint32_t i = 0; i < batches && ok; i++) {
    ok = run_batch(&w, max);
    if (w.t.height > tall) tall = w.t.height;
    if (i % 16 == 0 || i + 1 == batches) {
      bool sane = tree_sane(&w), looked = lookups_agree(&w);
      CHECK(sane && looked);
      ok = ok && sane && looked;
      uint8_t pfx[9] = {VXFS_KENT};
      vxfs_kput64(pfx + 1, below(4));
      bool all = scan_agrees(&w, nullptr, 0), dir = scan_agrees(&w, pfx, 9), one = scan_agrees(&w, pfx, 1);
      CHECK(all && dir && one);
      ok = ok && all && dir && one;
      if (!ok) fprintf(stderr, "seed %llu: wrong after batch %u\n", (unsigned long long)seed, i);
    }
  }
  CHECK(tall >= 2); // the batches made pivots
  world_close(&w);
}

// Big values in key order until the tree is three tall, then every key
// deleted: back to one empty leaf, and the space all returned.
static void test_grow_shrink(void) {
  model_reset();
  world w;
  world_open(&w);
  uint64_t base = used_blocks(&w.fs);
  static batch b;
  uint8_t k[17], v[VXFS_INLMAX];
  memset(v, 0x33, sizeof v);
  uint32_t n = 0;
  while (w.t.height < 3 && n < 40000) {
    b = (batch){};
    for (;; n++) {
      k[0] = VXFS_KDAT;
      vxfs_kput64(k + 1, 7), vxfs_kput64(k + 9, n);
      if (!add(&b, VXFS_OINSERT, k, 17, v, sizeof v)) break;
      model_set(k, 17, v, sizeof v);
    }
    CHECK(vxfs_upsert(&w.fs, &w.t, b.m, b.n) == VX_OK && vxfs_end_op(&w.fs));
  }
  CHECK(w.t.height == 3 && tree_sane(&w) && lookups_agree(&w) && scan_agrees(&w, nullptr, 0));
  // Deleted in a scattered order.
  for (uint32_t done = 0; done < n;) {
    b = (batch){};
    for (; done < n; done++) {
      uint32_t i = (uint32_t)(((uint64_t)done * 7919) % n);
      k[0] = VXFS_KDAT;
      vxfs_kput64(k + 1, 7), vxfs_kput64(k + 9, i);
      if (!add(&b, VXFS_ODELETE, k, 17, nullptr, 0)) break;
      model_del(k, 17);
    }
    CHECK(vxfs_upsert(&w.fs, &w.t, b.m, b.n) == VX_OK && vxfs_end_op(&w.fs));
    if (done % 2048 < 256) CHECK(tree_sane(&w));
  }
  // Messages may still be buffered for keys now gone: clear them through with lookups' view.
  CHECK(nmodel == 0 && lookups_agree(&w) && scan_agrees(&w, nullptr, 0) && tree_sane(&w));
  // Flush what is buffered: clobbers enough to push everything down.
  for (uint32_t r = 0; r < 64 && w.t.height > 1; r++) {
    b = (batch){};
    for (;;) {
      k[0] = VXFS_KDAT;
      vxfs_kput64(k + 1, 7), vxfs_kput64(k + 9, below(n));
      if (!add(&b, VXFS_OCLOBBER, k, 17, nullptr, 0)) break;
    }
    CHECK(vxfs_upsert(&w.fs, &w.t, b.m, b.n) == VX_OK && vxfs_end_op(&w.fs));
  }
  CHECK(w.t.height == 1 && tree_sane(&w));
  CHECK(used_blocks(&w.fs) == base);
  world_close(&w);
}

static void test_refused(void) {
  model_reset();
  world w;
  world_open(&w);
  vxfs_tree before = w.t;
  uint8_t k[VXFS_KEYMAX + 1] = {VXFS_KENT}, v[VXFS_INLMAX + 1] = {};
  vxfs_msg bad[] = {
      {.op = VXFS_ONOP, .k = k, .nk = 1},
      {.op = VXFS_NMSG, .k = k, .nk = 1},
      {.op = VXFS_OINSERT, .k = k, .nk = 0},
      {.op = VXFS_OINSERT, .k = k, .nk = VXFS_KEYMAX + 1},
      {.op = VXFS_OINSERT, .k = k, .nk = 1, .v = v, .nv = VXFS_INLMAX + 1},
      {.op = VXFS_OINSERT, .k = k, .nk = 1, .v = nullptr, .nv = 4},
  };
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
    CHECK(vxfs_upsert(&w.fs, &w.t, &bad[i], 1) == VX_ERR_INVALID);
  // More than a buffer holds.
  static vxfs_msg many[64];
  for (uint32_t i = 0; i < 64; i++)
    many[i] = (vxfs_msg){.op = VXFS_OINSERT, .k = k, .nk = 1, .v = v, .nv = 200};
  CHECK(vxfs_upsert(&w.fs, &w.t, many, 64) == VX_ERR_INVALID);
  CHECK(w.fs.err == VX_OK && w.t.root.addr == before.root.addr);

  // Applying what cannot apply: a delete or wstat of a key that is not there.
  vxfs_msg del = {.op = VXFS_ODELETE, .k = k, .nk = 9};
  CHECK(vxfs_upsert(&w.fs, &w.t, &del, 1) == VX_ERR_INVALID && w.fs.err == VX_ERR_INVALID);
  world_close(&w);

  // A message buffered in a pivot that cannot apply: lookups and scans
  // report the damage.
  world_open(&w);
  vxfs_msg ins = {.op = VXFS_OINSERT, .k = k, .nk = 9, .v = v, .nv = 3};
  CHECK(vxfs_upsert(&w.fs, &w.t, &ins, 1) == VX_OK);
  // A root pivot over that leaf, its buffer holding a wstat the value is too short for.
  vxfs_blk *r = vxfs_new_block(&w.fs, VXFS_TPIVOT);
  kids one = {};
  CHECK(kids_push(&w.fs, &one, k, 9, w.t.root, 8));
  r->nval = 1, r->valsz = kids_pack(r->data, one.v, 1);
  uint8_t st[] = {VXFS_WUID, 1, 0, 0, 0};
  vxfs_msg ws = {.op = VXFS_OWSTAT, .k = k, .nk = 9, .v = st, .nv = sizeof st};
  r->nbuf = 1, r->bufsz = tab_pack(r->data + VXFS_PIVSPC, VXFS_BUFSPC, &ws, 1, true);
  CHECK(vxfs_write_block(&w.fs, r));
  vxfs_tree bad_tree = {.root = r->bp, .height = 2};
  vxfs_drop(&w.fs, r);
  kids_free(&w.fs, &one);
  uint8_t out[VXFS_INLMAX];
  uint16_t nout;
  CHECK(vxfs_lookup(&w.fs, &bad_tree, k, 9, out, &nout) == VX_ERR_INVALID);
  world_close(&w);
}

// The planner's parts: each fits, together they hold every entry in order,
// and there are as few as fit allows.
static void test_plan(void) {
  vxfs fs = {.mem = {.alloc = m_alloc, .free = m_free}};
  static uint32_t size[200];
  for (uint32_t n = 1; n < 200; n += 13) {
    for (uint32_t i = 0; i < n; i++) size[i] = 7 + (i * 37 % 770);
    uint64_t total = 0;
    for (uint32_t i = 0; i < n; i++) total += size[i];
    uint32_t *cuts = nullptr, parts = plan(&fs, size, n, VXFS_LEAFSPC, &cuts);
    CHECK(parts >= (total + VXFS_LEAFSPC - 1) / VXFS_LEAFSPC &&
          parts <= (total + VXFS_LEAFSPC - 1) / VXFS_LEAFSPC + 1);
    uint32_t at = 0;
    for (uint32_t p = 0; p < parts; p++) {
      uint64_t sz = 0;
      CHECK(cuts[p] > at);
      for (; at < cuts[p]; at++) sz += size[at];
      CHECK(sz <= VXFS_LEAFSPC);
    }
    CHECK(at == n);
    if (total > 2ull * VXFS_LEAFSPC) CHECK(parts >= 3);
    m_free(nullptr, cuts, parts * sizeof *cuts);
  }
}

int main(void) {
  test_plan();
  test_refused();
  test_grow_shrink();
  for (uint64_t seed = 1; seed <= 6; seed++)
    test_model(seed * 0x9E3779B97F4A7C15ull, 300, seed % 2 ? 40 : 400);
  free(model);
  return check_result();
}
