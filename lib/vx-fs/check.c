// vx-fs's checker (docs/11 §6, §14): a mounted volume walked whole, as
// `fsd -c` and the host's tests run it.
//
// Every block a structure reaches is checked: its hash, its structure, and
// for trees the order of keys across nodes, one height everywhere, and
// each child's fill as its parent records it. Snapshots and labels must
// agree: each label names a snapshot, each snapshot's label and fork
// counts are right, chains link both ways, a branch names the end of its
// chain, a deadlist lists only blocks its snapshot's predecessor holds.
// And space must add up: the blocks the arenas have in use are exactly
// those reached, each reached block in use, and nothing but snapshots'
// trees sharing a block.

#pragma once

#include "vol.c"

typedef struct vxfs_check {
  uint64_t used;        // blocks the arenas have in use
  uint64_t trees;       // distinct blocks of trees and the data they name (shared by snapshots)
  uint64_t other;       // logs, deadlists, the freed chain, deferred blocks
  uint64_t leaked;      // in use, reached by nothing
  uint64_t unallocated; // reached, but free (or outside every arena)
  uint64_t shared;      // reached by a log, deadlist or chain and something else too
  uint64_t damaged;     // unreadable, failing their hash, or malformed
  uint64_t bad_snaps;   // snapshots and labels that disagree
  uint64_t bad_lists;   // deadlists that do not fit their snapshot
  uint32_t snapshots, labels, dlists;
} vxfs_check;

typedef struct addrs {
  uint64_t *a;
  uint32_t n, cap;
} addrs;

static void addrs_add(vxfs *fs, addrs *s, uint64_t addr) {
  if (fs_grow(fs, (void **)&s->a, s->n, &s->cap, sizeof *s->a)) s->a[s->n++] = addr;
}

static void sift(uint64_t *a, uint32_t root, uint32_t n) {
  for (;;) {
    uint32_t child = 2 * root + 1;
    if (child >= n) return;
    if (child + 1 < n && a[child] < a[child + 1]) child++;
    if (a[root] >= a[child]) return;
    uint64_t t = a[root];
    a[root] = a[child], a[child] = t;
    root = child;
  }
}

static void addrs_sort(addrs *s) { // a heap sort: in place, and no worse than n log n
  for (uint32_t i = s->n / 2; i-- > 0;) sift(s->a, i, s->n);
  for (uint32_t end = s->n; end > 1; end--) {
    uint64_t t = s->a[0];
    s->a[0] = s->a[end - 1], s->a[end - 1] = t;
    sift(s->a, 0, end - 1);
  }
}

static bool addrs_has(const addrs *s, uint64_t addr) {
  uint32_t lo = 0, hi = s->n;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (s->a[mid] < addr)
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo < s->n && s->a[lo] == addr;
}

typedef struct checking {
  vxfs_vol *v;
  vxfs_check *c;
  addrs trees, other;
} checking;

// A tree node and all under it; every key in it, buffered or not, in
// [lo, hi); `fill` its parent's record of it (0xffff: a root).
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree is tall
static void check_node(checking *k, vxfs_bptr bp, uint32_t level, const uint8_t *lo, uint16_t nlo,
                       const uint8_t *hi, uint16_t nhi, uint16_t fill) {
  vxfs *fs = &k->v->fs;
  vx_status was = fs->err;
  vxfs_blk *b = vxfs_get(fs, bp, level == 1 ? VXFS_TLEAF : VXFS_TPIVOT);
  if (!b) {
    k->c->damaged++;
    if (was == VX_OK) fs->err = VX_OK; // go on: count it all
    return;
  }
  addrs_add(fs, &k->trees, bp.addr);
  bool bad = (fill != 0xffff && fill != blk_fill(b)) || (level > 1 && !b->nval);
  for (uint32_t i = 0; i < b->nval; i++) {
    vxfs_msg e = tab_get(b->data, i, false);
    bool first_pivot = level > 1 && i == 0; // a pivot's first key may be below the range
    if ((lo && !first_pivot && vxfs_keycmp(e.k, e.nk, lo, nlo) < 0) ||
        (hi && vxfs_keycmp(e.k, e.nk, hi, nhi) >= 0))
      bad = true;
    if (level == 1 && owns_block(&e)) addrs_add(fs, &k->trees, vxfs_unpackbp(e.v + 1).addr);
  }
  for (uint32_t i = 0; i < b->nbuf; i++) {
    vxfs_msg m = tab_get(b->data + VXFS_PIVSPC, i, true);
    if ((lo && vxfs_keycmp(m.k, m.nk, lo, nlo) < 0) || (hi && vxfs_keycmp(m.k, m.nk, hi, nhi) >= 0))
      bad = true;
    if (m.op == VXFS_OINSERT && owns_block(&m)) addrs_add(fs, &k->trees, vxfs_unpackbp(m.v + 1).addr);
  }
  if (bad) k->c->damaged++;
  for (uint32_t i = 0; level > 1 && i < b->nval; i++) {
    vxfs_msg e = tab_get(b->data, i, false);
    vxfs_msg n = i + 1 < b->nval ? tab_get(b->data, i + 1, false) : (vxfs_msg){};
    vxfs_bptr child = vxfs_unpackbp(e.v);
    if (child.gen > bp.gen) k->c->damaged++; // a node is never older than what it points at
    check_node(k, child, level - 1, i ? e.k : lo, i ? e.nk : nlo, n.k ? n.k : hi, n.k ? n.nk : nhi,
               vxfs_get16(e.v + VXFS_PTRSZ));
  }
  vxfs_drop(fs, b);
}

