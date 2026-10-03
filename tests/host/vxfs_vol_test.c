// vxfs_vol_test.c: lib/vx-fs volumes. Formatted with branches; changed,
// committed, and mounted again: what was committed is there and what was
// not is gone. A branch's old snapshots are deleted as it moves, and space
// adds up after every commit and mount: the checker finds the volume clean. A damaged superblock or arena header falls
// back to its copy; both damaged, the mount refuses.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fs/check.c"

typedef struct memdev {
  uint8_t *bytes;
  uint64_t size, barriers;
} memdev;

static vx_status md_read(void *ctx, uint64_t addr, void *buf) {
  memcpy(buf, ((memdev *)ctx)->bytes + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status md_write(void *ctx, uint64_t addr, const void *buf) {
  memcpy(((memdev *)ctx)->bytes + addr, buf, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status md_barrier(void *ctx) {
  ((memdev *)ctx)->barriers++;
  return VX_OK;
}
static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }
static const vxfs_mem MEM = {.alloc = m_alloc, .free = m_free};

static vxfs_dev dev_of(memdev *d) {
  return (vxfs_dev){.ctx = d, .read = md_read, .write = md_write, .barrier = md_barrier, .size = d->size};
}

static uint64_t rng = 7;
static uint64_t rnd(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}

// --- The checker: clean, and how many snapshots ---

static void report(const vxfs_check *c) {
  fprintf(stderr,
          "check: used %llu trees %llu other %llu leaked %llu unallocated %llu shared %llu damaged %llu "
          "snaps %llu lists %llu\n",
          (unsigned long long)c->used, (unsigned long long)c->trees, (unsigned long long)c->other,
          (unsigned long long)c->leaked, (unsigned long long)c->unallocated, (unsigned long long)c->shared,
          (unsigned long long)c->damaged, (unsigned long long)c->bad_snaps, (unsigned long long)c->bad_lists);
}

static bool space_adds_up(vxfs_vol *v, uint32_t *nsnap) {
  vxfs_check c;
  bool ok = vxfs_check_volume(v, &c) == VX_OK;
  if (!ok) report(&c);
  if (nsnap) *nsnap = c.snapshots;
  return ok;
}

// --- A model of one branch: keys k0..kN with values, or none ---

static constexpr uint32_t NKEYS = 600;
typedef struct model {
  uint16_t nv[NKEYS];
  bool has[NKEYS], data[NKEYS]; // data: a Kdat whose value names a block
  uint8_t v[NKEYS][64];
} model;

static uint16_t key_of(uint32_t i, uint8_t *k) {
  if (i % 3 == 0) { // a Kdat
    k[0] = VXFS_KDAT;
    vxfs_kput64(k + 1, 5), vxfs_kput64(k + 9, (uint64_t)i * VXFS_BLKSZ);
    return 17;
  }
  k[0] = VXFS_KENT;
  vxfs_kput64(k + 1, 1);
  int n = snprintf((char *)k + 9, 32, "name-%u", i);
  return (uint16_t)(9 + n);
}

// A batch of random changes to branch br and the model.
static void change(vxfs_vol *v, vxfs_branch *br, model *m, uint32_t count) {
  static uint8_t keys[64][32], vals[64][64];
  vxfs_msg msg[64];
  uint32_t n = 0;
  for (uint32_t c = 0; c < count; c++) {
    uint32_t i = (uint32_t)(rnd() % NKEYS);
    uint16_t nk = key_of(i, keys[n]);
    bool dup = false; // one message a key, so the model's order cannot differ
    for (uint32_t j = 0; j < n; j++) dup = dup || (msg[j].nk == nk && !memcmp(msg[j].k, keys[n], nk));
    if (dup) continue;
    if (m->has[i] && rnd() % 3 == 0) {
      msg[n] = (vxfs_msg){.op = i % 3 == 0 ? VXFS_OCLEARB : VXFS_ODELETE, .k = keys[n], .nk = nk};
      n++;
      m->has[i] = false;
      continue;
    }
    uint16_t nv;
    if (i % 3 == 0 && rnd() % 2) { // a data block
      vxfs_blk *b = vxfs_new_data(&v->fs, &br->t);
      CHECK(b != nullptr);
      if (!b) return;
      b->data[0] = (uint8_t)rnd();
      CHECK(vxfs_write_block(&v->fs, b));
      vals[n][0] = VXFS_VREF;
      vxfs_packbp(vals[n] + 1, b->bp);
      vxfs_drop(&v->fs, b);
      nv = 1 + VXFS_PTRSZ;
      m->data[i] = true;
    } else {
      nv = (uint16_t)(1 + rnd() % 60);
      for (uint16_t j = 0; j < nv; j++) vals[n][j] = (uint8_t)rnd();
      if (i % 3 == 0) vals[n][0] = VXFS_VINL;
      m->data[i] = false;
    }
    msg[n] = (vxfs_msg){.op = VXFS_OINSERT, .k = keys[n], .nk = nk, .v = vals[n], .nv = nv};
    memcpy(m->v[i], vals[n], nv);
    n++;
    m->nv[i] = nv, m->has[i] = true;
  }
  CHECK(vxfs_upsert(&v->fs, &br->t, msg, n) == VX_OK);
  CHECK(vxfs_end_op(&v->fs));
}

static bool agrees(vxfs_vol *v, const vxfs_tree *t, const model *m) {
  uint8_t k[32], val[VXFS_INLMAX];
  for (uint32_t i = 0; i < NKEYS; i++) {
    uint16_t nv = 0;
    vx_status st = vxfs_lookup(&v->fs, t, k, key_of(i, k), val, &nv);
    if (m->has[i] ? st != VX_OK || nv != m->nv[i] || memcmp(val, m->v[i], nv) != 0 : st != VX_ERR_NOT_FOUND) {
      fprintf(stderr, "key %u: %d\n", i, st);
      return false;
    }
  }
  return true;
}

static memdev *memdev_new(uint64_t blocks) {
  memdev *d = calloc(1, sizeof *d);
  d->size = blocks * VXFS_BLKSZ;
  d->bytes = calloc(1, d->size);
  return d;
}

static void memdev_free(memdev *d) {
  free(d->bytes);
  free(d);
}

static const char *const BRANCHES[] = {"main", "cfg", "adm"};

static void test_format_mount(void) {
  memdev *d = memdev_new(4096);
  vxfs_vol v;
  CHECK(vxfs_format(&v, dev_of(d), MEM, 256, 2, BRANCHES, 3) == VX_OK);
  uint32_t snaps = 0;
  CHECK(space_adds_up(&v, &snaps) && snaps == 3);
  CHECK(v.sb.commit == 1 && v.fs.narenas == 2);
  vxfs_unmount(&v);

  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK);
  CHECK(v.sb.commit == 1 && space_adds_up(&v, &snaps) && snaps == 3);
  uint64_t gen;
  uint32_t flags;
  CHECK(vxfs_label_get(&v, "cfg", &gen, &flags) == VX_OK && flags == VXFS_LMUT);
  CHECK(vxfs_label_get(&v, "nope", &gen, &flags) == VX_ERR_NOT_FOUND);
  vxfs_branch *br;
  CHECK(vxfs_branch_open(&v, "nope", &br) == VX_ERR_NOT_FOUND);
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && br->t.height == 1);
  vxfs_unmount(&v);

  // Too small, and not a volume.
  memdev *tiny = memdev_new(9);
  CHECK(vxfs_format(&v, dev_of(tiny), MEM, 256, 0, BRANCHES, 1) == VX_ERR_INVALID);
  vxfs_unmount(&v);
  memdev_free(tiny);
  memdev *blank = memdev_new(64);
  CHECK(vxfs_mount(&v, dev_of(blank), MEM, 256) == VX_ERR_INVALID);
  vxfs_unmount(&v);
  memdev_free(blank);
  memdev_free(d);
}

static void test_commits(void) {
  memdev *d = memdev_new(8192);
  vxfs_vol v;
  CHECK(vxfs_format(&v, dev_of(d), MEM, 512, 3, BRANCHES, 3) == VX_OK);
  static model m, mc; // the model as changed, and as last committed
  m = (model){}, mc = (model){};
  vxfs_branch *br, *cfg;
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && vxfs_branch_open(&v, "cfg", &cfg) == VX_OK);
  uint64_t used_after[40];
  for (uint32_t c = 0; c < 40; c++) {
    for (uint32_t k = 0; k < 8; k++) change(&v, br, &m, 40);
    if (c % 5 == 0) { // cfg too, now and then: two branches in one commit
      static model scratch;
      change(&v, cfg, &scratch, 10);
    }
    CHECK(vxfs_commit(&v) == VX_OK);
    mc = m;
    uint32_t snaps = 0;
    CHECK(space_adds_up(&v, &snaps) && snaps == 3); // the old snapshots deleted as the branches move
    used_after[c] = 0;
    for (uint32_t i = 0; i < v.fs.narenas; i++) used_after[c] += v.fs.arenas[i].used;
    if (c % 8 == 7) {         // mounted again: as committed
      change(&v, br, &m, 30); // not committed: lost
      vxfs_unmount(&v);
      CHECK(vxfs_mount(&v, dev_of(d), MEM, 512) == VX_OK);
      CHECK(space_adds_up(&v, &snaps) && snaps == 3);
      CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && vxfs_branch_open(&v, "cfg", &cfg) == VX_OK);
      CHECK(agrees(&v, &br->t, &mc));
      m = mc;
    }
  }
  // Space does not grow while the contents do not: the keys are bounded.
  CHECK(used_after[39] < used_after[20] * 2);
  vxfs_tree ro;
  CHECK(vxfs_snap_open(&v, "main", &ro) == VX_OK && agrees(&v, &ro, &mc));
  vxfs_unmount(&v);
  memdev_free(d);
}

