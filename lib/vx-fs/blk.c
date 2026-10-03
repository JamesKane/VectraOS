// vx-fs blocks (docs/11 §3, §6): the block cache, reading and checking
// blocks, arenas and their allocation logs, after gefs's blk.c.
//
// Every block but the logs is reached through a block pointer whose hash is
// that of the block's whole contents: a read that does not match is
// INVALID, and the volume is read-only from then on. A block's structure is
// checked too (every offset and length inside the block, keys in order),
// so a damaged or hostile disk makes errors, never faults.
//
// Space comes from arenas. Each keeps its free space as sorted ranges in
// memory, and an append-only log of allocations and frees on the disk,
// replayed at load: the log is the one structure written in place, so it
// carries a hash of its own. Freeing has two cases. A block born in the
// generation being built (since the last commit) is freed when the current
// operation ends, the epoch gefs's readers need (single-threaded here); one
// born earlier may still be reachable from the last commit, so it is killed:
// kept on fs->dead, for the commit's deadlists (step 3).

#pragma once

#include "fs.h"
#include "xxh64.c"

enum : uint8_t { VXFS_BDIRTY = 1, VXFS_BCACHED = 2, VXFS_BLRU = 4 };
static constexpr uint16_t VXFS_TTREE = 0xfffe; // to vxfs_get: a pivot or a leaf, whichever it is

typedef struct vxfs_blk {
  struct vxfs_blk *hnext;         // the cache's hash chain
  struct vxfs_blk *lprev, *lnext; // the LRU list, while unreferenced
  uint16_t type;
  uint16_t nval, valsz, nbuf, bufsz; // tree blocks
  uint16_t logsz;                    // logs
  vxfs_bptr logp;                    // logs: the next block in the chain
  vxfs_bptr bp;
  uint32_t ref;
  uint8_t flags;
  uint8_t *data; // into buf, past the header
  alignas(64) uint8_t buf[VXFS_BLKSZ];
} vxfs_blk;

typedef struct vxfs_range {
  uint64_t off, len;
} vxfs_range;

// An arena: a header block at base, its data blocks after it, and a footer
// after them (step 3 writes those two).
typedef struct vxfs_arena {
  uint64_t base, size; // bytes of data blocks, from base + VXFS_BLKSZ
  uint64_t used, reserve;
  vxfs_range *free; // sorted, disjoint, never adjacent
  uint32_t nfree, capfree;
  vxfs_bptr loghd;   // the log's first block
  vxfs_blk *logtl;   // its last, held, open for appending
  uint64_t nlog;     // its blocks
  uint64_t *retired; // a compressed log's old chain, not yet reusable
  uint64_t nretired;
} vxfs_arena;

typedef struct vxfs {
  vxfs_dev dev;
  vxfs_mem mem;
  vx_status err; // sticky: the first error, after which nothing more is written

  vxfs_blk *blocks;
  uint32_t nblocks;
  vxfs_blk **hash;
  uint32_t nhash;              // a power of two
  vxfs_blk *lru_old, *lru_new; // the unreferenced blocks, least recently used first

  vxfs_arena *arenas;
  uint32_t narenas;
  uint32_t rr, rr_writes; // the round robin over arenas (11 §6)

  uint64_t gen; // the generation blocks are born in now
  vxfs_bptr *limbo, *dead;
  uint32_t nlimbo, caplimbo, ndead, capdead;

  uint64_t reads, writes; // blocks, for tests and status
} vxfs;

static constexpr uint64_t VXFS_LOG_SYNC_SHIFT = 8;
enum : uint8_t { LOG_NOP, LOG_ALLOC1, LOG_FREE1, LOG_SYNC, LOG_ALLOC, LOG_FREE };

static bool fs_fail(vxfs *fs, vx_status st) {
  if (fs->err == VX_OK) fs->err = st;
  return false;
}

static void *fs_alloc(vxfs *fs, size_t n) {
  void *p = fs->mem.alloc ? fs->mem.alloc(fs->mem.ctx, n) : nullptr;
  if (!p) fs_fail(fs, VX_ERR_NO_MEMORY);
  return p;
}

static void fs_release(vxfs *fs, void *p, size_t n) {
  if (p && fs->mem.free) fs->mem.free(fs->mem.ctx, p, n);
}

