// vx-fs volumes (docs/11 §5, §6): the superblocks, arenas' headers and
// footers, the snapshot tree, branches, deadlists, and the commit, after
// gefs's snap.c, load.c, ream.c and sync.
//
// A volume is two superblocks (its first block and its last), arenas, and
// in them the snapshot tree. That tree holds the snapshots (Ksnap), the
// labels naming them (Klabel), and their deadlists (Kdlist). A branch is a
// label that moves: at each commit its tree becomes a new snapshot, and the
// label names that. A snapshot left with no label and no fork is deleted at
// once, which is what reclaims space as a branch moves on.
//
// Deadlists, as gefs's: every block pointer carries its birth generation.
// A block a branch kills (born before the generation being built, so still
// in the last snapshot) goes on the deadlist keyed by the snapshot being
// built and the block's birth. Deleting snapshot S, followed by T and
// preceded by P: S's lists born at or before P still hold blocks P has, and
// become T's; the rest, and T's lists born after P, held blocks only S had,
// and are freed. Unlike gefs's, a deadlist is a chain written once, and
// Kdlist's key has a sequence number: merging lists re-keys them, and never
// writes a block a commit can see.
//
// The commit (11 §6): the data written so far made durable by a barrier;
// the branches' new snapshots put in the snapshot tree, their kills in
// deadlists; the blocks the commit frees written as a chain the superblock
// names; each arena's log written, and its header (saying how much of the
// log the commit covers); a barrier; both superblocks; a barrier; the
// footers. Then what the commit freed is free. A crash before the
// superblocks lands leaves the last commit; mounting frees again what the
// commit it finds freed, whose frees were logged past what it covers.

#pragma once

#include "tree.c"

static constexpr uint32_t VXFS_MAXBRANCH = 16;
static constexpr uint32_t VXFS_DLPER = VXFS_LOGSPC / 8; // addresses in a deadlist block

typedef struct vxfs_branch {
  uint8_t name[VXFS_LABELMAX];
  uint16_t nname;
  bool open;
  vxfs_tree t;  // as changed
  vxfs_snap at; // the snapshot it was at, at the last commit
} vxfs_branch;

typedef struct vxfs_vol {
  vxfs fs;
  vxfs_sb sb; // as of the last commit
  vxfs_tree snap;
  uint64_t nextgen, nextqid, nextdl;
  uint64_t *arenahash;  // each arena's header hash, as the next superblock records it
  uint64_t *freedchain; // the last commit's freed chain: deferred at the next
  uint32_t nfreedchain, capfreedchain;
  vxfs_blk **hdr; // the headers a commit writes, held until their footers are
  vxfs_branch br[VXFS_MAXBRANCH];
} vxfs_vol;

static vx_status vol_bad(vxfs_vol *v) {
  fs_fail(&v->fs, VX_ERR_INVALID);
  return VX_ERR_INVALID;
}

// --- Keys ---

static uint16_t key_snap(uint8_t *k, uint64_t gen) {
  k[0] = VXFS_KSNAP;
  vxfs_kput64(k + 1, gen);
  return 9;
}

static uint16_t key_label(uint8_t *k, const uint8_t *name, uint16_t n) {
  k[0] = VXFS_KLABEL;
  memcpy(k + 1, name, n);
  return (uint16_t)(1 + n);
}

static uint16_t key_dlist(uint8_t *k, uint64_t snap, uint64_t birth, uint64_t seq) {
  k[0] = VXFS_KDLIST;
  vxfs_kput64(k + 1, snap), vxfs_kput64(k + 9, birth), vxfs_kput64(k + 17, seq);
  return 25;
}

// --- The snapshot tree ---

// A batch of messages for the snapshot tree, their bytes kept with them.
typedef struct sbatch {
  vxfs_msg m[64];
  uint8_t bytes[64 * (26 + VXFS_SNAPSZ)];
  uint32_t n, used, size;
} sbatch;

static bool snap_flush(vxfs_vol *v, sbatch *b) {
  vx_status st = vxfs_upsert(&v->fs, &v->snap, b->m, b->n);
  b->n = b->used = b->size = 0;
  return st == VX_OK && vxfs_end_op(&v->fs);
}

static bool snap_msg(vxfs_vol *v, sbatch *b, uint8_t op, const uint8_t *k, uint16_t nk, const uint8_t *val,
                     uint16_t nv) {
  uint32_t sz = 2 + 1 + 2 + nk + 2 + nv;
  if ((b->n == 64 || b->size + sz > VXFS_BUFSPC || b->used + nk + nv > sizeof b->bytes) && !snap_flush(v, b))
    return false;
  uint8_t *p = b->bytes + b->used;
  memcpy(p, k, nk);
  if (nv) memcpy(p + nk, val, nv);
  b->m[b->n++] = (vxfs_msg){.op = op, .k = p, .nk = nk, .v = nv ? p + nk : nullptr, .nv = nv};
  b->used += nk + nv, b->size += sz;
  return true;
}

static bool snap_set(vxfs_vol *v, sbatch *b, const vxfs_snap *s) {
  uint8_t k[9], val[VXFS_SNAPSZ];
  vxfs_packsnap(val, s);
  return snap_msg(v, b, VXFS_OINSERT, k, key_snap(k, s->gen), val, VXFS_SNAPSZ);
}

static bool label_set(vxfs_vol *v, sbatch *b, const uint8_t *name, uint16_t n, uint64_t gen, uint32_t flags) {
  uint8_t k[VXFS_KEYMAX], val[12];
  vxfs_put64(val, gen), vxfs_put32(val + 8, flags);
  return snap_msg(v, b, VXFS_OINSERT, k, key_label(k, name, n), val, 12);
}

