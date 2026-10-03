// vxfs_crash_test.c: power cuts (docs/11 §14). A workload runs on a device
// that records every write and barrier: changes to branches, commits,
// labels, forks, labels removed, rollbacks, and logs long enough to be
// compressed. Then the record is replayed, and power is cut at every
// barrier and at random points between them. A write the last barrier
// covers has landed; one after it may have landed or not, in any order,
// and may be torn, some of its sectors new and the rest old. Every cut
// must mount, the checker must find it clean, and its labels must hold
// what they did at the last commit whose superblock landed: the one before
// the cut, or the one under way if its superblock got out.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fs/check.c"

static constexpr uint64_t BLOCKS = 2048;
static constexpr uint32_t SECTOR = 512;

static uint64_t rng = 5;
static uint64_t rnd(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}
static uint32_t below(uint32_t n) { return (uint32_t)(rnd() % n); }
static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }
static const vxfs_mem MEM = {.alloc = m_alloc, .free = m_free};

// --- The record ---

typedef struct event {
  uint64_t addr; // ~0: a barrier
  uint8_t *data;
  uint64_t commit; // the last commit whose superblock barrier had passed before this
} event;

typedef struct recorder {
  uint8_t *live;
  event *ev;
  uint32_t n, cap;
  bool on;
  uint64_t commit; // set by the workload as commits return
} recorder;

static void record(recorder *r, uint64_t addr, const void *data) {
  if (!r->on) return;
  if (r->n == r->cap) {
    r->cap = r->cap ? r->cap * 2 : 4096;
    event *more = realloc(r->ev, r->cap * sizeof *r->ev);
    if (!more) abort();
    r->ev = more;
  }
  event *e = &r->ev[r->n++];
  *e = (event){.addr = addr, .commit = r->commit};
  if (data) {
    e->data = malloc(VXFS_BLKSZ);
    memcpy(e->data, data, VXFS_BLKSZ);
  }
}

static vx_status rec_read(void *ctx, uint64_t addr, void *buf) {
  memcpy(buf, ((recorder *)ctx)->live + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status rec_write(void *ctx, uint64_t addr, const void *buf) {
  recorder *r = ctx;
  memcpy(r->live + addr, buf, VXFS_BLKSZ);
  record(r, addr, buf);
  return VX_OK;
}
static vx_status rec_barrier(void *ctx) {
  record(ctx, ~0ull, nullptr);
  return VX_OK;
}

// --- The workload's expectations: each commit's labels and contents ---

static constexpr uint32_t NKEYS = 200, MAXLABELS = 12;
typedef struct model {
  uint8_t nv[NKEYS];
  uint8_t v[NKEYS][32];
} model;

typedef struct state { // what a commit left: its labels and what each holds
  uint32_t n;
  char name[MAXLABELS][12];
  model m[MAXLABELS];
} state;

static state *states; // by commit number
static uint64_t nstates;

static uint16_t key_of(uint32_t i, uint8_t *k) {
  if (i % 2) {
    k[0] = VXFS_KDAT;
    vxfs_kput64(k + 1, 2), vxfs_kput64(k + 9, (uint64_t)i * VXFS_BLKSZ);
    return 17;
  }
  k[0] = VXFS_KENT;
  vxfs_kput64(k + 1, 1);
  return (uint16_t)(9 + snprintf((char *)k + 9, 16, "e%u", i));
}

typedef struct label {
  char name[12];
  bool used, branch;
  model now, committed;
  vxfs_branch *br;
} label;

static label labels[MAXLABELS];
static uint32_t serial;

static void change(vxfs_vol *v, label *l) {
  static uint8_t keys[32][32], vals[32][32];
  vxfs_msg msg[32];
  uint32_t n = 0;
  bool seen[NKEYS] = {};
  for (uint32_t c = 0; c < 32; c++) {
    uint32_t i = below(NKEYS);
    if (seen[i]) continue;
    seen[i] = true;
    uint16_t nk = key_of(i, keys[n]);
    if (l->now.nv[i] && below(3) == 0) {
      msg[n] = (vxfs_msg){.op = i % 2 ? VXFS_OCLEARB : VXFS_ODELETE, .k = keys[n], .nk = nk};
      l->now.nv[i] = 0;
      n++;
      continue;
    }
    uint8_t nv;
    if (i % 2 && below(2)) {
      vxfs_blk *b = vxfs_new_data(&v->fs, &l->br->t);
      if (!b) abort();
      memset(b->data, (int)rnd(), VXFS_BLKSZ);
      CHECK(vxfs_write_block(&v->fs, b));
      vals[n][0] = VXFS_VREF;
      vxfs_packbp(vals[n] + 1, b->bp);
      vxfs_drop(&v->fs, b);
      nv = 1 + VXFS_PTRSZ;
    } else {
      nv = (uint8_t)(1 + below(31));
      for (uint8_t j = 0; j < nv; j++) vals[n][j] = (uint8_t)rnd();
      if (i % 2) vals[n][0] = VXFS_VINL;
    }
    msg[n] = (vxfs_msg){.op = VXFS_OINSERT, .k = keys[n], .nk = nk, .v = vals[n], .nv = nv};
    memcpy(l->now.v[i], vals[n], nv);
    l->now.nv[i] = nv;
    n++;
  }
  CHECK(vxfs_upsert(&v->fs, &l->br->t, msg, n) == VX_OK && vxfs_end_op(&v->fs));
}

static void note_state(uint64_t commit) {
  if (commit >= nstates) {
    uint64_t more = commit + 64;
    state *s = realloc(states, more * sizeof *states);
    if (!s) abort();
    states = s;
    nstates = more;
  }
  state *s = &states[commit];
  s->n = 0;
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (labels[i].used) {
      memcpy(s->name[s->n], labels[i].name, sizeof labels[i].name);
      s->m[s->n++] = labels[i].committed;
    }
}

static void commit(vxfs_vol *v, recorder *r) {
  CHECK(vxfs_commit(v) == VX_OK);
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (labels[i].used && labels[i].branch) labels[i].committed = labels[i].now;
  r->commit = v->sb.commit;
  note_state(r->commit);
}

static label *new_label(bool branch) {
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (!labels[i].used) {
      labels[i] = (label){.used = true, .branch = branch};
      snprintf(labels[i].name, sizeof labels[i].name, "%c%u", branch ? 'b' : 's', serial++);
      return &labels[i];
    }
  return nullptr;
}

static label *pick(int branch) {
  label *c[MAXLABELS];
  uint32_t n = 0;
  for (uint32_t i = 0; i < MAXLABELS; i++)
    if (labels[i].used && (branch < 0 || labels[i].branch == (branch == 1))) c[n++] = &labels[i];
  return n ? c[below(n)] : nullptr;
}

static uint32_t branches(void) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < MAXLABELS; i++) n += labels[i].used && labels[i].branch;
  return n;
}