// Grows an array of `size`-byte items to hold one more; false if it cannot.
static bool fs_grow(vxfs *fs, void **arr, uint32_t n, uint32_t *cap, size_t size) {
  if (n < *cap) return true;
  uint32_t ncap = *cap ? *cap * 2 : 16;
  void *more = fs_alloc(fs, (size_t)ncap * size);
  if (!more) return false;
  if (*arr) {
    memcpy(more, *arr, (size_t)n * size);
    fs_release(fs, *arr, (size_t)*cap * size);
  }
  *arr = more;
  *cap = ncap;
  return true;
}

// --- The cache ---

static uint32_t cache_slot(const vxfs *fs, uint64_t addr) {
  return (uint32_t)((addr / VXFS_BLKSZ * 0x9E3779B97F4A7C15ull) >> 32) & (fs->nhash - 1);
}

static void lru_unlink(vxfs *fs, vxfs_blk *b) {
  if (!(b->flags & VXFS_BLRU)) return;
  *(b->lprev ? &b->lprev->lnext : &fs->lru_old) = b->lnext;
  *(b->lnext ? &b->lnext->lprev : &fs->lru_new) = b->lprev;
  b->lprev = b->lnext = nullptr;
  b->flags &= (uint8_t)~VXFS_BLRU;
}

static void lru_push(vxfs *fs, vxfs_blk *b) { // the most recently used end
  b->lprev = fs->lru_new;
  b->lnext = nullptr;
  *(fs->lru_new ? &fs->lru_new->lnext : &fs->lru_old) = b;
  fs->lru_new = b;
  b->flags |= VXFS_BLRU;
}

static vxfs_blk *cache_find(vxfs *fs, uint64_t addr) {
  for (vxfs_blk *b = fs->hash[cache_slot(fs, addr)]; b; b = b->hnext)
    if (b->bp.addr == addr) return b;
  return nullptr;
}

static void cache_del(vxfs *fs, vxfs_blk *b) {
  if (!(b->flags & VXFS_BCACHED)) return;
  for (vxfs_blk **link = &fs->hash[cache_slot(fs, b->bp.addr)]; *link; link = &(*link)->hnext)
    if (*link == b) {
      *link = b->hnext;
      break;
    }
  b->hnext = nullptr;
  b->flags &= (uint8_t)~VXFS_BCACHED;
}

static void cache_put(vxfs *fs, vxfs_blk *b) {
  uint32_t s = cache_slot(fs, b->bp.addr);
  b->hnext = fs->hash[s];
  fs->hash[s] = b;
  b->flags |= VXFS_BCACHED;
}

// A block of the cache's for a new use, held: the least recently used one
// that nothing holds and that has been written (a dirty block is not
// evicted, whoever dropped it). nullptr (NO_MEMORY) if there is none.
static vxfs_blk *cache_take(vxfs *fs) {
  vxfs_blk *b = fs->lru_old;
  while (b && (b->flags & VXFS_BDIRTY)) b = b->lnext;
  if (!b) {
    fs_fail(fs, VX_ERR_NO_MEMORY);
    return nullptr;
  }
  lru_unlink(fs, b);
  cache_del(fs, b);
  b->ref = 1;
  b->flags = 0;
  return b;
}

[[maybe_unused]] static vxfs_blk *vxfs_hold(vxfs *fs, vxfs_blk *b) {
  if (!b->ref++) lru_unlink(fs, b);
  return b;
}

[[maybe_unused]] static void vxfs_drop(vxfs *fs, vxfs_blk *b) {
  if (b && !--b->ref) lru_push(fs, b);
}

// Drops a block from the cache altogether (its address freed for reuse).
static void cache_forget(vxfs *fs, uint64_t addr) {
  vxfs_blk *b = cache_find(fs, addr);
  if (b) cache_del(fs, b);
}

// --- Checking a block read from the disk ---

// The entries of a table at d[0, spc): n offsets of 2 bytes, each to an
// entry inside [2n, spc): an op (if `msgs`), a key and a value, whose sizes
// add up to `size`. Keys in order: strictly for values, and messages may
// repeat a key. A pivot's values are each a block pointer and a fill.
static bool check_table(const uint8_t *d, uint32_t spc, uint16_t n, uint16_t size, bool msgs, bool pivot) {
  uint32_t lo = 2u * n, total = 0;
  if (lo + size > spc) return false;
  const uint8_t *pk = nullptr;
  uint16_t pnk = 0;
  for (uint16_t i = 0; i < n; i++) {
    uint32_t o = vxfs_get16(d + (size_t)2 * i), at = o;
    if (o < lo || o >= spc) return false;
    uint8_t op = 0;
    if (msgs) {
      op = d[at++];
      if (op == VXFS_ONOP || op >= VXFS_NMSG) return false;
    }
    if (at + 2 > spc) return false;
    uint16_t nk = vxfs_get16(d + at);
    at += 2;
    if (!nk || nk > VXFS_KEYMAX || at + nk + 2 > spc) return false;
    const uint8_t *k = d + at;
    at += nk;
    uint16_t nv = vxfs_get16(d + at);
    at += 2;
    if (nv > VXFS_INLMAX || at + nv > spc) return false;
    if (pivot && !msgs && nv != VXFS_PTRSZ + 2) return false;
    int c = pk ? vxfs_keycmp(pk, pnk, k, nk) : -1;
    if (c > 0 || (c == 0 && !msgs)) return false; // values strictly in order; messages may repeat a key
    pk = k, pnk = nk;
    total += (msgs ? 1u : 0u) + 2 + nk + 2 + nv;
  }
  return total == size;
}