static vx_status snap_get(vxfs_vol *v, uint64_t gen, vxfs_snap *s) {
  uint8_t k[9], val[VXFS_INLMAX];
  uint16_t nv = 0;
  vx_status st = vxfs_lookup(&v->fs, &v->snap, k, key_snap(k, gen), val, &nv);
  if (st != VX_OK) return st;
  if (nv != VXFS_SNAPSZ) return vol_bad(v);
  *s = vxfs_unpacksnap(val);
  return s->gen == gen ? VX_OK : vol_bad(v);
}

[[maybe_unused]] static vx_status vxfs_label_get(vxfs_vol *v, const char *name, uint64_t *gen,
                                                 uint32_t *flags) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  if (!n || n > VXFS_LABELMAX) return VX_ERR_INVALID;
  uint8_t k[VXFS_KEYMAX], val[VXFS_INLMAX];
  uint16_t nv = 0;
  vx_status st = vxfs_lookup(&v->fs, &v->snap, k, key_label(k, (const uint8_t *)name, n), val, &nv);
  if (st != VX_OK) return st;
  if (nv != 12) return vol_bad(v);
  *gen = vxfs_get64(val), *flags = vxfs_get32(val + 8);
  return VX_OK;
}

// --- Deadlists and other chains ---

// Writes addresses as a chain of deadlist blocks, the last written first;
// its head, or 0 for none. The chain's own blocks are added to `blocks` if
// it is given.
static uint64_t chain_write(vxfs_vol *v, const uint64_t *a, uint64_t n, uint64_t **blocks, uint32_t *nblocks,
                            uint32_t *cap) {
  vxfs *fs = &v->fs;
  tree_enter(fs, &v->snap);
  uint64_t next = 0;
  for (uint64_t at = 0; at < n;) {
    vxfs_blk *b = vxfs_new_block(fs, VXFS_TDLIST);
    if (!b) return 0;
    uint64_t k = n - at < VXFS_DLPER ? n - at : VXFS_DLPER;
    for (uint64_t i = 0; i < k; i++) vxfs_put64(b->data + 8 * i, a[at + i]);
    b->logsz = (uint16_t)(8 * k);
    b->logp = (vxfs_bptr){.addr = next};
    next = b->bp.addr;
    bool ok = vxfs_write_block(fs, b);
    vxfs_drop(fs, b);
    if (blocks) {
      ok = ok && fs_grow(fs, (void **)blocks, *nblocks, cap, sizeof **blocks);
      if (ok) (*blocks)[(*nblocks)++] = next;
    }
    if (!ok) return 0;
    at += k;
  }
  return next;
}

// Each address in the chain at hd, then each of the chain's own blocks, to
// fn. False on damage: a loop, or a block that is not a deadlist's.
static bool chain_each(vxfs_vol *v, uint64_t hd, bool (*fn)(vxfs_vol *, uint64_t, void *), void *ctx,
                       bool listed, bool own) {
  vxfs *fs = &v->fs;
  for (uint64_t chain = 0; hd; chain++) {
    if (chain > fs->dev.size / VXFS_BLKSZ) return fs_fail(fs, VX_ERR_INVALID);
    vxfs_blk *b = vxfs_get(fs, (vxfs_bptr){.addr = hd}, VXFS_TDLIST);
    if (!b) return false;
    bool ok = true;
    for (uint32_t i = 0; listed && ok && i < b->logsz; i += 8) ok = fn(v, vxfs_get64(b->data + i), ctx);
    uint64_t self = hd;
    hd = b->logp.addr;
    vxfs_drop(fs, b);
    if (ok && own) ok = fn(v, self, ctx);
    if (!ok) return false;
  }
  return true;
}

static bool defer_one(vxfs_vol *v, uint64_t addr, [[maybe_unused]] void *ctx) {
  return vxfs_defer(&v->fs, addr);
}
static bool free_one(vxfs_vol *v, uint64_t addr, [[maybe_unused]] void *ctx) {
  return block_dealloc(&v->fs, addr);
}

typedef struct dlent {
  uint64_t birth, seq, hd, count;
} dlent;

// The deadlists of snapshot gen, read out of the snapshot tree.
static bool dlists_of(vxfs_vol *v, uint64_t gen, dlent **out, uint32_t *n, uint32_t *cap) {
  uint8_t pfx[9] = {VXFS_KDLIST};
  vxfs_kput64(pfx + 1, gen);
  vxfs_scan s;
  vxfs_scan_start(&s, &v->snap, pfx, 9);
  vxfs_kvp kv;
  bool ok = true;
  while (ok && vxfs_scan_next(&v->fs, &s, &kv)) {
    if (kv.nk != 25 || kv.nv != 16) {
      ok = fs_fail(&v->fs, VX_ERR_INVALID);
      break;
    }
    ok = fs_grow(&v->fs, (void **)out, *n, cap, sizeof **out);
    if (ok)
      (*out)[(*n)++] =
          (dlent){vxfs_kget64(kv.k + 9), vxfs_kget64(kv.k + 17), vxfs_get64(kv.v), vxfs_get64(kv.v + 8)};
  }
  vxfs_scan_end(&v->fs, &s);
  return ok && v->fs.err == VX_OK;
}

static bool dlist_put(vxfs_vol *v, sbatch *b, uint64_t snap, uint64_t birth, uint64_t seq, uint64_t hd,
                      uint64_t count) {
  uint8_t k[25], val[16];
  vxfs_put64(val, hd), vxfs_put64(val + 8, count);
  return snap_msg(v, b, VXFS_OINSERT, k, key_dlist(k, snap, birth, seq), val, 16);
}