static void check_tree(checking *k, vxfs_bptr root, uint32_t height) {
  if (!height || height > VXFS_MAXHEIGHT) {
    k->c->damaged++;
    return;
  }
  check_node(k, root, height, nullptr, 0, nullptr, 0, 0xffff);
}

static bool add_other(vxfs_vol *v, uint64_t addr, void *ctx) {
  addrs_add(&v->fs, &((checking *)ctx)->other, addr);
  return true;
}

typedef struct snaprec {
  vxfs_snap s;
  uint32_t labels, forks;
} snaprec;

static snaprec *find_snap(snaprec *s, uint32_t n, uint64_t gen) {
  for (uint32_t i = 0; i < n; i++)
    if (s[i].s.gen == gen) return &s[i];
  return nullptr;
}

// Checks the volume: VX_OK if it is clean, INVALID if not; *c says what was
// found either way. Open branches' uncommitted trees count as reached.
[[maybe_unused]] static vx_status vxfs_check_volume(vxfs_vol *v, vxfs_check *c) {
  vxfs *fs = &v->fs;
  *c = (vxfs_check){};
  if (fs->err != VX_OK) return fs->err;
  checking k = {.v = v, .c = c};
  check_tree(&k, v->snap.root, v->snap.height);

  // Snapshots and labels.
  snaprec *snaps = nullptr;
  uint32_t ns = 0, caps = 0;
  vxfs_scan s;
  vxfs_kvp kv;
  uint8_t pfx = VXFS_KSNAP;
  vxfs_scan_start(&s, &v->snap, &pfx, 1);
  while (vxfs_scan_next(fs, &s, &kv)) {
    if (kv.nk != 9 || kv.nv != VXFS_SNAPSZ || vxfs_unpacksnap(kv.v).gen != vxfs_kget64(kv.k + 1)) {
      c->bad_snaps++;
      continue;
    }
    if (fs_grow(fs, (void **)&snaps, ns, &caps, sizeof *snaps))
      snaps[ns++] = (snaprec){.s = vxfs_unpacksnap(kv.v)};
  }
  vxfs_scan_end(fs, &s);
  c->snapshots = ns;
  pfx = VXFS_KLABEL;
  vxfs_scan_start(&s, &v->snap, &pfx, 1);
  while (vxfs_scan_next(fs, &s, &kv)) {
    c->labels++;
    snaprec *r = kv.nv == 12 ? find_snap(snaps, ns, vxfs_get64(kv.v)) : nullptr;
    if (!r || (r->s.succ &&
               (vxfs_get32(kv.v + 8) & VXFS_LMUT))) { // nothing named, or a branch not at its chain's end
      c->bad_snaps++;
      continue;
    }
    r->labels++;
  }
  vxfs_scan_end(fs, &s);
  for (uint32_t i = 0; i < ns; i++) {
    const vxfs_snap *t = &snaps[i].s;
    if (t->base && !t->pred) { // the first of a fork's chain
      snaprec *b = find_snap(snaps, ns, t->base);
      if (b)
        b->forks++;
      else
        c->bad_snaps++;
    }
    snaprec *p = t->pred ? find_snap(snaps, ns, t->pred) : nullptr,
            *n = t->succ ? find_snap(snaps, ns, t->succ) : nullptr;
    if ((t->pred && (!p || p->s.succ != t->gen)) || (t->succ && (!n || n->s.pred != t->gen))) c->bad_snaps++;
    if (t->pred && t->pred >= t->gen) c->bad_snaps++;
    check_tree(&k, t->root, t->height);
  }
  for (uint32_t i = 0; i < ns; i++) {
    const snaprec *r = &snaps[i];
    if (r->labels != r->s.nlbl || r->forks != r->s.nref || (!r->s.nlbl && !r->s.nref)) c->bad_snaps++;
  }
  for (uint32_t i = 0; i < VXFS_MAXBRANCH; i++)
    if (v->br[i].open) check_tree(&k, v->br[i].t.root, v->br[i].t.height);

  // Deadlists: their chains, and what they list, kept for after the sort.
  addrs listed = {};
  pfx = VXFS_KDLIST;
  vxfs_scan_start(&s, &v->snap, &pfx, 1);
  while (vxfs_scan_next(fs, &s, &kv)) {
    c->dlists++;
    snaprec *r = kv.nk == 25 && kv.nv == 16 ? find_snap(snaps, ns, vxfs_kget64(kv.k + 1)) : nullptr;
    if (!r || !r->s.pred || vxfs_kget64(kv.k + 9) > r->s.pred) {
      c->bad_lists++;
      continue;
    }
    uint64_t before = listed.n;
    bool ok = chain_each(v, vxfs_get64(kv.v), add_other, &k, false, true);
    // What it lists: the chain again, its entries.
    for (uint64_t hd = vxfs_get64(kv.v); ok && hd;) {
      vxfs_blk *b = vxfs_get(fs, (vxfs_bptr){.addr = hd}, VXFS_TDLIST);
      if (!b) {
        ok = false;
        break;
      }
      for (uint32_t j = 0; j < b->logsz; j += 8) addrs_add(fs, &listed, vxfs_get64(b->data + j));
      hd = b->logp.addr;
      vxfs_drop(fs, b);
    }
    if (!ok) c->damaged++, fs->err = VX_OK;
    if (ok && listed.n - before != vxfs_get64(kv.v + 8)) c->bad_lists++;
  }
  vxfs_scan_end(fs, &s);
  fs_release(fs, snaps, caps * sizeof *snaps);

  // Logs, the freed chain, what is deferred.
  for (uint32_t i = 0; i < fs->narenas; i++) {
    const vxfs_arena *a = &fs->arenas[i];
    c->used += a->used / VXFS_BLKSZ;
    vxfs_bptr bp = a->loghd;
    for (uint64_t j = 0; j < a->nlog; j++) {
      addrs_add(fs, &k.other, bp.addr);
      if (j + 1 == a->nlog) break;
      vxfs_blk *b = vxfs_get(fs, bp, VXFS_TLOG);
      if (!b) {
        c->damaged++, fs->err = VX_OK;
        break;
      }
      bp = b->logp;
      vxfs_drop(fs, b);
    }
    for (uint64_t j = 0; j < a->nretired; j++) addrs_add(fs, &k.other, a->retired[j]);
  }
  for (uint32_t i = 0; i < v->nfreedchain; i++) addrs_add(fs, &k.other, v->freedchain[i]);
  for (uint32_t i = 0; i < fs->ndeferred; i++) addrs_add(fs, &k.other, fs->deferred[i]);

  // Space: distinct trees' blocks, other blocks each once and in nothing else.
  addrs_sort(&k.trees);
  addrs_sort(&k.other);
  uint32_t nt = 0;
  for (uint32_t i = 0; i < k.trees.n; i++)
    if (!i || k.trees.a[i] != k.trees.a[i - 1]) k.trees.a[nt++] = k.trees.a[i];
  k.trees.n = nt;
  for (uint32_t i = 0; i < k.other.n; i++)
    if ((i && k.other.a[i] == k.other.a[i - 1]) || addrs_has(&k.trees, k.other.a[i])) c->shared++;
  c->trees = k.trees.n, c->other = k.other.n;
  for (int pass = 0; pass < 2; pass++) {
    const addrs *set = pass ? &k.other : &k.trees;
    for (uint32_t i = 0; i < set->n; i++) {
      vxfs_arena *a = arena_of(fs, set->a[i]);
      if (!a || range_has(a, set->a[i])) c->unallocated++;
    }
  }
  for (uint32_t i = 0; i < listed.n; i++) // a deadlist's blocks are its predecessor's still
    if (!addrs_has(&k.trees, listed.a[i])) c->bad_lists++;
  uint64_t reached = c->trees + c->other - c->shared;
  if (c->used > reached) c->leaked = c->used - reached;
  fs_release(fs, listed.a, listed.cap * sizeof *listed.a);
  fs_release(fs, k.trees.a, k.trees.cap * sizeof *k.trees.a);
  fs_release(fs, k.other.a, k.other.cap * sizeof *k.other.a);
  if (fs->err != VX_OK) return fs->err; // out of memory, say
  bool clean = !c->leaked && !c->unallocated && !c->shared && !c->damaged && !c->bad_snaps && !c->bad_lists &&
               c->used == reached;
  return clean ? VX_OK : VX_ERR_INVALID;
}