// Reads the header the block's type has, and checks what it says. False if
// the block is not one of type `want` or is malformed.
static bool parse_block(vxfs_blk *b, uint16_t want) {
  const uint8_t *p = b->buf;
  b->nval = b->valsz = b->nbuf = b->bufsz = b->logsz = 0;
  b->logp = (vxfs_bptr){};
  if (want == VXFS_TDAT) {
    b->type = VXFS_TDAT;
    b->data = b->buf;
    return true;
  }
  b->type = vxfs_get16(p);
  if (b->type != want && !(want == VXFS_TTREE && (b->type == VXFS_TPIVOT || b->type == VXFS_TLEAF)))
    return false;
  switch (b->type) {
  case VXFS_TPIVOT:
    b->nval = vxfs_get16(p + 2), b->valsz = vxfs_get16(p + 4);
    b->nbuf = vxfs_get16(p + 6), b->bufsz = vxfs_get16(p + 8);
    b->data = b->buf + VXFS_PIVHDSZ;
    return b->nval >= 1 && check_table(b->data, VXFS_PIVSPC, b->nval, b->valsz, false, true) &&
           check_table(b->data + VXFS_PIVSPC, VXFS_BUFSPC, b->nbuf, b->bufsz, true, true);
  case VXFS_TLEAF:
    b->nval = vxfs_get16(p + 2), b->valsz = vxfs_get16(p + 4);
    b->data = b->buf + VXFS_LEAFHDSZ;
    return check_table(b->data, VXFS_LEAFSPC, b->nval, b->valsz, false, false);
  case VXFS_TLOG:
  case VXFS_TDLIST:
    b->logsz = vxfs_get16(p + 2);
    b->logp = vxfs_unpackbp(p + 12);
    b->data = b->buf + VXFS_LOGHDSZ;
    return b->logsz <= VXFS_LOGSPC && b->logsz % 8 == 0 &&
           vxfs_get64(p + 4) == vxfs_xxh64(b->data, b->logsz, 0);
  default: return false;
  }
}

// The block bp points at, of type `type`, held. Its hash is checked unless
// it is a log (whose pointers carry none: it is written in place).
[[maybe_unused]] static vxfs_blk *vxfs_get(vxfs *fs, vxfs_bptr bp, uint16_t type) {
  if (bp.addr % VXFS_BLKSZ || bp.addr >= fs->dev.size || fs->dev.size - bp.addr < VXFS_BLKSZ) {
    fs_fail(fs, VX_ERR_INVALID);
    return nullptr;
  }
  vxfs_blk *b = cache_find(fs, bp.addr);
  if (b) {
    bool kind = b->type == type || (type == VXFS_TTREE && (b->type == VXFS_TPIVOT || b->type == VXFS_TLEAF));
    if (!kind || (type != VXFS_TLOG && b->bp.hash != bp.hash)) {
      fs_fail(fs, VX_ERR_INVALID);
      return nullptr;
    }
    return vxfs_hold(fs, b);
  }
  if (!(b = cache_take(fs))) return nullptr;
  fs->reads++;
  vx_status st = fs->dev.read(fs->dev.ctx, bp.addr, b->buf);
  bool ok = st == VX_OK &&
            (type == VXFS_TLOG || type == VXFS_TDLIST || vxfs_xxh64(b->buf, VXFS_BLKSZ, 0) == bp.hash);
  if (ok) ok = parse_block(b, type);
  if (!ok) {
    fs_fail(fs, st != VX_OK ? st : VX_ERR_INVALID);
    b->ref = 0;
    lru_push(fs, b);
    return nullptr;
  }
  b->bp = bp;
  cache_put(fs, b);
  return b;
}