static bool dlist_del(vxfs_vol *v, sbatch *b, uint64_t snap, uint64_t birth, uint64_t seq) {
  uint8_t k[25];
  return snap_msg(v, b, VXFS_ODELETE, k, key_dlist(k, snap, birth, seq), nullptr, 0);
}

// Snapshot s is deleted, followed by succ (0: none) and preceded by pred:
// its deadlists born at or before pred become succ's; the rest are freed,
// with succ's born after pred. With no successor, its lists' blocks are
// still pred's: only the lists themselves go (the tree's own blocks are the
// caller's to sweep).
static bool reclaim(vxfs_vol *v, sbatch *b, uint64_t s, uint64_t succ, uint64_t pred) {
  dlent *d = nullptr;
  uint32_t n = 0, cap = 0;
  bool ok = dlists_of(v, s, &d, &n, &cap);
  for (uint32_t i = 0; ok && i < n; i++) {
    ok = dlist_del(v, b, s, d[i].birth, d[i].seq);
    if (ok && succ && d[i].birth <= pred)
      ok = dlist_put(v, b, succ, d[i].birth, d[i].seq, d[i].hd, d[i].count);
    else if (ok)
      ok = chain_each(v, d[i].hd, defer_one, nullptr, succ != 0, true);
  }
  n = 0;
  if (ok && succ && snap_flush(v, b)) ok = dlists_of(v, succ, &d, &n, &cap);
  for (uint32_t i = 0; ok && i < n; i++)
    if (d[i].birth > pred)
      ok = dlist_del(v, b, succ, d[i].birth, d[i].seq) &&
           chain_each(v, d[i].hd, defer_one, nullptr, true, true);
  fs_release(&v->fs, d, cap * sizeof *d);
  return ok;
}

// Writes the kills of generation `death` born at or before `keep` as
// deadlists of snapshot `death`; the rest are deferred (nothing kept still
// has them).
static bool write_kills(vxfs_vol *v, sbatch *b, uint64_t death, uint64_t keep) {
  vxfs *fs = &v->fs;
  // Gathered by birth: one list each (sorted by birth, a few at a time).
  bool ok = true;
  uint64_t *a = nullptr;
  uint32_t na = 0, cap = 0;
  for (;;) {
    uint64_t birth = 0; // the least birth of this death not yet written
    for (uint32_t i = 0; i < fs->ndead; i++)
      if (fs->dead[i].death == death && fs->dead[i].birth && (!birth || fs->dead[i].birth < birth))
        birth = fs->dead[i].birth;
    if (!birth || !ok) break;
    na = 0;
    for (uint32_t i = 0; ok && i < fs->ndead; i++) {
      vxfs_dead *e = &fs->dead[i];
      if (e->death != death || e->birth != birth) continue;
      if (birth > keep)
        ok = vxfs_defer(fs, e->addr);
      else if ((ok = fs_grow(fs, (void **)&a, na, &cap, sizeof *a)))
        a[na++] = e->addr;
      e->birth = 0; // written
    }
    if (ok && na) {
      uint64_t hd = chain_write(v, a, na, nullptr, nullptr, nullptr);
      ok = hd && dlist_put(v, b, death, birth, v->nextdl++, hd, na);
    }
  }
  fs_release(fs, a, cap * sizeof *a);
  return ok;
}

// --- Snapshots of branches at a commit ---

// Branch br's tree becomes a new snapshot, which its label names. The one
// it was at is kept if anything else names it, and deleted if not.
static bool branch_update(vxfs_vol *v, sbatch *b, vxfs_branch *br) {
  vxfs_snap o;
  if (!snap_flush(v, b)) return false; // reads below see every change so far
  if (snap_get(v, br->at.gen, &o) != VX_OK) return fs_fail(&v->fs, VX_ERR_INVALID);
  vxfs_snap t = {.root = br->t.root,
                 .height = br->t.height,
                 .flags = o.flags,
                 .gen = br->t.memgen,
                 .base = o.base,
                 .nlbl = 1};
  if (o.nlbl) o.nlbl--;
  bool del = o.nlbl == 0 && o.nref == 0;
  bool ok = true;
  if (del) {
    t.pred = o.pred;
    if (o.pred) {
      vxfs_snap p;
      ok = snap_get(v, o.pred, &p) == VX_OK;
      p.succ = t.gen;
      ok = ok && snap_set(v, b, &p);
    }
    uint8_t k[9];
    ok = ok && snap_msg(v, b, VXFS_ODELETE, k, key_snap(k, o.gen), nullptr, 0);
  } else {
    t.pred = o.gen;
    o.succ = t.gen;
    ok = snap_set(v, b, &o);
  }
  ok = ok && snap_set(v, b, &t) && label_set(v, b, br->name, br->nname, t.gen, VXFS_LMUT);
  // Its kills: those still held by what precedes the new snapshot are its
  // deadlists; the rest are free once this commit is.
  ok = ok && write_kills(v, b, t.gen, del ? o.pred : o.gen);
  if (ok && del) ok = snap_flush(v, b) && reclaim(v, b, o.gen, t.gen, o.pred);
  if (ok) br->at = t;
  return ok;
}

// --- Superblocks and headers ---