static void workload(vxfs_vol *v, recorder *r, uint32_t rounds) {
  for (uint32_t round = 0; round < rounds; round++) {
    uint32_t op = below(100);
    label *l, *s;
    if (op < 52) {
      if ((l = pick(1))) change(v, l);
    } else if (op < 55) { // a log compressed: its old chain is freed by the next commit
      vxfs_arena *a = &v->fs.arenas[below(v->fs.narenas)];
      if (!a->nretired) CHECK(vxfs_log_compress(&v->fs, a));
    } else if (op < 75) {
      commit(v, r);
    } else if (op < 83) {
      if ((l = pick(1)) && (s = new_label(false))) {
        CHECK(vxfs_label(v, l->name, s->name, 0) == VX_OK);
        s->committed = l->committed;
      }
    } else if (op < 88) {
      if (branches() < 4 && (l = pick(-1)) && (s = new_label(true))) {
        CHECK(vxfs_label(v, l->name, s->name, VXFS_LMUT) == VX_OK);
        s->committed = s->now = l->committed;
        CHECK(vxfs_branch_open(v, s->name, &s->br) == VX_OK);
      }
    } else if (op < 95) {
      if ((l = pick(0))) {
        CHECK(vxfs_unlabel(v, l->name) == VX_OK);
        l->used = false;
      }
    } else if ((s = pick(0)) && (l = pick(1))) { // a rollback: committed first, so the branch can close
      commit(v, r);
      CHECK(vxfs_branch_close(l->br) == VX_OK && vxfs_rollback(v, l->name, s->name) == VX_OK);
      l->committed = l->now = s->committed;
      CHECK(vxfs_branch_open(v, l->name, &l->br) == VX_OK);
    }
  }
  commit(v, r);
}

// --- Replaying the record, with cuts ---

typedef struct cutdev {
  const uint8_t *durable; // everything up to the last barrier
  uint64_t *addr;         // and over it, blocks as the cut left them, and as mounting writes them
  uint8_t **data;
  uint32_t n, cap;
} cutdev;

static uint8_t *cut_find(cutdev *c, uint64_t addr) {
  for (uint32_t i = 0; i < c->n; i++)
    if (c->addr[i] == addr) return c->data[i];
  return nullptr;
}