// A new block of `type` at addr, held, empty.
static vxfs_blk *new_block_at(vxfs *fs, uint64_t addr, uint16_t type) {
  vxfs_blk *b = cache_take(fs);
  if (!b) return nullptr;
  b->type = type;
  b->bp = (vxfs_bptr){.addr = addr, .gen = fs->gen};
  b->nval = b->valsz = b->nbuf = b->bufsz = b->logsz = 0;
  b->logp = (vxfs_bptr){};
  switch (type) {
  case VXFS_TPIVOT: b->data = b->buf + VXFS_PIVHDSZ; break;
  case VXFS_TLEAF: b->data = b->buf + VXFS_LEAFHDSZ; break;
  case VXFS_TLOG:
  case VXFS_TDLIST: b->data = b->buf + VXFS_LOGHDSZ; break;
  default: b->data = b->buf; break;
  }
  memset(b->buf, 0, sizeof b->buf);
  b->flags |= VXFS_BDIRTY;
  cache_put(fs, b);
  return b;
}

// Writes the header and the hash: the block is final, and its pointer whole.
static void finalize(vxfs_blk *b) {
  uint8_t *p = b->buf;
  if (b->type != VXFS_TDAT) vxfs_put16(p, b->type);
  switch (b->type) {
  case VXFS_TPIVOT:
    vxfs_put16(p + 2, b->nval), vxfs_put16(p + 4, b->valsz);
    vxfs_put16(p + 6, b->nbuf), vxfs_put16(p + 8, b->bufsz);
    break;
  case VXFS_TLEAF: vxfs_put16(p + 2, b->nval), vxfs_put16(p + 4, b->valsz); break;
  case VXFS_TLOG:
  case VXFS_TDLIST:
    vxfs_put16(p + 2, b->logsz);
    vxfs_put64(p + 4, vxfs_xxh64(b->data, b->logsz, 0));
    vxfs_packbp(p + 12, b->logp);
    break;
  default: break;
  }
  b->bp.hash = vxfs_xxh64(b->buf, VXFS_BLKSZ, 0);
}

// Finalizes the block and writes it. A tree or data block is never changed
// after this; a log's last block is, and is written again.
[[maybe_unused]] static bool vxfs_write_block(vxfs *fs, vxfs_blk *b) {
  if (fs->err != VX_OK) return false;
  finalize(b);
  fs->writes++;
  vx_status st = fs->dev.write(fs->dev.ctx, b->bp.addr, b->buf);
  if (st != VX_OK) return fs_fail(fs, st);
  b->flags &= (uint8_t)~VXFS_BDIRTY;
  if (++fs->rr_writes == 4096) fs->rr++, fs->rr_writes = 0; // every few thousand writes, the next arena
  return true;
}

// --- Free space: sorted ranges ---

// The index of the range holding off, or of the first after it.
static uint32_t range_at(const vxfs_arena *a, uint64_t off) {
  uint32_t lo = 0, hi = a->nfree;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (a->free[mid].off + a->free[mid].len <= off)
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo;
}

static bool range_has(const vxfs_arena *a, uint64_t addr) {
  uint32_t i = range_at(a, addr);
  return i < a->nfree && a->free[i].off <= addr;
}

// [off, off + len) becomes free. False (INVALID) if any of it already was.
static bool range_free(vxfs *fs, vxfs_arena *a, uint64_t off, uint64_t len) {
  uint32_t i = range_at(a, off);
  if (i < a->nfree && a->free[i].off < off + len) return fs_fail(fs, VX_ERR_INVALID); // freed twice
  bool before = i > 0 && a->free[i - 1].off + a->free[i - 1].len == off;
  bool after = i < a->nfree && a->free[i].off == off + len;
  if (before && after) {
    a->free[i - 1].len += len + a->free[i].len;
    memmove(&a->free[i], &a->free[i + 1], (a->nfree - i - 1) * sizeof a->free[0]);
    a->nfree--;
  } else if (before) {
    a->free[i - 1].len += len;
  } else if (after) {
    a->free[i].off = off, a->free[i].len += len;
  } else {
    if (!fs_grow(fs, (void **)&a->free, a->nfree, &a->capfree, sizeof a->free[0])) return false;
    memmove(&a->free[i + 1], &a->free[i], (a->nfree - i) * sizeof a->free[0]);
    a->free[i] = (vxfs_range){off, len};
    a->nfree++;
  }
  return true;
}