static void pack_sb(const vxfs_vol *v, uint8_t *p0) {
  memset(p0, 0, VXFS_BLKSZ);
  uint8_t *p = p0;
  const vxfs_sb *s = &v->sb;
  vxfs_put32(p, VXFS_MAGIC), vxfs_put32(p + 4, VXFS_VERSION);
  vxfs_put32(p + 8, VXFS_BLKSZ), vxfs_put32(p + 12, VXFS_BUFSPC);
  vxfs_put32(p + 16, s->narenas), vxfs_put32(p + 20, s->snapht);
  p += 24;
  vxfs_packbp(p, s->snaproot), p += VXFS_PTRSZ;
  vxfs_put64(p, s->commit), vxfs_put64(p + 8, s->nextgen), vxfs_put64(p + 16, s->nextqid);
  vxfs_put64(p + 24, s->nextdl), vxfs_put64(p + 32, s->flags), vxfs_put64(p + 40, s->freed);
  p += 56; // and a word to spare
  for (uint32_t i = 0; i < s->narenas; i++, p += 24) {
    const vxfs_arena *a = &v->fs.arenas[i];
    vxfs_put64(p, a->base), vxfs_put64(p + 8, a->size / VXFS_BLKSZ), vxfs_put64(p + 16, v->arenahash[i]);
  }
  vxfs_put64(p, vxfs_xxh64(p0, (size_t)(p - p0), 0));
}

// A superblock, if it is one: false if not.
static bool unpack_sb(const uint8_t *p0, vxfs_sb *s) {
  const uint8_t *p = p0;
  if (vxfs_get32(p) != VXFS_MAGIC || vxfs_get32(p + 4) != VXFS_VERSION || vxfs_get32(p + 8) != VXFS_BLKSZ ||
      vxfs_get32(p + 12) != VXFS_BUFSPC)
    return false;
  s->narenas = vxfs_get32(p + 16), s->snapht = vxfs_get32(p + 20);
  if (!s->narenas || s->narenas > VXFS_MAXARENAS || !s->snapht || s->snapht > VXFS_MAXHEIGHT) return false;
  p += 24;
  s->snaproot = vxfs_unpackbp(p), p += VXFS_PTRSZ;
  s->commit = vxfs_get64(p), s->nextgen = vxfs_get64(p + 8), s->nextqid = vxfs_get64(p + 16);
  s->nextdl = vxfs_get64(p + 24), s->flags = vxfs_get64(p + 32), s->freed = vxfs_get64(p + 40);
  p += 56 + (size_t)24 * s->narenas;
  return vxfs_get64(p) == vxfs_xxh64(p0, (size_t)(p - p0), 0);
}

static uint64_t arena_reserve(uint64_t size) {
  uint64_t r = size / 1024;
  if (r < 512ull * 1024) r = 512ull * 1024;
  if (r > 8ull * 1024 * 1024) r = 8ull * 1024 * 1024;
  if (r > size / 8) r = size / 8 / VXFS_BLKSZ * VXFS_BLKSZ;
  return r;
}

// --- The commit ---

// Makes everything changed so far durable at once (11 §6).
[[maybe_unused]] static vx_status vxfs_commit(vxfs_vol *v) {
  vxfs *fs = &v->fs;
  if (fs->err != VX_OK) return fs->err;
  // 1. What is written so far lands first.
  if (fs->dev.barrier(fs->dev.ctx) != VX_OK) {
    fs_fail(fs, VX_ERR_IO);
    return fs->err;
  }
  fs->use_reserve = true;
  sbatch *b = fs_alloc(fs, sizeof *b);
  bool ok = b != nullptr;
  if (ok) b->n = b->used = b->size = 0;
  // The branches' new snapshots, and their deadlists.
  for (uint32_t i = 0; ok && i < VXFS_MAXBRANCH; i++) {
    vxfs_branch *br = &v->br[i];
    if (br->open && (br->t.root.addr != br->at.root.addr || br->t.height != br->at.height))
      ok = branch_update(v, b, br);
  }
  ok = ok && snap_flush(v, b);
  fs->ndead = 0;
  // 2. What the commit frees: the snapshot tree's old blocks, dropped
  // deadlists, compressed logs' old chains, and the last commit's chain of
  // these; written as a chain of its own, which the superblock names.
  for (uint32_t i = 0; ok && i < fs->narenas; i++) { // long logs compressed, the old chains deferred
    vxfs_arena *a = &fs->arenas[i];
    if (a->nlog >= fs->compress_at && a->nlog >= 2 * a->lastlog) ok = vxfs_log_compress(fs, a);
    ok = ok && vxfs_log_retire(fs, a);
  }
  for (uint32_t i = 0; ok && i < v->nfreedchain; i++) ok = vxfs_defer(fs, v->freedchain[i]);
  v->nfreedchain = 0;
  uint64_t freed = 0;
  if (ok && fs->ndeferred) {
    freed = chain_write(v, fs->deferred, fs->ndeferred, &v->freedchain, &v->nfreedchain, &v->capfreedchain);
    ok = freed != 0;
  }
  ok = ok && vxfs_end_op(fs);
  // 3. Each arena's log, and its header; a barrier.
  for (uint32_t i = 0; ok && i < fs->narenas; i++) {
    vxfs_arena *a = &fs->arenas[i];
    vxfs_arena_hdr h;
    ok = vxfs_arena_seal(fs, a, &h);
    cache_forget(fs, a->base); // the last commit's
    vxfs_blk *hb = ok ? new_block_at(fs, a->base, VXFS_TARENA) : nullptr;
    ok = hb != nullptr;
    if (ok) {
      vxfs_pack_arena(hb->data, &h);
      ok = vxfs_write_block(fs, hb);
      v->arenahash[i] = hb->bp.hash;
    }
    v->hdr[i] = hb;
  }
  ok = ok && fs->dev.barrier(fs->dev.ctx) == VX_OK;
  // 4. The superblock; a barrier. This is the write that commits. The
  // backup follows with the footers: the two are never in flight together,
  // so a cut cannot tear both (one of them is always whole, the last
  // commit's or this one's).
  vxfs_sb was = v->sb;
  static uint8_t sbuf[VXFS_BLKSZ];
  uint64_t last = (fs->dev.size / VXFS_BLKSZ - 1) * VXFS_BLKSZ;
  if (ok) {
    v->sb.narenas = fs->narenas, v->sb.snapht = v->snap.height, v->sb.snaproot = v->snap.root;
    v->sb.commit++, v->sb.nextgen = v->nextgen, v->sb.nextqid = v->nextqid, v->sb.nextdl = v->nextdl;
    v->sb.freed = freed;
    pack_sb(v, sbuf);
    ok = fs->dev.write(fs->dev.ctx, 0, sbuf) == VX_OK && fs->dev.barrier(fs->dev.ctx) == VX_OK;
    fs->writes++;
    if (!ok) v->sb = was;
  }
  // 5. The backup superblock, and the footers: the headers' copies.
  if (ok) ok = fs->dev.write(fs->dev.ctx, last, sbuf) == VX_OK;
  fs->writes++;
  for (uint32_t i = 0; i < fs->narenas; i++) {
    vxfs_blk *hb = v->hdr[i];
    if (!hb) continue;
    vxfs_arena *a = &fs->arenas[i];
    if (ok) ok = fs->dev.write(fs->dev.ctx, a->base + VXFS_BLKSZ + a->size, hb->buf) == VX_OK;
    fs->writes++;
    vxfs_drop(fs, hb);
    v->hdr[i] = nullptr;
  }
  if (!ok) fs_fail(fs, VX_ERR_IO);
  // 7. What it freed is free; the trees go on in new generations.
  ok = ok && vxfs_free_deferred(fs);
  for (uint32_t i = 0; ok && i < VXFS_MAXBRANCH; i++)
    if (v->br[i].open) v->br[i].t.memgen = v->nextgen++;
  v->snap.memgen = v->nextgen++;
  fs->use_reserve = false;
  fs_release(fs, b, sizeof *b);
  if (ok) return VX_OK;
  return fs->err != VX_OK ? fs->err : VX_ERR_INVALID;
}

