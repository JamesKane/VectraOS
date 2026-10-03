// vxfs_snap_test.c: lib/vx-fs snapshots and branches against a model.
// Random rounds of changes to several branches, commits, labels on
// snapshots, forks, labels removed, branches deleted and rolled back. After
// every commit the checker must find the volume clean (every block
// reachable, nothing leaked, deadlists fitting their snapshots), and every
// label must hold what the model says it did when it was made; now and then
// the volume is mounted again and all of it checked once more. Then the
// cases by hand: a middle snapshot deleted, a fork outliving its base's
// label, the base reclaimed when the fork goes, and refusals.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fs/check.c"

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

static uint64_t rng = 99;
static uint64_t rnd(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}
static uint32_t below(uint32_t n) { return (uint32_t)(rnd() % n); }

// --- Models ---

static constexpr uint32_t NKEYS = 300;
typedef struct model {
  uint8_t nv[NKEYS]; // 0: none
  uint8_t v[NKEYS][40];
} model;

static uint16_t key_of(uint32_t i, uint8_t *k) {
  if (i % 2) {
    k[0] = VXFS_KDAT;
    vxfs_kput64(k + 1, 3), vxfs_kput64(k + 9, (uint64_t)i * VXFS_BLKSZ);
    return 17;
  }
  k[0] = VXFS_KENT;
  vxfs_kput64(k + 1, 1);
  return (uint16_t)(9 + snprintf((char *)k + 9, 32, "f%u", i));
}

static void change(vxfs_vol *v, vxfs_branch *br, model *m, uint32_t count) {
  static uint8_t keys[48][32], vals[48][40];
  vxfs_msg msg[48];
  uint32_t n = 0;
  bool seen[NKEYS] = {};
  for (uint32_t c = 0; c < count && n < 48; c++) {
    uint32_t i = below(NKEYS);
    if (seen[i]) continue;
    seen[i] = true;
    uint16_t nk = key_of(i, keys[n]);
    if (m->nv[i] && below(3) == 0) {
      msg[n] = (vxfs_msg){.op = i % 2 ? VXFS_OCLEARB : VXFS_ODELETE, .k = keys[n], .nk = nk};
      n++;
      m->nv[i] = 0;
      continue;
    }
    uint8_t nv;
    if (i % 2 && below(2)) { // a data block
      vxfs_blk *b = vxfs_new_data(&v->fs, &br->t);
      CHECK(b != nullptr);
      if (!b) return;
      b->data[0] = (uint8_t)rnd();
      CHECK(vxfs_write_block(&v->fs, b));
      vals[n][0] = VXFS_VREF;
      vxfs_packbp(vals[n] + 1, b->bp);
      vxfs_drop(&v->fs, b);
      nv = 1 + VXFS_PTRSZ;
    } else {
      nv = (uint8_t)(1 + below(39));
      for (uint8_t j = 0; j < nv; j++) vals[n][j] = (uint8_t)rnd();
      if (i % 2) vals[n][0] = VXFS_VINL;
    }
    msg[n] = (vxfs_msg){.op = VXFS_OINSERT, .k = keys[n], .nk = nk, .v = vals[n], .nv = nv};
    memcpy(m->v[i], vals[n], nv);
    m->nv[i] = nv;
    n++;
  }
  CHECK(vxfs_upsert(&v->fs, &br->t, msg, n) == VX_OK);
  CHECK(vxfs_end_op(&v->fs));
}

static bool agrees(vxfs_vol *v, const vxfs_tree *t, const model *m) {
  uint8_t k[32], val[VXFS_INLMAX];
  for (uint32_t i = 0; i < NKEYS; i++) {
    uint16_t nv = 0;
    vx_status st = vxfs_lookup(&v->fs, t, k, key_of(i, k), val, &nv);
    bool ok =
        m->nv[i] ? st == VX_OK && nv == m->nv[i] && memcmp(val, m->v[i], nv) == 0 : st == VX_ERR_NOT_FOUND;
    if (!ok) return false;
  }
  return true;
}

// --- The world: labels, each a snapshot or a branch, with what they hold ---

static constexpr uint32_t MAXLABELS = 48;
typedef struct label {
  char name[16];
  bool used, branch;
  model *now, *committed; // a snapshot's are one
  vxfs_branch *br;        // a branch's, open
} label;

typedef struct world {
  memdev d;
  vxfs_vol v;
  label l[MAXLABELS];
  uint32_t serial, commits;
} world;

static bool clean(world *w) {
  vxfs_check c;
  vx_status st = vxfs_check_volume(&w->v, &c);
  if (st != VX_OK)
    fprintf(
        stderr,
        "check: used %llu trees %llu other %llu leaked %llu unalloc %llu shared %llu damaged %llu snaps %llu "
        "lists %llu\n",
        (unsigned long long)c.used, (unsigned long long)c.trees, (unsigned long long)c.other,
        (unsigned long long)c.leaked, (unsigned long long)c.unallocated, (unsigned long long)c.shared,
        (unsigned long long)c.damaged, (unsigned long long)c.bad_snaps, (unsigned long long)c.bad_lists);
  return st == VX_OK;
}