// [off, off + len) is taken. False (INVALID) if it was not all free.
static bool range_grab(vxfs *fs, vxfs_arena *a, uint64_t off, uint64_t len) {
  uint32_t i = range_at(a, off);
  if (i == a->nfree || a->free[i].off > off || off + len > a->free[i].off + a->free[i].len)
    return fs_fail(fs, VX_ERR_INVALID);
  vxfs_range *r = &a->free[i];
  uint64_t end = r->off + r->len;
  if (off == r->off && len == r->len) {
    memmove(&a->free[i], &a->free[i + 1], (a->nfree - i - 1) * sizeof a->free[0]);
    a->nfree--;
  } else if (off == r->off) {
    r->off += len, r->len -= len;
  } else if (off + len == end) {
    r->len -= len;
  } else { // the middle: two pieces
    if (!fs_grow(fs, (void **)&a->free, a->nfree, &a->capfree, sizeof a->free[0])) return false;
    r = &a->free[i];
    memmove(&a->free[i + 2], &a->free[i + 1], (a->nfree - i - 1) * sizeof a->free[0]);
    a->free[i + 1] = (vxfs_range){off + len, end - off - len};
    r->len = off - r->off;
    a->nfree++;
  }
  return true;
}

// One block from the arena's free space, unlogged: from its start
// (sequential, for logs being rewritten) or its end. 0 if there is no room.
static uint64_t arena_take(vxfs *fs, vxfs_arena *a, bool seq) {
  if (!a->nfree || a->size - a->used <= a->reserve) return 0;
  vxfs_range *r = seq ? &a->free[0] : &a->free[a->nfree - 1];
  uint64_t b = seq ? r->off : r->off + r->len - VXFS_BLKSZ;
  range_grab(fs, a, b, VXFS_BLKSZ);
  a->used += VXFS_BLKSZ;
  return b;
}

// --- The allocation log ---

static vxfs_arena *arena_of(vxfs *fs, uint64_t addr) {
  for (uint32_t i = 0; i < fs->narenas; i++) {
    vxfs_arena *a = &fs->arenas[i];
    if (addr >= a->base + VXFS_BLKSZ && addr < a->base + VXFS_BLKSZ + a->size) return a;
  }
  return nullptr;
}

// Appends an entry: an allocation or free of [off, off + len), or a sync
// barrier for generation `off` (op LOG_SYNC). A full block chains to a new
// one, taken from the arena and logged in the old one first.
static bool log_append(vxfs *fs, vxfs_arena *a, uint64_t off, uint64_t len, uint8_t op) {
  vxfs_blk *lb = a->logtl;
  if (lb->logsz >= VXFS_LOGSPC - VXFS_LOGSLOP) {
    uint64_t o = arena_take(fs, a, false);
    if (!o) return fs_fail(fs, VX_ERR_NO_MEMORY);
    vxfs_put64(lb->data + lb->logsz, o | LOG_ALLOC1);
    lb->logsz += 8;
    lb->logp = (vxfs_bptr){.addr = o};
    vxfs_blk *next = new_block_at(fs, o, VXFS_TLOG);
    if (!next || !vxfs_write_block(fs, next) || !vxfs_write_block(fs, lb)) return false;
    vxfs_drop(fs, lb);
    a->logtl = lb = next;
    a->nlog++;
  }
  if (op == LOG_ALLOC && len == VXFS_BLKSZ) op = LOG_ALLOC1;
  if (op == LOG_FREE && len == VXFS_BLKSZ) op = LOG_FREE1;
  vxfs_put64(lb->data + lb->logsz, op == LOG_SYNC ? off << VXFS_LOG_SYNC_SHIFT | op : off | op);
  lb->logsz += 8;
  if (op == LOG_ALLOC || op == LOG_FREE) {
    vxfs_put64(lb->data + lb->logsz, len);
    lb->logsz += 8;
  }
  lb->flags |= VXFS_BDIRTY;
  return true;
}

// Writes the log's open block, if it has changed.
[[maybe_unused]] static bool vxfs_log_flush(vxfs *fs, vxfs_arena *a) {
  if (!(a->logtl->flags & VXFS_BDIRTY)) return true;
  return vxfs_write_block(fs, a->logtl);
}

[[maybe_unused]] static bool vxfs_log_barrier(vxfs *fs, vxfs_arena *a, uint64_t gen) {
  return log_append(fs, a, gen, 0, LOG_SYNC);
}