// --- Branches and snapshots ---

static vxfs_branch *branch_named(vxfs_vol *v, const char *name) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  for (uint32_t i = 0; i < VXFS_MAXBRANCH; i++)
    if (v->br[i].open && v->br[i].nname == n && memcmp(v->br[i].name, name, n) == 0) return &v->br[i];
  return nullptr;
}

// Loads branch `name`, as its label says now, into br.
static vx_status branch_load(vxfs_vol *v, const char *name, vxfs_branch *br) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  uint64_t gen;
  uint32_t flags;
  vx_status st = vxfs_label_get(v, name, &gen, &flags);
  if (st != VX_OK) return st;
  if (!(flags & VXFS_LMUT)) return VX_ERR_ACCESS; // a snapshot, not a branch
  vxfs_snap s;
  if ((st = snap_get(v, gen, &s)) != VX_OK)
    return st == VX_ERR_NOT_FOUND ? vol_bad(v) : st; // a label naming nothing
  *br = (vxfs_branch){.nname = n, .open = true, .at = s};
  memcpy(br->name, name, n);
  br->t = (vxfs_tree){.root = s.root, .height = s.height, .memgen = v->nextgen++, .base = s.base};
  return VX_OK;
}

// Branch `name`, open for changes: *out is valid until the volume closes.
[[maybe_unused]] static vx_status vxfs_branch_open(vxfs_vol *v, const char *name, vxfs_branch **out) {
  vxfs_branch *open = branch_named(v, name);
  if (open) {
    *out = open;
    return VX_OK;
  }
  vxfs_branch *br = nullptr;
  for (uint32_t i = 0; i < VXFS_MAXBRANCH && !br; i++)
    if (!v->br[i].open) br = &v->br[i];
  if (!br) return VX_ERR_NO_MEMORY; // VXFS_MAXBRANCH open already
  vx_status st = branch_load(v, name, br);
  if (st != VX_OK) {
    *br = (vxfs_branch){};
    return st;
  }
  *out = br;
  return VX_OK;
}

// The tree a label names, as of the last commit, to read.
[[maybe_unused]] static vx_status vxfs_snap_open(vxfs_vol *v, const char *name, vxfs_tree *t) {
  uint64_t gen;
  uint32_t flags;
  vx_status st = vxfs_label_get(v, name, &gen, &flags);
  vxfs_snap s;
  if (st == VX_OK) st = snap_get(v, gen, &s);
  if (st != VX_OK) return st;
  *t = (vxfs_tree){.root = s.root, .height = s.height, .base = s.base};
  return VX_OK;
}

// A data block for tree t, held: born in t's generation.
[[maybe_unused]] static vxfs_blk *vxfs_new_data(vxfs *fs, const vxfs_tree *t) {
  tree_enter(fs, t);
  return vxfs_new_block(fs, VXFS_TDAT);
}

// --- Labels, forks and deleting snapshots ---