static void test_damage(void) {
  memdev *d = memdev_new(4096);
  vxfs_vol v;
  CHECK(vxfs_format(&v, dev_of(d), MEM, 256, 2, BRANCHES, 3) == VX_OK);
  static model m;
  m = (model){};
  vxfs_branch *br;
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK);
  change(&v, br, &m, 50);
  CHECK(vxfs_commit(&v) == VX_OK);
  uint64_t base0 = v.fs.arenas[0].base, foot0 = base0 + VXFS_BLKSZ + v.fs.arenas[0].size;
  vxfs_unmount(&v);
  uint64_t last = d->size - VXFS_BLKSZ;

  // The primary superblock damaged: the backup.
  d->bytes[100] ^= 1;
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK && v.sb.commit == 2);
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && agrees(&v, &br->t, &m));
  vxfs_unmount(&v);
  d->bytes[last + 100] ^= 1; // and the backup too: nothing
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_ERR_INVALID);
  vxfs_unmount(&v);
  d->bytes[100] ^= 1, d->bytes[last + 100] ^= 1;

  // An arena's header damaged: its footer.
  d->bytes[base0 + 20] ^= 1;
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK);
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && agrees(&v, &br->t, &m) && space_adds_up(&v, nullptr));
  vxfs_unmount(&v);
  d->bytes[foot0 + 20] ^= 1; // both
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_ERR_INVALID);
  vxfs_unmount(&v);
  d->bytes[base0 + 20] ^= 1, d->bytes[foot0 + 20] ^= 1;

  // An older superblock with a newer one beside it: the newer wins.
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK);
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK);
  static uint8_t old_sb[VXFS_BLKSZ];
  memcpy(old_sb, d->bytes, VXFS_BLKSZ);
  change(&v, br, &m, 20);
  CHECK(vxfs_commit(&v) == VX_OK);
  vxfs_unmount(&v);
  memcpy(d->bytes + last, old_sb, VXFS_BLKSZ);
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK && v.sb.commit == 3);
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && agrees(&v, &br->t, &m));
  vxfs_unmount(&v);
  memdev_free(d);
}