// A new arena over [base, base + VXFS_BLKSZ * (blocks + 2)): all of its data
// blocks free, but the first, its log, which says so.
[[maybe_unused]] static bool vxfs_arena_init(vxfs *fs, vxfs_arena *a, uint64_t base, uint64_t blocks) {
  *a = (vxfs_arena){.base = base, .size = blocks * VXFS_BLKSZ};
  if (!range_free(fs, a, base + VXFS_BLKSZ, a->size)) return false;
  uint64_t first = arena_take(fs, a, true);
  if (!first) return fs_fail(fs, VX_ERR_NO_MEMORY);
  if (!(a->logtl = new_block_at(fs, first, VXFS_TLOG))) return false;
  a->loghd = (vxfs_bptr){.addr = first};
  a->nlog = 1;
  // Replayed from nothing: all of it free, then the log's block taken.
  return log_append(fs, a, base + VXFS_BLKSZ, a->size, LOG_FREE) &&
         log_append(fs, a, first, VXFS_BLKSZ, LOG_ALLOC) && vxfs_log_flush(fs, a);
}

// After a replay: every block of the log's chain is one the log says is
// taken. A log that freed its own would have them handed out, and written over.
static bool log_owned(vxfs *fs, vxfs_arena *a) {
  vxfs_bptr bp = a->loghd;
  for (uint64_t i = 0; i < a->nlog; i++) {
    if (range_has(a, bp.addr)) return fs_fail(fs, VX_ERR_INVALID);
    if (i + 1 == a->nlog) break;
    vxfs_blk *b = vxfs_get(fs, bp, VXFS_TLOG);
    if (!b) return false;
    bp = b->logp;
    vxfs_drop(fs, b);
  }
  return true;
}

// Loads an arena's free space by replaying its log from loghd, up to the
// first sync barrier of generation `upto` or later, which a crash left
// after the last commit (step 3): the log is cut there, and appended to.
[[maybe_unused]] static bool vxfs_arena_load(vxfs *fs, vxfs_arena *a, uint64_t base, uint64_t blocks,
                                             vxfs_bptr loghd, uint64_t upto) {
  *a = (vxfs_arena){.base = base, .size = blocks * VXFS_BLKSZ, .loghd = loghd, .used = blocks * VXFS_BLKSZ};
  vxfs_bptr bp = loghd;
  for (uint64_t chain = 0;; chain++) {
    if (chain > blocks) return fs_fail(fs, VX_ERR_INVALID); // a loop in the chain
    vxfs_blk *b = vxfs_get(fs, bp, VXFS_TLOG);
    if (!b) return false;
    a->nlog++;
    bool cut = false;
    for (uint32_t i = 0; i < b->logsz && !cut;) {
      uint64_t ent = vxfs_get64(b->data + i), at = ent & ~0xffull;
      uint8_t op = (uint8_t)ent;
      uint32_t n = op >= LOG_ALLOC ? 16 : 8;
      if (i + n > b->logsz) {
        vxfs_drop(fs, b);
        return fs_fail(fs, VX_ERR_INVALID);
      }
      uint64_t len = op >= LOG_ALLOC ? vxfs_get64(b->data + i + 8) : VXFS_BLKSZ;
      bool ok = true;
      switch (op) {
      case LOG_SYNC:
        if (ent >> VXFS_LOG_SYNC_SHIFT >= upto) { // after the last commit: not durable, and dropped
          b->logsz = (uint16_t)i;
          b->logp = (vxfs_bptr){};
          cut = true;
        }
        break;
      case LOG_ALLOC:
      case LOG_ALLOC1:
        ok = len % VXFS_BLKSZ == 0 && at % VXFS_BLKSZ == 0 && range_grab(fs, a, at, len);
        a->used += len;
        break;
      case LOG_FREE:
      case LOG_FREE1:
        ok = len % VXFS_BLKSZ == 0 && at % VXFS_BLKSZ == 0 && at >= base + VXFS_BLKSZ &&
             at + len <= base + VXFS_BLKSZ + a->size && range_free(fs, a, at, len);
        a->used -= len;
        break;
      default: ok = false; break;
      }
      if (!ok) {
        vxfs_drop(fs, b);
        return fs_fail(fs, VX_ERR_INVALID);
      }
      i += n;
    }
    if (cut || !b->logp.addr) { // the last block: open for appending
      if (cut) b->flags |= VXFS_BDIRTY;
      a->logtl = b;
      return log_owned(fs, a);
    }
    bp = b->logp;
    vxfs_drop(fs, b);
  }
}