// The blocks of a tree born after `keep`, deferred: what a deleted snapshot
// alone held, when nothing follows it (what was born by `keep` is still its
// predecessor's, or its base's). A node is never older than what it points
// at, so a subtree born by `keep` is skipped whole.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree is tall
static bool sweep(vxfs_vol *v, vxfs_bptr bp, uint32_t level, uint64_t keep) {
  if (bp.gen <= keep) return true;
  vxfs *fs = &v->fs;
  vxfs_blk *b = vxfs_get(fs, bp, level == 1 ? VXFS_TLEAF : VXFS_TPIVOT);
  if (!b) return false;
  bool ok = vxfs_defer(fs, bp.addr);
  if (level == 1) {
    for (uint32_t i = 0; ok && i < b->nval; i++) {
      vxfs_msg e = tab_get(b->data, i, false);
      vxfs_bptr d = owns_block(&e) ? vxfs_unpackbp(e.v + 1) : (vxfs_bptr){};
      if (d.addr && d.gen > keep) ok = vxfs_defer(fs, d.addr);
    }
  } else {
    for (uint32_t i = 0; ok && i < b->nbuf; i++) {
      vxfs_msg m = tab_get(b->data + VXFS_PIVSPC, i, true);
      vxfs_bptr d = m.op == VXFS_OINSERT && owns_block(&m) ? vxfs_unpackbp(m.v + 1) : (vxfs_bptr){};
      if (d.addr && d.gen > keep) ok = vxfs_defer(fs, d.addr);
    }
    for (uint32_t i = 0; ok && i < b->nval; i++)
      ok = sweep(v, vxfs_unpackbp(tab_get(b->data, i, false).v), level - 1, keep);
  }
  vxfs_drop(fs, b);
  return ok;
}

// Deletes snapshot gen, which nothing names: its neighbours linked past it,
// its deadlists merged or dropped, and, at the end of its chain, its tree
// swept. A fork's whole chain gone, its base loses a fork, and is deleted
// in turn if nothing else holds it.
static bool snap_delete(vxfs_vol *v, sbatch *b, uint64_t gen) {
  while (gen) {
    vxfs_snap t, n;
    if (!snap_flush(v, b) || snap_get(v, gen, &t) != VX_OK) return false;
    bool ok = true;
    if (t.pred) {
      ok = snap_get(v, t.pred, &n) == VX_OK;
      n.succ = t.succ;
      ok = ok && snap_set(v, b, &n);
    }
    if (ok && t.succ) {
      ok = snap_get(v, t.succ, &n) == VX_OK;
      n.pred = t.pred;
      ok = ok && snap_set(v, b, &n);
    }
    uint8_t k[9];
    ok = ok && snap_msg(v, b, VXFS_ODELETE, k, key_snap(k, t.gen), nullptr, 0) && snap_flush(v, b);
    ok = ok && reclaim(v, b, t.gen, t.succ, t.pred);
    if (ok && !t.succ) ok = sweep(v, t.root, t.height, t.pred ? t.pred : t.base);
    gen = 0;
    if (ok && !t.pred && !t.succ && t.base) {
      ok = snap_flush(v, b) && snap_get(v, t.base, &n) == VX_OK && n.nref;
      if (ok) n.nref--;
      ok = ok && snap_set(v, b, &n);
      if (ok && !n.nlbl && !n.nref) gen = n.gen;
    }
    if (!ok) return v->fs.err == VX_OK ? fs_fail(&v->fs, VX_ERR_INVALID) : false;
  }
  return snap_flush(v, b);
}

// A snapshot of `s`, forked as a branch's first: sharing its tree, based on it.
static bool fork_of(vxfs_vol *v, sbatch *b, vxfs_snap *s, const char *name, uint16_t n) {
  vxfs_snap f = {.root = s->root,
                 .height = s->height,
                 .flags = s->flags,
                 .gen = v->nextgen++,
                 .base = s->gen,
                 .nlbl = 1};
  s->nref++;
  return snap_set(v, b, s) && snap_set(v, b, &f) &&
         label_set(v, b, (const uint8_t *)name, n, f.gen, VXFS_LMUT);
}

static sbatch *batch_new(vxfs_vol *v) {
  sbatch *b = fs_alloc(&v->fs, sizeof *b);
  if (b) b->n = b->used = b->size = 0;
  return b;
}

static vx_status vol_status(vxfs_vol *v, bool ok) {
  if (ok) return VX_OK;
  return v->fs.err != VX_OK ? v->fs.err : VX_ERR_INVALID;
}

// Labels the snapshot `from` names (as of the last commit) `name`: a
// snapshot that stays, or, with VXFS_LMUT, a new branch forked from it.
// Durable at the next commit.
[[maybe_unused]] static vx_status vxfs_label(vxfs_vol *v, const char *from, const char *name,
                                             uint32_t flags) {
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  if (!n || n > VXFS_LABELMAX) return VX_ERR_INVALID;
  uint64_t gen, g;
  uint32_t f;
  vx_status st = vxfs_label_get(v, from, &gen, &f);
  if (st != VX_OK) return st;
  if ((st = vxfs_label_get(v, name, &g, &f)) != VX_ERR_NOT_FOUND) return st == VX_OK ? VX_ERR_EXISTS : st;
  vxfs_snap s;
  if ((st = snap_get(v, gen, &s)) != VX_OK) return st;
  sbatch *b = batch_new(v);
  bool ok = b != nullptr;
  if (ok && (flags & VXFS_LMUT)) {
    ok = fork_of(v, b, &s, name, n);
  } else if (ok) {
    s.nlbl++;
    ok = snap_set(v, b, &s) && label_set(v, b, (const uint8_t *)name, n, s.gen, 0);
  }
  ok = ok && snap_flush(v, b);
  fs_release(&v->fs, b, sizeof *b);
  return vol_status(v, ok);
}

// Removes a label. The snapshot it named is deleted if nothing else names
// it or was forked from it. A branch must not be open.
[[maybe_unused]] static vx_status vxfs_unlabel(vxfs_vol *v, const char *name) {
  uint64_t gen;
  uint32_t flags;
  vx_status st = vxfs_label_get(v, name, &gen, &flags);
  if (st != VX_OK) return st;
  if (branch_named(v, name)) return VX_ERR_BAD_STATE;
  vxfs_snap s;
  if ((st = snap_get(v, gen, &s)) != VX_OK) return st;
  sbatch *b = batch_new(v);
  bool ok = b != nullptr;
  uint8_t k[VXFS_KEYMAX];
  uint16_t n = vxfs_namelen(name, VXFS_LABELMAX);
  ok = ok && snap_msg(v, b, VXFS_ODELETE, k, key_label(k, (const uint8_t *)name, n), nullptr, 0);
  if (ok && s.nlbl) s.nlbl--;
  ok = ok && snap_set(v, b, &s);
  if (ok && !s.nlbl && !s.nref) ok = snap_delete(v, b, s.gen);
  ok = ok && snap_flush(v, b);
  fs_release(&v->fs, b, sizeof *b);
  return vol_status(v, ok);
}