// The checker finds what is wrong: a leaked block, a damaged one, a
// snapshot record that disagrees; and damage to free space is no damage.
static void test_checker(void) {
  memdev *d = memdev_new(4096);
  vxfs_vol v;
  CHECK(vxfs_format(&v, dev_of(d), MEM, 256, 2, BRANCHES, 3) == VX_OK);
  static model m;
  m = (model){};
  vxfs_branch *br;
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK);
  for (int i = 0; i < 40; i++) change(&v, br, &m, 50); // enough for pivots
  CHECK(vxfs_commit(&v) == VX_OK);
  vxfs_check c;
  CHECK(vxfs_check_volume(&v, &c) == VX_OK && c.trees > 4 && c.snapshots == 3 && c.labels == 3);

  // A block allocated and reached by nothing: leaked.
  CHECK(block_alloc(&v.fs, VXFS_TDAT) != 0);
  CHECK(vxfs_check_volume(&v, &c) == VX_ERR_INVALID && c.leaked == 1);
  vxfs_unmount(&v);
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK); // never committed, so gone
  CHECK(vxfs_check_volume(&v, &c) == VX_OK);

  // A free block written over: nothing is wrong.
  uint64_t free_at = v.fs.arenas[1].free[0].off;
  memset(d->bytes + free_at, 0x5a, VXFS_BLKSZ);
  CHECK(vxfs_check_volume(&v, &c) == VX_OK);
  // A leaf of main's damaged: found, and counted rather than stopping the walk.
  CHECK(vxfs_branch_open(&v, "main", &br) == VX_OK && br->t.height >= 2);
  vxfs_blk *root = vxfs_get(&v.fs, br->t.root, VXFS_TPIVOT);
  vxfs_bptr leaf = vxfs_unpackbp(tab_get(root->data, 0, false).v);
  vxfs_drop(&v.fs, root);
  vxfs_unmount(&v);
  d->bytes[leaf.addr + 200] ^= 0x01;
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK);
  CHECK(vxfs_check_volume(&v, &c) == VX_ERR_INVALID && c.damaged == 1 && c.snapshots == 3);
  vxfs_unmount(&v);
  d->bytes[leaf.addr + 200] ^= 0x01;

  // A snapshot whose label count is wrong.
  CHECK(vxfs_mount(&v, dev_of(d), MEM, 256) == VX_OK);
  uint64_t gen;
  uint32_t flags;
  CHECK(vxfs_label_get(&v, "cfg", &gen, &flags) == VX_OK);
  vxfs_snap s;
  CHECK(snap_get(&v, gen, &s) == VX_OK);
  s.nlbl = 2;
  sbatch *b = batch_new(&v);
  CHECK(snap_set(&v, b, &s) && snap_flush(&v, b));
  free(b);
  CHECK(vxfs_check_volume(&v, &c) == VX_ERR_INVALID && c.bad_snaps == 1);
  vxfs_unmount(&v);
  memdev_free(d);
}

int main(void) {
  test_checker();
  test_format_mount();
  test_commits();
  test_damage();
  return check_result();
}