// Rewrites the log as the free ranges alone, in new blocks: a long log is
// short again. The new log also says the old chain's blocks are free, but
// they are kept from reuse (a->retired) until vxfs_log_retire: until the
// commit that points the arena at the new log is durable, a crash replays
// the old one, which must still be on the disk.
[[maybe_unused]] static bool vxfs_log_compress(vxfs *fs, vxfs_arena *a) {
  if (a->nretired) return fs_fail(fs, VX_ERR_BAD_STATE); // the last compression's commit has not landed
  if (!vxfs_log_flush(fs, a)) return false;
  // Enough blocks for every range at 16 bytes each, taken from the front
  // and unlogged: the old log, which a crash replays, has them free.
  uint32_t per = (VXFS_LOGSPC - VXFS_LOGSLOP) / 16, need = a->nfree / per + 2, got = 0;
  uint64_t nold = a->nlog;
  uint64_t *blks = fs_alloc(fs, need * sizeof *blks),
           *old = blks ? fs_alloc(fs, nold * sizeof *old) : nullptr;
  bool ok = old != nullptr;
  for (; ok && got < need; got++)
    if (!(blks[got] = arena_take(fs, a, true))) ok = fs_fail(fs, VX_ERR_NO_MEMORY);
  vxfs_bptr bp = a->loghd;
  for (uint64_t i = 0; ok && i < nold; i++) { // the old chain
    old[i] = bp.addr;
    vxfs_blk *b = i + 1 == nold ? vxfs_hold(fs, a->logtl) : vxfs_get(fs, bp, VXFS_TLOG);
    if (!b) ok = false;
    if (b) bp = b->logp, vxfs_drop(fs, b);
  }
  uint32_t used = 0;
  vxfs_blk *b = ok ? new_block_at(fs, blks[used++], VXFS_TLOG) : nullptr;
  ok = b != nullptr;
  for (uint32_t r = 0; ok && r < a->nfree; r++) {
    if (b->logsz >= VXFS_LOGSPC - VXFS_LOGSLOP) {
      b->logp = (vxfs_bptr){.addr = blks[used]};
      vxfs_blk *next = new_block_at(fs, blks[used++], VXFS_TLOG);
      ok = next && vxfs_write_block(fs, b);
      vxfs_drop(fs, b);
      b = next;
    }
    if (ok) {
      vxfs_put64(b->data + b->logsz, a->free[r].off | LOG_FREE);
      vxfs_put64(b->data + b->logsz + 8, a->free[r].len);
      b->logsz += 16;
    }
  }
  if (ok) {
    vxfs_drop(fs, a->logtl);
    a->loghd = (vxfs_bptr){.addr = blks[0]};
    a->logtl = b;
    a->nlog = used;
    b->flags |= VXFS_BDIRTY;
    a->retired = old, a->nretired = nold;
    old = nullptr;
  } else if (b) {
    vxfs_drop(fs, b);
  }
  // The blocks taken and not used (all of them, if it failed): never
  // written, so free at once, and logged so in the new log.
  for (uint32_t i = ok ? used : 0; i < got; i++) {
    cache_forget(fs, blks[i]);
    range_free(fs, a, blks[i], VXFS_BLKSZ);
    a->used -= VXFS_BLKSZ;
    if (ok) ok = log_append(fs, a, blks[i], VXFS_BLKSZ, LOG_FREE);
  }
  for (uint64_t i = 0; ok && i < a->nretired; i++)
    ok = log_append(fs, a, a->retired[i], VXFS_BLKSZ, LOG_FREE);
  ok = ok && vxfs_log_flush(fs, a);
  fs_release(fs, old, nold * sizeof *old);
  fs_release(fs, blks, need * sizeof *blks);
  return ok;
}

// After the commit that points the arena at its new log: the old chain's
// blocks may be reused.
[[maybe_unused]] static bool vxfs_log_retire(vxfs *fs, vxfs_arena *a) {
  bool ok = true;
  for (uint64_t i = 0; i < a->nretired && ok; i++) {
    cache_forget(fs, a->retired[i]);
    ok = range_free(fs, a, a->retired[i], VXFS_BLKSZ);
    a->used -= VXFS_BLKSZ;
  }
  fs_release(fs, a->retired, a->nretired * sizeof *a->retired);
  a->retired = nullptr, a->nretired = 0;
  return ok;
}

// --- Allocating and freeing blocks ---

// A block's address from the arena the round robin picks for its type
// (11 §6), logged; 0 if every arena is full.
static uint64_t block_alloc(vxfs *fs, uint16_t type) {
  if (fs->err != VX_OK) return 0;
  for (uint32_t tries = 0; tries < fs->narenas; tries++) {
    vxfs_arena *a = &fs->arenas[(fs->rr + type + tries) % fs->narenas];
    uint64_t b = arena_take(fs, a, false);
    if (!b) continue;
    if (!log_append(fs, a, b, VXFS_BLKSZ, LOG_ALLOC)) return 0;
    return b;
  }
  fs_fail(fs, VX_ERR_NO_MEMORY); // the volume is full
  return 0;
}