// Rolls branch `name` back to the snapshot `to` names: the branch becomes
// a fork of it (11 §5), and the snapshot it was at is deleted if nothing
// else names it. The branch must not be open.
[[maybe_unused]] static vx_status vxfs_rollback(vxfs_vol *v, const char *name, const char *to) {
  uint64_t gen, target;
  uint32_t flags, f;
  vx_status st = vxfs_label_get(v, name, &gen, &flags);
  if (st == VX_OK) st = vxfs_label_get(v, to, &target, &f);
  if (st != VX_OK) return st;
  if (!(flags & VXFS_LMUT)) return VX_ERR_ACCESS;
  if (branch_named(v, name)) return VX_ERR_BAD_STATE;
  vxfs_snap t, o;
  if ((st = snap_get(v, target, &t)) != VX_OK) return st;
  sbatch *b = batch_new(v);
  bool ok = b != nullptr && fork_of(v, b, &t, name, vxfs_namelen(name, VXFS_LABELMAX)) && snap_flush(v, b) &&
            snap_get(v, gen, &o) == VX_OK;
  if (ok && o.nlbl) o.nlbl--;
  ok = ok && snap_set(v, b, &o);
  if (ok && !o.nlbl && !o.nref) ok = snap_delete(v, b, o.gen);
  ok = ok && snap_flush(v, b);
  fs_release(&v->fs, b, sizeof *b);
  return vol_status(v, ok);
}

// Rolls an open branch back to the snapshot `to` names (vxfs_rollback),
// in place: br stays the branch, at its new state. Nothing in it may be
// uncommitted.
[[maybe_unused]] static vx_status vxfs_branch_rollback(vxfs_vol *v, vxfs_branch *br, const char *to) {
  if (br->t.root.addr != br->at.root.addr || br->t.height != br->at.height) return VX_ERR_BAD_STATE;
  char name[VXFS_LABELMAX + 1];
  memcpy(name, br->name, br->nname);
  name[br->nname] = 0;
  br->open = false;
  vx_status st = vxfs_rollback(v, name, to);
  vx_status again = branch_load(v, name, br); // as it is now, rolled back or not
  return st != VX_OK ? st : again;
}

// Closes a branch with nothing uncommitted.
[[maybe_unused]] static vx_status vxfs_branch_close(vxfs_branch *br) {
  if (br->t.root.addr != br->at.root.addr || br->t.height != br->at.height) return VX_ERR_BAD_STATE;
  br->open = false;
  return VX_OK;
}

// --- Making and mounting volumes ---

static bool vol_alloc(vxfs_vol *v, uint32_t narenas) {
  vxfs *fs = &v->fs;
  v->arenahash = fs_alloc(fs, narenas * sizeof *v->arenahash);
  v->hdr = fs_alloc(fs, narenas * sizeof *v->hdr);
  if (!v->arenahash || !v->hdr || !vxfs_arenas(fs, narenas)) return false;
  memset(v->arenahash, 0, narenas * sizeof *v->arenahash);
  memset(v->hdr, 0, narenas * sizeof *v->hdr);
  return true;
}

// A new volume over the whole device, with `narenas` arenas (0: as its
// size suggests) and an empty branch for each name, committed; left mounted.
[[maybe_unused]] static vx_status vxfs_format(vxfs_vol *v, vxfs_dev dev, vxfs_mem mem, uint32_t cache,
                                              uint32_t narenas, const char *const *branches,
                                              uint32_t nbranches) {
  *v = (vxfs_vol){};
  vxfs *fs = &v->fs;
  uint64_t blocks = dev.size / VXFS_BLKSZ;
  if (!narenas) narenas = (uint32_t)(dev.size / (4ull << 30)) + 1;
  if (narenas > 64) narenas = 64;
  while (narenas > 1 && (blocks - 2) / narenas < 64) narenas--;
  if (blocks < 2 + 8 || (blocks - 2) / narenas < 8) return VX_ERR_INVALID; // too small to hold anything
  if (!vxfs_open(fs, dev, mem, cache) || !vol_alloc(v, narenas)) return fs->err;
  uint64_t per = (blocks - 2) / narenas;
  for (uint32_t i = 0; i < narenas; i++) {
    vxfs_arena *a = &fs->arenas[i];
    if (!vxfs_arena_init(fs, a, (1 + i * per) * VXFS_BLKSZ, per - 2)) return fs->err;
    a->reserve = arena_reserve(a->size);
  }
  v->nextgen = 1, v->nextqid = 1, v->nextdl = 1;
  v->snap = (vxfs_tree){.memgen = v->nextgen++, .snap = true};
  if (!vxfs_tree_init(fs, &v->snap)) return fs->err;
  sbatch *b = fs_alloc(fs, sizeof *b);
  bool ok = b != nullptr;
  if (ok) b->n = b->used = b->size = 0;
  for (uint32_t i = 0; ok && i < nbranches; i++) {
    uint16_t n = vxfs_namelen(branches[i], VXFS_LABELMAX);
    vxfs_tree t = {.memgen = v->nextgen++};
    ok = n && n <= VXFS_LABELMAX && vxfs_tree_init(fs, &t) && vxfs_end_op(fs);
    vxfs_snap s = {.root = t.root, .height = 1, .gen = t.memgen, .nlbl = 1};
    ok = ok && snap_set(v, b, &s) && label_set(v, b, (const uint8_t *)branches[i], n, s.gen, VXFS_LMUT);
  }
  ok = ok && snap_flush(v, b);
  fs_release(fs, b, sizeof *b);
  if (!ok) return fs->err != VX_OK ? fs->err : VX_ERR_INVALID;
  return vxfs_commit(v);
}