static bool labels_agree(world *w) {
  for (uint32_t i = 0; i < MAXLABELS; i++) {
    label *l = &w->l[i];
    if (!l->used) continue;
    vxfs_tree t;
    if (vxfs_snap_open(&w->v, l->name, &t) != VX_OK || !agrees(&w->v, &t, l->committed)) {
      fprintf(stderr, "label %s disagrees\n", l->name);
      return false;
    }
  }
  return true;
}

static label *new_label(world *w, bool branch, const char *prefix) {
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (!w->l[i].used) {
      label *l = &w->l[i];
      *l = (label){.used = true, .branch = branch};
      snprintf(l->name, sizeof l->name, "%s%u", prefix, w->serial++);
      l->committed = calloc(1, sizeof(model));
      l->now = branch ? calloc(1, sizeof(model)) : l->committed;
      return l;
    }
  return nullptr;
}

static void drop_label(label *l) {
  if (l->now != l->committed) free(l->now);
  free(l->committed);
  *l = (label){};
}

static label *pick(world *w, int branch) { // -1: either
  uint32_t n = 0;
  label *cand[MAXLABELS];
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (w->l[i].used && (branch < 0 || w->l[i].branch == (branch == 1))) cand[n++] = &w->l[i];
  return n ? cand[below(n)] : nullptr;
}

static uint32_t count(world *w, bool branch) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < MAXLABELS; i++) n += w->l[i].used && w->l[i].branch == branch;
  return n;
}

static void commit(world *w) {
  CHECK(vxfs_commit(&w->v) == VX_OK);
  w->commits++;
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (w->l[i].used && w->l[i].branch) memcpy(w->l[i].committed, w->l[i].now, sizeof(model));
}

static void remount(world *w) {
  vxfs_unmount(&w->v);
  vxfs_dev dev = {.ctx = &w->d, .read = md_read, .write = md_write, .barrier = md_barrier, .size = w->d.size};
  CHECK(vxfs_mount(&w->v, dev, MEM, 512) == VX_OK);
  for (uint32_t i = 0; i < MAXLABELS; i++) {
    label *l = &w->l[i];
    if (!l->used || !l->branch) continue;
    CHECK(vxfs_branch_open(&w->v, l->name, &l->br) == VX_OK);
    memcpy(l->now, l->committed, sizeof(model)); // uncommitted changes are gone
  }
}

static void round_of(world *w) {
  uint32_t op = below(100);
  label *l;
  if (op < 45) { // changes
    if ((l = pick(w, 1))) change(&w->v, l->br, l->now, 1 + below(30));
  } else if (op < 60) {
    commit(w);
    CHECK(clean(w) && labels_agree(w));
  } else if (op < 72) { // a snapshot of a branch's last commit
    label *b = pick(w, 1), *s = b ? new_label(w, false, "s") : nullptr;
    if (s) {
      CHECK(vxfs_label(&w->v, b->name, s->name, 0) == VX_OK);
      memcpy(s->committed, b->committed, sizeof(model));
    }
  } else if (op < 80) { // a fork of anything
    label *from = count(w, true) < 6 ? pick(w, -1) : nullptr, *f = from ? new_label(w, true, "b") : nullptr;
    if (f) {
      CHECK(vxfs_label(&w->v, from->name, f->name, VXFS_LMUT) == VX_OK);
      memcpy(f->committed, from->committed, sizeof(model));
      memcpy(f->now, from->committed, sizeof(model));
      CHECK(vxfs_branch_open(&w->v, f->name, &f->br) == VX_OK);
    }
  } else if (op < 90) { // a snapshot's label removed
    if ((l = pick(w, 0))) {
      CHECK(vxfs_unlabel(&w->v, l->name) == VX_OK);
      drop_label(l);
    }
  } else if (op < 95) { // a branch deleted: committed, closed, removed
    if (count(w, true) > 1 && (l = pick(w, 1))) {
      commit(w);
      CHECK(vxfs_branch_close(l->br) == VX_OK && vxfs_unlabel(&w->v, l->name) == VX_OK);
      drop_label(l);
    }
  } else { // a branch rolled back to a snapshot
    label *s = pick(w, 0);
    if (s && (l = pick(w, 1))) {
      commit(w);
      CHECK(vxfs_branch_close(l->br) == VX_OK && vxfs_rollback(&w->v, l->name, s->name) == VX_OK);
      memcpy(l->committed, s->committed, sizeof(model));
      memcpy(l->now, s->committed, sizeof(model));
      CHECK(vxfs_branch_open(&w->v, l->name, &l->br) == VX_OK);
    }
  }
}

static void world_open(world *w, uint64_t blocks) {
  *w = (world){};
  w->d.size = blocks * VXFS_BLKSZ;
  w->d.bytes = calloc(1, w->d.size);
  vxfs_dev dev = {.ctx = &w->d, .read = md_read, .write = md_write, .barrier = md_barrier, .size = w->d.size};
  label *m = new_label(w, true, "main");
  const char *names[] = {m->name};
  CHECK(vxfs_format(&w->v, dev, MEM, 512, 4, names, 1) == VX_OK);
  CHECK(vxfs_branch_open(&w->v, m->name, &m->br) == VX_OK);
}