// A new block of `type`, born in this generation, held.
[[maybe_unused]] static vxfs_blk *vxfs_new_block(vxfs *fs, uint16_t type) {
  uint64_t addr = block_alloc(fs, type);
  return addr ? new_block_at(fs, addr, type) : nullptr;
}

static bool block_dealloc(vxfs *fs, uint64_t addr) {
  vxfs_arena *a = arena_of(fs, addr);
  if (!a) return fs_fail(fs, VX_ERR_INVALID);
  cache_forget(fs, addr);
  if (!log_append(fs, a, addr, VXFS_BLKSZ, LOG_FREE) || !range_free(fs, a, addr, VXFS_BLKSZ)) return false;
  a->used -= VXFS_BLKSZ;
  return true;
}

// A block the tree no longer points at. Born in this generation, nothing
// committed can reach it: it is freed when the current operation ends.
// Born earlier, the last commit may: it is killed, kept for step 3's
// deadlists.
[[maybe_unused]] static bool vxfs_free(vxfs *fs, vxfs_bptr bp) {
  if (bp.gen >= fs->gen) {
    if (!fs_grow(fs, (void **)&fs->limbo, fs->nlimbo, &fs->caplimbo, sizeof *fs->limbo)) return false;
    fs->limbo[fs->nlimbo++] = bp;
  } else {
    if (!fs_grow(fs, (void **)&fs->dead, fs->ndead, &fs->capdead, sizeof *fs->dead)) return false;
    fs->dead[fs->ndead++] = bp;
  }
  return true;
}

// The end of an operation: what it freed of this generation's is free.
[[maybe_unused]] static bool vxfs_end_op(vxfs *fs) {
  bool ok = true;
  for (uint32_t i = 0; i < fs->nlimbo && ok; i++) ok = block_dealloc(fs, fs->limbo[i].addr);
  fs->nlimbo = 0;
  return ok;
}

// The library's state over a device, with a cache of `cache` blocks.
[[maybe_unused]] static bool vxfs_open(vxfs *fs, vxfs_dev dev, vxfs_mem mem, uint32_t cache) {
  *fs = (vxfs){.dev = dev, .mem = mem, .gen = 1};
  if (cache < 4 * VXFS_MAXHEIGHT)
    cache = 4 * VXFS_MAXHEIGHT; // a whole path, its splits and siblings, held at once
  fs->nhash = 1;
  while (fs->nhash < cache) fs->nhash <<= 1;
  fs->blocks = fs_alloc(fs, (size_t)cache * sizeof *fs->blocks);
  fs->hash = fs_alloc(fs, (size_t)fs->nhash * sizeof *fs->hash);
  if (!fs->blocks || !fs->hash) return false;
  memset(fs->hash, 0, (size_t)fs->nhash * sizeof *fs->hash);
  fs->nblocks = cache;
  for (uint32_t i = 0; i < cache; i++) {
    fs->blocks[i] = (vxfs_blk){};
    lru_push(fs, &fs->blocks[i]);
  }
  return true;
}

// Room for n arenas, each to be set up by vxfs_arena_init or _load.
[[maybe_unused]] static bool vxfs_arenas(vxfs *fs, uint32_t n) {
  if (!(fs->arenas = fs_alloc(fs, n * sizeof *fs->arenas))) return false;
  memset(fs->arenas, 0, n * sizeof *fs->arenas);
  fs->narenas = n;
  return true;
}

[[maybe_unused]] static void vxfs_close(vxfs *fs) {
  for (uint32_t i = 0; i < fs->narenas; i++) {
    vxfs_arena *a = &fs->arenas[i];
    fs_release(fs, a->free, a->capfree * sizeof *a->free);
    fs_release(fs, a->retired, a->nretired * sizeof *a->retired);
  }
  fs_release(fs, fs->arenas, fs->narenas * sizeof *fs->arenas);
  fs_release(fs, fs->limbo, fs->caplimbo * sizeof *fs->limbo);
  fs_release(fs, fs->dead, fs->capdead * sizeof *fs->dead);
  fs_release(fs, fs->hash, (size_t)fs->nhash * sizeof *fs->hash);
  fs_release(fs, fs->blocks, (size_t)fs->nblocks * sizeof *fs->blocks);
  *fs = (vxfs){};
}