// The arena a superblock's table describes: its header, or its footer if
// the header does not match (a commit torn while writing headers).
static bool mount_arena(vxfs_vol *v, uint32_t i, const uint8_t *ent) {
  vxfs *fs = &v->fs;
  uint64_t base = vxfs_get64(ent), blocks = vxfs_get64(ent + 8), hash = vxfs_get64(ent + 16);
  if (base % VXFS_BLKSZ || blocks > fs->dev.size / VXFS_BLKSZ || base > fs->dev.size ||
      (blocks + 2) * VXFS_BLKSZ > fs->dev.size - base)
    return fs_fail(fs, VX_ERR_INVALID);
  vxfs_blk *hb = nullptr;
  for (int copy = 0; copy < 2 && !hb; copy++) {
    uint64_t at = copy == 0 ? base : base + VXFS_BLKSZ + blocks * VXFS_BLKSZ;
    vx_status was = fs->err;
    hb = vxfs_get(fs, (vxfs_bptr){.addr = at, .hash = hash}, VXFS_TARENA);
    if (!hb && was == VX_OK) fs->err = VX_OK; // the other copy, then
  }
  if (!hb) return fs_fail(fs, VX_ERR_INVALID);
  vxfs_arena_hdr h = vxfs_unpack_arena(hb->data);
  vxfs_drop(fs, hb);
  cache_forget(fs, base), cache_forget(fs, base + VXFS_BLKSZ + blocks * VXFS_BLKSZ);
  if (h.base != base || h.blocks != blocks) return fs_fail(fs, VX_ERR_INVALID);
  v->arenahash[i] = hash;
  vxfs_arena *a = &fs->arenas[i];
  if (!vxfs_arena_load(fs, a, &h)) return false;
  a->reserve = arena_reserve(a->size);
  return true;
}

// Mounts the volume on the device: the newer of its two good superblocks,
// its arenas, and the frees of the commit it describes done again.
[[maybe_unused]] static vx_status vxfs_mount(vxfs_vol *v, vxfs_dev dev, vxfs_mem mem, uint32_t cache) {
  *v = (vxfs_vol){};
  vxfs *fs = &v->fs;
  if (dev.size < 10ull * VXFS_BLKSZ) return VX_ERR_INVALID;
  if (!vxfs_open(fs, dev, mem, cache)) return fs->err;
  static uint8_t sbuf[2][VXFS_BLKSZ];
  vxfs_sb sb[2];
  bool good[2];
  uint64_t at[2] = {0, (dev.size / VXFS_BLKSZ - 1) * VXFS_BLKSZ};
  for (int i = 0; i < 2; i++) {
    good[i] = dev.read(dev.ctx, at[i], sbuf[i]) == VX_OK && unpack_sb(sbuf[i], &sb[i]);
    fs->reads++;
  }
  if (!good[0] && !good[1]) return vol_bad(v);
  int use = !good[0] || (good[1] && sb[1].commit > sb[0].commit) ? 1 : 0;
  v->sb = sb[use];
  if (!vol_alloc(v, v->sb.narenas)) return fs->err;
  for (uint32_t i = 0; i < v->sb.narenas; i++)
    if (!mount_arena(v, i, sbuf[use] + VXFS_SBHDSZ + (size_t)24 * i)) return fs->err;
  v->nextgen = v->sb.nextgen, v->nextqid = v->sb.nextqid, v->nextdl = v->sb.nextdl;
  v->snap = (vxfs_tree){.root = v->sb.snaproot, .height = v->sb.snapht, .memgen = v->nextgen++, .snap = true};
  // What the commit freed: free now (those frees, logged after it, were not
  // replayed); its chain, which the superblock names, at the next commit.
  if (v->sb.freed && (!chain_each(v, v->sb.freed, free_one, nullptr, true, false) ||
                      !chain_each(v, v->sb.freed, defer_one, nullptr, false, true)))
    return fs->err != VX_OK ? fs->err : VX_ERR_INVALID;
  if (v->sb.freed) { // deferred: kept as the chain to free at the next commit
    for (uint32_t i = 0; i < fs->ndeferred; i++) {
      if (!fs_grow(fs, (void **)&v->freedchain, v->nfreedchain, &v->capfreedchain, sizeof *v->freedchain))
        return fs->err;
      v->freedchain[v->nfreedchain++] = fs->deferred[i];
    }
    fs->ndeferred = 0;
  }
  return VX_OK;
}

[[maybe_unused]] static void vxfs_unmount(vxfs_vol *v) {
  vxfs *fs = &v->fs;
  if (fs->arenas)
    for (uint32_t i = 0; i < fs->narenas; i++)
      if (fs->arenas[i].logtl) vxfs_drop(fs, fs->arenas[i].logtl);
  fs_release(fs, v->arenahash, fs->narenas * sizeof *v->arenahash);
  fs_release(fs, v->hdr, fs->narenas * sizeof *v->hdr);
  fs_release(fs, v->freedchain, v->capfreedchain * sizeof *v->freedchain);
  vxfs_close(fs);
  *v = (vxfs_vol){};
}