static void world_close(world *w) {
  vxfs_unmount(&w->v);
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (w->l[i].used) drop_label(&w->l[i]);
  free(w->d.bytes);
}

static void test_random(uint64_t seed, uint32_t rounds) {
  rng = seed;
  static world w;
  world_open(&w, 16384);
  bool ok = true;
  for (uint32_t r = 0; r < rounds && ok; r++) {
    round_of(&w);
    if (r % 97 == 96) {
      commit(&w);
      remount(&w);
      ok = clean(&w) && labels_agree(&w);
      CHECK(ok);
    }
    ok = ok && check_failures == 0;
    if (!ok) fprintf(stderr, "seed %llu: wrong at round %u\n", (unsigned long long)seed, r);
  }
  commit(&w);
  CHECK(clean(&w) && labels_agree(&w));
  CHECK(w.commits > 20 && w.serial > 10);
  world_close(&w);
}

// By hand: a fork outlives its base's label; deleting the fork reclaims
// the base; a middle snapshot deleted keeps both neighbours whole.
static void test_cases(void) {
  static world w;
  world_open(&w, 8192);
  label *m = &w.l[0];
  change(&w.v, m->br, m->now, 40);
  commit(&w);
  label *s1 = new_label(&w, false, "s");
  CHECK(vxfs_label(&w.v, m->name, s1->name, 0) == VX_OK);
  memcpy(s1->committed, m->committed, sizeof(model));
  change(&w.v, m->br, m->now, 40);
  commit(&w);
  label *s2 = new_label(&w, false, "s");
  CHECK(vxfs_label(&w.v, m->name, s2->name, 0) == VX_OK);
  memcpy(s2->committed, m->committed, sizeof(model));
  change(&w.v, m->br, m->now, 40);
  commit(&w);
  CHECK(clean(&w) && labels_agree(&w));
  uint32_t snaps_before = 0;
  {
    vxfs_check c;
    CHECK(vxfs_check_volume(&w.v, &c) == VX_OK && c.dlists > 0);
    snaps_before = c.snapshots;
  }

  // The middle one deleted: its neighbours still hold what they did.
  CHECK(vxfs_unlabel(&w.v, s2->name) == VX_OK);
  drop_label(s2);
  commit(&w);
  CHECK(clean(&w) && labels_agree(&w));

  // A fork of s1, then s1's label removed: the fork keeps the snapshot.
  label *f = new_label(&w, true, "b");
  CHECK(vxfs_label(&w.v, s1->name, f->name, VXFS_LMUT) == VX_OK);
  memcpy(f->committed, s1->committed, sizeof(model));
  memcpy(f->now, s1->committed, sizeof(model));
  CHECK(vxfs_branch_open(&w.v, f->name, &f->br) == VX_OK);
  change(&w.v, f->br, f->now, 40);
  commit(&w);
  CHECK(vxfs_unlabel(&w.v, s1->name) == VX_OK);
  drop_label(s1);
  commit(&w);
  CHECK(clean(&w) && labels_agree(&w));
  // The fork deleted: its base, now named by nothing, goes too.
  CHECK(vxfs_branch_close(f->br) == VX_OK && vxfs_unlabel(&w.v, f->name) == VX_OK);
  drop_label(f);
  commit(&w);
  vxfs_check c;
  CHECK(vxfs_check_volume(&w.v, &c) == VX_OK && c.snapshots == 1 && snaps_before == 3);
  CHECK(labels_agree(&w));

  // Refusals.
  CHECK(vxfs_label(&w.v, m->name, m->name, 0) == VX_ERR_EXISTS);
  CHECK(vxfs_label(&w.v, "nothing", "x", 0) == VX_ERR_NOT_FOUND);
  CHECK(vxfs_unlabel(&w.v, m->name) == VX_ERR_BAD_STATE); // open
  change(&w.v, m->br, m->now, 5);
  CHECK(vxfs_branch_close(m->br) == VX_ERR_BAD_STATE); // changed, not committed
  label *s3 = new_label(&w, false, "s");
  CHECK(vxfs_label(&w.v, m->name, s3->name, 0) == VX_OK);
  memcpy(s3->committed, m->committed, sizeof(model));
  CHECK(vxfs_rollback(&w.v, s3->name, m->name) == VX_ERR_ACCESS); // a snapshot is not a branch
  vxfs_branch *br;
  CHECK(vxfs_branch_open(&w.v, s3->name, &br) == VX_ERR_ACCESS);
  commit(&w);
  CHECK(clean(&w) && labels_agree(&w));
  world_close(&w);
}

int main(void) {
  test_cases();
  for (uint64_t seed = 1; seed <= 4; seed++) test_random(seed * 0x9E3779B97F4A7C15ull, 1500);
  return check_result();
}