static uint8_t *cut_block(cutdev *c, uint64_t addr) { // the overlay's copy, made if need be
  uint8_t *b = cut_find(c, addr);
  if (b) return b;
  if (c->n == c->cap) {
    c->cap = c->cap ? c->cap * 2 : 64;
    uint64_t *a = realloc(c->addr, c->cap * sizeof *c->addr);
    if (!a) abort();
    c->addr = a;
    uint8_t **d = realloc(c->data, c->cap * sizeof *c->data);
    if (!d) abort();
    c->data = d;
  }
  b = malloc(VXFS_BLKSZ);
  memcpy(b, c->durable + addr, VXFS_BLKSZ);
  c->addr[c->n] = addr, c->data[c->n++] = b;
  return b;
}

static vx_status cut_read(void *ctx, uint64_t addr, void *buf) {
  cutdev *c = ctx;
  uint8_t *b = cut_find(c, addr);
  memcpy(buf, b ? b : c->durable + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status cut_write(void *ctx, uint64_t addr, const void *buf) {
  memcpy(cut_block(ctx, addr), buf, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status cut_barrier([[maybe_unused]] void *ctx) { return VX_OK; }

static void cut_free(cutdev *c) {
  for (uint32_t i = 0; i < c->n; i++) free(c->data[i]);
  free(c->addr), free(c->data);
  *c = (cutdev){.durable = c->durable};
}

static uint32_t cuts, torn, at_newer;

// Mounts what a cut left (durable, and of the writes since the last
// barrier, those in `pending` chosen to land) and checks it.
// With tear_sb, every write lands, but the superblocks torn: their first
// sector new, the rest old.
static bool try_cut(const uint8_t *durable, event **pending, uint32_t np, uint64_t done, bool tear_sb) {
  cutdev c = {.durable = durable};
  // The writes in flight: each lands or not, in a shuffled order, some torn.
  uint32_t order[4096];
  if (np > 4096) abort();
  for (uint32_t i = 0; i < np; i++) order[i] = i;
  for (uint32_t i = np; i > 1; i--) {
    uint32_t j = below(i), t = order[i - 1];
    order[i - 1] = order[j], order[j] = t;
  }
  uint32_t keep = tear_sb ? 1 : below(4); // 0: none land, 1: all, else each by chance
  uint64_t last = (BLOCKS - 1) * VXFS_BLKSZ;
  for (uint32_t i = 0; i < np; i++) {
    const event *e = pending[tear_sb ? i : order[i]];
    if (keep == 0 || (keep > 1 && below(2))) continue;
    uint8_t *b = cut_block(&c, e->addr);
    if (tear_sb && (e->addr == 0 || e->addr == last)) {
      torn++;
      memcpy(b, e->data, SECTOR);
    } else if (!tear_sb && below(8) == 0) { // torn: sectors at random
      torn++;
      for (uint32_t s = 0; s < VXFS_BLKSZ / SECTOR; s++)
        if (below(2)) memcpy(b + (size_t)s * SECTOR, e->data + (size_t)s * SECTOR, SECTOR);
    } else {
      memcpy(b, e->data, VXFS_BLKSZ);
    }
  }
  cuts++;
  vxfs_vol v;
  vxfs_dev dev = {
      .ctx = &c, .read = cut_read, .write = cut_write, .barrier = cut_barrier, .size = BLOCKS * VXFS_BLKSZ};
  vx_status st = vxfs_mount(&v, dev, MEM, 256);
  bool ok = st == VX_OK;
  if (!ok) fprintf(stderr, "cut after commit %llu: mount: %d\n", (unsigned long long)done, st);
  vxfs_check chk;
  if (ok && vxfs_check_volume(&v, &chk) != VX_OK) {
    fprintf(stderr,
            "cut after commit %llu: check: used %llu leaked %llu unalloc %llu shared %llu damaged %llu snaps "
            "%llu "
            "lists %llu\n",
            (unsigned long long)done, (unsigned long long)chk.used, (unsigned long long)chk.leaked,
            (unsigned long long)chk.unallocated, (unsigned long long)chk.shared,
            (unsigned long long)chk.damaged, (unsigned long long)chk.bad_snaps,
            (unsigned long long)chk.bad_lists);
    ok = false;
  }
  uint64_t got = v.sb.commit;
  if (ok && got != done && got != done + 1) {
    fprintf(stderr, "cut after commit %llu: mounted commit %llu\n", (unsigned long long)done,
            (unsigned long long)got);
    ok = false;
  }
  if (ok && got == done + 1) at_newer++;
  // Its labels, and what they hold.
  if (ok && got < nstates) {
    const state *s = &states[got];
    ok = chk.labels == s->n;
    uint8_t k[32], val[VXFS_INLMAX];
    for (uint32_t i = 0; ok && i < s->n; i++) {
      vxfs_tree t;
      ok = vxfs_snap_open(&v, s->name[i], &t) == VX_OK;
      for (uint32_t j = 0; ok && j < NKEYS; j++) {
        uint16_t nv = 0;
        vx_status ls = vxfs_lookup(&v.fs, &t, k, key_of(j, k), val, &nv);
        ok = s->m[i].nv[j] ? ls == VX_OK && nv == s->m[i].nv[j] && memcmp(val, s->m[i].v[j], nv) == 0
                           : ls == VX_ERR_NOT_FOUND;
      }
      if (!ok)
        fprintf(stderr, "cut after commit %llu: label %s differs\n", (unsigned long long)done, s->name[i]);
    }
  }
  // And it goes on: a change and a commit on what the cut left.
  vxfs_branch *br;
  if (ok && got < nstates && states[got].n && states[got].name[0][0] == 'b' &&
      vxfs_branch_open(&v, states[got].name[0], &br) == VX_OK) {
    uint8_t k[32], val[4] = {1, 2, 3, 4};
    vxfs_msg m = {.op = VXFS_OINSERT, .k = k, .nk = key_of(0, k), .v = val, .nv = 4};
    ok = vxfs_upsert(&v.fs, &br->t, &m, 1) == VX_OK && vxfs_end_op(&v.fs) && vxfs_commit(&v) == VX_OK &&
         vxfs_check_volume(&v, &chk) == VX_OK;
    if (!ok) fprintf(stderr, "cut after commit %llu: no commit after it\n", (unsigned long long)done);
  }
  vxfs_unmount(&v);
  cut_free(&c);
  return ok;
}

static void test_cuts(uint64_t seed, uint32_t rounds, uint32_t narenas) {
  rng = seed;
  memset(labels, 0, sizeof labels);
  serial = 0;
  recorder r = {.live = calloc(1, BLOCKS * VXFS_BLKSZ)};
  vxfs_dev dev = {
      .ctx = &r, .read = rec_read, .write = rec_write, .barrier = rec_barrier, .size = BLOCKS * VXFS_BLKSZ};
  label *m = new_label(true);
  const char *names[] = {m->name};
  vxfs_vol v;
  CHECK(vxfs_format(&v, dev, MEM, 256, narenas, names, 1) == VX_OK);
  v.fs.compress_at = 2; // long logs compressed by commits too
  CHECK(vxfs_branch_open(&v, m->name, &m->br) == VX_OK);
  r.commit = v.sb.commit;
  note_state(r.commit);
  uint8_t *durable = malloc(BLOCKS * VXFS_BLKSZ);
  memcpy(durable, r.live, BLOCKS * VXFS_BLKSZ); // the formatted volume, all landed
  r.on = true;
  workload(&v, &r, rounds);
  r.on = false;
  vxfs_unmount(&v);

  // The replay: durable advances at each barrier; cuts at each barrier and between.
  event *pending[4096];
  uint32_t np = 0, bad = 0;
  uint64_t done = states ? 1 : 0;
  for (uint32_t i = 0; i < r.n && bad < 3; i++) {
    event *e = &r.ev[i];
    if (e->addr != ~0ull) {
      if (np == 4096) abort();
      pending[np++] = e;
      if (below(6) == 0 && !try_cut(durable, pending, np, e->commit, false)) bad++; // between barriers
      continue;
    }
    if (!try_cut(durable, pending, np, e->commit, false)) bad++; // just before the barrier
    bool sbs = false;
    for (uint32_t j = 0; j < np; j++) sbs = sbs || pending[j]->addr == 0;
    if (sbs && !try_cut(durable, pending, np, e->commit, true)) bad++; // the superblocks torn
    for (uint32_t j = 0; j < np; j++) memcpy(durable + pending[j]->addr, pending[j]->data, VXFS_BLKSZ);
    np = 0;
    done = e->commit;
    if (!try_cut(durable, pending, 0, done, false)) bad++; // just after it
  }
  CHECK(bad == 0);
  CHECK(r.n > 500);
  for (uint32_t i = 0; i < r.n; i++) free(r.ev[i].data);
  free(r.ev);
  free(r.live);
  free(durable);
}

int main(void) {
  // Two arenas; and 24, a superblock of more than one sector, which a cut can tear.
  for (uint64_t seed = 1; seed <= 3; seed++) test_cuts(seed * 0x9E3779B97F4A7C15ull, 220, seed == 3 ? 24 : 2);
  CHECK(cuts > 1000 && at_newer > 100 && torn > 500); // the cuts reached what they are for
  free(states);
  return check_result();
}
