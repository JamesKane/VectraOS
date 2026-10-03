// vxfs_test.c: lib/vx-fs's block layer over a device in memory. XXH64
// against the reference implementation's values; packing; blocks written,
// read back and checked against their pointers' hashes, damage refused and
// sticky; arenas allocating and freeing, their logs replayed to the same
// free space, cut at a sync barrier, chained across blocks, and compressed;
// blocks freed now (this generation's) or kept for the deadlists (older);
// malformed tree blocks refused; a cache with every block held.

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-fs/blk.c"

// --- A device and memory ---

typedef struct memdev {
  uint8_t *bytes;
  uint64_t size;
  bool fail_reads;
  uint64_t barriers;
} memdev;

static vx_status md_read(void *ctx, uint64_t addr, void *buf) {
  memdev *d = ctx;
  if (d->fail_reads) return VX_ERR_IO;
  memcpy(buf, d->bytes + addr, VXFS_BLKSZ);
  return VX_OK;
}

static vx_status md_write(void *ctx, uint64_t addr, const void *buf) {
  memdev *d = ctx;
  memcpy(d->bytes + addr, buf, VXFS_BLKSZ);
  return VX_OK;
}

static vx_status md_barrier(void *ctx) {
  ((memdev *)ctx)->barriers++;
  return VX_OK;
}

static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }

static const vxfs_mem MEM = {.alloc = m_alloc, .free = m_free};

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

static vxfs_dev dev_of(memdev *d) {
  return (vxfs_dev){.ctx = d, .read = md_read, .write = md_write, .barrier = md_barrier, .size = d->size};
}

// --- XXH64 ---

static uint8_t pattern_byte(size_t i) { return (uint8_t)((i * 31 + 7) ^ (i >> 8)); }

static void test_xxh64(void) {
  // From the reference implementation (libxxhash 0.8) over pattern_byte's bytes.
  static const struct {
    uint32_t len;
    uint64_t seed, hash;
  } V[] = {
      {0, 0x0000000000000000ull, 0xef46db3751d8e999ull},
      {0, 0x9e3779b97f4a7c15ull, 0xc4349fc93c010000ull},
      {1, 0x0000000000000000ull, 0xa96c7f0ce858bbb7ull},
      {1, 0x9e3779b97f4a7c15ull, 0x585882422a6165e7ull},
      {3, 0x0000000000000000ull, 0x56e6957632a487f9ull},
      {3, 0x9e3779b97f4a7c15ull, 0x5acb303e78133c22ull},
      {4, 0x0000000000000000ull, 0xc60d15b1e3ff8f04ull},
      {4, 0x9e3779b97f4a7c15ull, 0x7d51d5e2461732b3ull},
      {7, 0x0000000000000000ull, 0xafbefc3d6c6f9a8eull},
      {7, 0x9e3779b97f4a7c15ull, 0x2ce9adec2b2c8104ull},
      {8, 0x0000000000000000ull, 0x3da5c7aa269683e0ull},
      {8, 0x9e3779b97f4a7c15ull, 0x758848f033fa76a2ull},
      {15, 0x0000000000000000ull, 0xae2a37eb9357caa7ull},
      {15, 0x9e3779b97f4a7c15ull, 0xa18d5c90d722cee3ull},
      {16, 0x0000000000000000ull, 0xa19ad429b02bc413ull},
      {16, 0x9e3779b97f4a7c15ull, 0xe3594f9058b426e7ull},
      {31, 0x0000000000000000ull, 0x4a74f3a1a39ad4a1ull},
      {31, 0x9e3779b97f4a7c15ull, 0x8137041f5af88413ull},
      {32, 0x0000000000000000ull, 0x8d57d6a4671cc43dull},
      {32, 0x9e3779b97f4a7c15ull, 0x184ebcf3745cd46cull},
      {33, 0x0000000000000000ull, 0x62c9fd21ed857664ull},
      {33, 0x9e3779b97f4a7c15ull, 0x52fac3c981f3cc2eull},
      {63, 0x0000000000000000ull, 0x5c320a0d2707057full},
      {63, 0x9e3779b97f4a7c15ull, 0x64ef99a2e94cc7bdull},
      {64, 0x0000000000000000ull, 0x7bbabbc45729d17eull},
      {64, 0x9e3779b97f4a7c15ull, 0xf7f22435fe1ab128ull},
      {100, 0x0000000000000000ull, 0xefa0ad2d3e70c151ull},
      {100, 0x9e3779b97f4a7c15ull, 0xbc7ab33be7528c18ull},
      {1000, 0x0000000000000000ull, 0x6e487f236c0c63ecull},
      {1000, 0x9e3779b97f4a7c15ull, 0x857708aaa1358a00ull},
      {16384, 0x0000000000000000ull, 0x53ed92d52f789284ull},
      {16384, 0x9e3779b97f4a7c15ull, 0x1fa3101ec8a4a74eull},
  };
  static uint8_t buf[16384];
  for (size_t i = 0; i < sizeof buf; i++) buf[i] = pattern_byte(i);
  for (size_t i = 0; i < sizeof V / sizeof V[0]; i++)
    CHECK(vxfs_xxh64(buf, V[i].len, V[i].seed) == V[i].hash);
}

// --- Packing ---

static void test_packing(void) {
  uint8_t p[VXFS_DIRSZ + 8] = {};
  vxfs_dir d = {.flags = 1,
                .qid_path = 0x0102030405060708,
                .qid_vers = 9,
                .qid_type = 0x80,
                .mode = 0x800001ed,
                .atime = -1,
                .mtime = 2,
                .ctime = 3,
                .btime = 4,
                .length = 1ull << 40,
                .uid = 10,
                .gid = 11,
                .muid = 12};
  vxfs_packdir(p, &d);
  CHECK(p[VXFS_DIRSZ] == 0); // nothing past its size
  vxfs_dir e = vxfs_unpackdir(p);
  CHECK(e.flags == d.flags && e.qid_path == d.qid_path && e.qid_vers == d.qid_vers &&
        e.qid_type == d.qid_type);
  CHECK(e.mode == d.mode && e.atime == d.atime && e.mtime == d.mtime && e.ctime == d.ctime &&
        e.btime == d.btime);
  CHECK(e.length == d.length && e.uid == d.uid && e.gid == d.gid && e.muid == d.muid);

  vxfs_bptr bp = {0x4000, 0xdeadbeefcafef00d, 7}, bq;
  vxfs_packbp(p, bp);
  bq = vxfs_unpackbp(p);
  CHECK(bq.addr == bp.addr && bq.hash == bp.hash && bq.gen == bp.gen);
  CHECK(p[0] == 0x00 && p[1] == 0x40); // little-endian in blocks

  // Big-endian in keys: they sort as their numbers do.
  uint8_t a[8], b[8];
  vxfs_kput64(a, 255), vxfs_kput64(b, 256);
  CHECK(vxfs_keycmp(a, 8, b, 8) < 0);
  CHECK(vxfs_kget64(b) == 256);
  CHECK(vxfs_keycmp(a, 7, a, 8) < 0 && vxfs_keycmp(a, 8, a, 7) > 0 && vxfs_keycmp(a, 8, a, 8) == 0);
  CHECK(vxfs_keycmp(a, 0, b, 0) == 0);
}

// --- Free space ---

// The arena's free ranges are sorted, disjoint, never adjacent, inside it,
// and with `used` add up to its size.
static bool arena_sane(const vxfs_arena *a) {
  uint64_t free = 0, lo = a->base + VXFS_BLKSZ, hi = lo + a->size;
  for (uint32_t i = 0; i < a->nfree; i++) {
    const vxfs_range *r = &a->free[i];
    if (!r->len || r->off < lo || r->off + r->len > hi || r->off % VXFS_BLKSZ || r->len % VXFS_BLKSZ)
      return false;
    if (i && a->free[i - 1].off + a->free[i - 1].len >= r->off) return false;
    free += r->len;
  }
  return free + a->used == a->size;
}

static bool arenas_equal(const vxfs_arena *a, const vxfs_arena *b) {
  if (a->nfree != b->nfree || a->used != b->used) return false;
  for (uint32_t i = 0; i < a->nfree; i++)
    if (a->free[i].off != b->free[i].off || a->free[i].len != b->free[i].len) return false;
  return true;
}

static bool is_free(const vxfs_arena *a, uint64_t addr) {
  for (uint32_t i = 0; i < a->nfree; i++)
    if (addr >= a->free[i].off && addr < a->free[i].off + a->free[i].len) return true;
  return false;
}

static void test_ranges(void) {
  vxfs fs = {.mem = MEM};
  vxfs_arena a = {.base = 0, .size = 64ull * VXFS_BLKSZ};
  const uint64_t B = VXFS_BLKSZ, lo = B;
  CHECK(range_free(&fs, &a, lo, a.size));
  a.used = 0;
  CHECK(a.nfree == 1 && arena_sane(&a));
  CHECK(range_grab(&fs, &a, lo + 4 * B, 2 * B)); // the middle: two pieces
  a.used += 2 * B;
  CHECK(a.nfree == 2 && arena_sane(&a));
  CHECK(range_grab(&fs, &a, lo, B));          // the front
  CHECK(range_grab(&fs, &a, lo + 63 * B, B)); // the end
  a.used += 2 * B;
  CHECK(a.nfree == 2 && arena_sane(&a));
  CHECK(!range_grab(&fs, &a, lo + 4 * B, B) && fs.err == VX_ERR_INVALID); // not free
  fs.err = VX_OK;
  CHECK(!range_free(&fs, &a, lo + 10 * B, B) && fs.err == VX_ERR_INVALID); // already free
  fs.err = VX_OK;
  CHECK(range_free(&fs, &a, lo + 5 * B, B)); // joins the range after it
  CHECK(range_free(&fs, &a, lo + 4 * B, B)); // joins both: one range again, but the ends
  a.used -= 2 * B;
  CHECK(a.nfree == 1 && arena_sane(&a));
  CHECK(range_free(&fs, &a, lo, B) && range_free(&fs, &a, lo + 63 * B, B));
  a.used -= 2 * B;
  CHECK(a.nfree == 1 && a.free[0].off == lo && a.free[0].len == a.size && arena_sane(&a));
  // Many small pieces, then joined back.
  for (uint64_t i = 0; i < 64; i += 2) CHECK(range_grab(&fs, &a, lo + i * B, B));
  CHECK(a.nfree == 32);
  for (uint64_t i = 0; i < 64; i += 2) CHECK(range_free(&fs, &a, lo + i * B, B));
  CHECK(a.nfree == 1 && fs.err == VX_OK);
  free(a.free);
}

// --- Blocks ---

static vxfs fresh(memdev *d, uint32_t arenas, uint64_t blocks_each, uint32_t cache) {
  vxfs fs;
  CHECK(vxfs_open(&fs, dev_of(d), MEM, cache));
  CHECK(vxfs_arenas(&fs, arenas));
  for (uint32_t i = 0; i < arenas; i++)
    CHECK(vxfs_arena_init(&fs, &fs.arenas[i], i * (blocks_each + 2) * VXFS_BLKSZ, blocks_each));
  return fs;
}

static void test_blocks(void) {
  memdev *d = memdev_new(132);
  vxfs fs = fresh(d, 2, 64, 256);
  CHECK(fs.err == VX_OK);
  for (uint32_t i = 0; i < 2; i++) CHECK(fs.arenas[i].used == VXFS_BLKSZ && arena_sane(&fs.arenas[i]));

  // A data block and a leaf, written, then read back by a fresh cache.
  vxfs_blk *b = vxfs_new_block(&fs, VXFS_TDAT);
  CHECK(b && b->bp.gen == 1);
  for (uint32_t i = 0; i < VXFS_BLKSZ; i++) b->data[i] = pattern_byte(i);
  CHECK(vxfs_write_block(&fs, b));
  vxfs_bptr dat = b->bp;
  vxfs_drop(&fs, b);

  vxfs_blk *l = vxfs_new_block(&fs, VXFS_TLEAF);
  CHECK(l);
  // One entry: key "k", value "v", at the end of the leaf's space.
  uint32_t at = VXFS_LEAFSPC - 6;
  vxfs_put16(l->data, (uint16_t)at);
  uint8_t ent[] = {1, 0, 'k', 1, 0, 'v'};
  memcpy(l->data + at, ent, sizeof ent);
  l->nval = 1, l->valsz = sizeof ent;
  CHECK(vxfs_write_block(&fs, l));
  vxfs_bptr leaf = l->bp;
  vxfs_drop(&fs, l);
  CHECK(dat.addr != leaf.addr && dat.hash && leaf.hash);
  for (uint32_t i = 0; i < 2; i++) CHECK(vxfs_log_flush(&fs, &fs.arenas[i]));

  vxfs again;
  CHECK(vxfs_open(&again, dev_of(d), MEM, 256));
  b = vxfs_get(&again, dat, VXFS_TDAT);
  CHECK(b && b->data[100] == pattern_byte(100) && again.reads == 1);
  vxfs_drop(&again, b);
  b = vxfs_get(&again, dat, VXFS_TDAT); // from the cache
  CHECK(b && again.reads == 1);
  vxfs_drop(&again, b);
  l = vxfs_get(&again, leaf, VXFS_TTREE);
  CHECK(l && l->type == VXFS_TLEAF && l->nval == 1 && l->valsz == 6);
  vxfs_drop(&again, l);
  CHECK(!vxfs_get(&again, leaf, VXFS_TPIVOT) && again.err == VX_ERR_INVALID); // not what it is
  vxfs_close(&again);

  // Damage: one bit, and the hash refuses it; the error is sticky.
  CHECK(vxfs_open(&again, dev_of(d), MEM, 256));
  d->bytes[dat.addr + 5000] ^= 0x10;
  CHECK(!vxfs_get(&again, dat, VXFS_TDAT) && again.err == VX_ERR_INVALID);
  d->bytes[dat.addr + 5000] ^= 0x10;
  CHECK(!vxfs_new_block(&again, VXFS_TDAT)); // nothing more after an error
  vxfs_close(&again);

  // The device's errors are passed on.
  CHECK(vxfs_open(&again, dev_of(d), MEM, 256));
  d->fail_reads = true;
  CHECK(!vxfs_get(&again, dat, VXFS_TDAT) && again.err == VX_ERR_IO);
  d->fail_reads = false;
  vxfs_close(&again);

  // Pointers outside the device, or not on a block.
  CHECK(vxfs_open(&again, dev_of(d), MEM, 256));
  CHECK(!vxfs_get(&again, (vxfs_bptr){.addr = d->size}, VXFS_TDAT) && again.err == VX_ERR_INVALID);
  again.err = VX_OK;
  CHECK(!vxfs_get(&again, (vxfs_bptr){.addr = 100}, VXFS_TDAT) && again.err == VX_ERR_INVALID);
  vxfs_close(&again);

  vxfs_close(&fs);
  memdev_free(d);
}

// A leaf of the entries given as {key, value} strings, finalized in place.
static void make_leaf(vxfs_blk *b, const char *const *kv, uint32_t n) {
  memset(b->buf, 0, sizeof b->buf);
  b->type = VXFS_TLEAF;
  b->data = b->buf + VXFS_LEAFHDSZ;
  uint32_t end = VXFS_LEAFSPC;
  b->nval = (uint16_t)n, b->valsz = 0;
  for (uint32_t i = 0; i < n; i++) {
    const char *k = kv[(size_t)2 * i], *v = kv[(size_t)2 * i + 1];
    uint16_t nk = (uint16_t)strlen(k), nv = (uint16_t)strlen(v);
    end -= 4u + nk + nv;
    vxfs_put16(b->data + (size_t)2 * i, (uint16_t)end);
    uint8_t *p = b->data + end;
    vxfs_put16(p, nk), vxfs_put16(p + 2 + nk, nv);
    for (uint16_t j = 0; j < nk; j++) p[2 + j] = (uint8_t)k[j]; // the bytes alone, not a C string
    for (uint16_t j = 0; j < nv; j++) p[4 + nk + j] = (uint8_t)v[j];
    b->valsz = (uint16_t)(b->valsz + 4 + nk + nv);
  }
  finalize(b);
}

static void test_malformed(void) {
  static vxfs_blk b;
  const char *good[] = {"a", "1", "b", "2", "c", "3"};
  make_leaf(&b, good, 3);
  CHECK(parse_block(&b, VXFS_TLEAF));

  const char *disorder[] = {"b", "1", "a", "2"};
  make_leaf(&b, disorder, 2);
  CHECK(!parse_block(&b, VXFS_TLEAF));
  const char *twice[] = {"a", "1", "a", "2"};
  make_leaf(&b, twice, 2);
  CHECK(!parse_block(&b, VXFS_TLEAF));

  make_leaf(&b, good, 3);
  vxfs_put16(b.buf + 2, 4000); // more entries than the space holds
  CHECK(!parse_block(&b, VXFS_TLEAF));
  make_leaf(&b, good, 3);
  vxfs_put16(b.buf + 4, 1); // sizes that do not add up
  CHECK(!parse_block(&b, VXFS_TLEAF));
  make_leaf(&b, good, 3);
  vxfs_put16(b.data + 2, 1); // an offset into the offsets
  CHECK(!parse_block(&b, VXFS_TLEAF));
  make_leaf(&b, good, 3);
  vxfs_put16(b.data, (uint16_t)(VXFS_LEAFSPC - 1)); // an entry running off the end
  CHECK(!parse_block(&b, VXFS_TLEAF));
  make_leaf(&b, good, 3);
  vxfs_put16(b.data + vxfs_get16(b.data), 0); // an empty key
  CHECK(!parse_block(&b, VXFS_TLEAF));
  make_leaf(&b, good, 3);
  vxfs_put16(b.buf, 9); // no such type
  CHECK(!parse_block(&b, VXFS_TTREE));
  make_leaf(&b, good, 3);
  vxfs_put16(b.buf, VXFS_TPIVOT); // a leaf's entries as a pivot's: values are not pointers
  CHECK(!parse_block(&b, VXFS_TTREE));
  make_leaf(&b, good, 0);
  CHECK(parse_block(&b, VXFS_TLEAF)); // an empty leaf is a leaf (an empty tree's root)

  // A log whose own hash does not match.
  memset(b.buf, 0, sizeof b.buf);
  b.type = VXFS_TLOG, b.data = b.buf + VXFS_LOGHDSZ, b.logsz = 8;
  vxfs_put64(b.data, VXFS_BLKSZ | LOG_ALLOC1);
  finalize(&b);
  CHECK(parse_block(&b, VXFS_TLOG));
  b.data[0] ^= 1;
  CHECK(!parse_block(&b, VXFS_TLOG));
}

// --- Arenas and their logs ---

// A fresh vxfs over the same device, its arenas loaded as headers h say.
static vxfs reload(memdev *d, const vxfs_arena_hdr *h, uint32_t n) {
  vxfs r;
  CHECK(vxfs_open(&r, dev_of(d), MEM, 256));
  CHECK(vxfs_arenas(&r, n));
  for (uint32_t i = 0; i < n; i++) CHECK(vxfs_arena_load(&r, &r.arenas[i], &h[i]));
  return r;
}

// Every arena's log written, and what its header would say.
static void seal(vxfs *fs, vxfs_arena_hdr *h) {
  for (uint32_t i = 0; i < fs->narenas; i++) CHECK(vxfs_arena_seal(fs, &fs->arenas[i], &h[i]));
}

static vxfs_arena copy_arena(const vxfs_arena *a) {
  vxfs_arena c = *a;
  c.free = malloc(a->nfree * sizeof *a->free);
  memcpy(c.free, a->free, a->nfree * sizeof *a->free);
  return c;
}

// A block taken from the arena and logged so.
static uint64_t take_logged(vxfs *fs, vxfs_arena *a) {
  uint64_t o = arena_take(fs, a, false);
  return o && log_append(fs, a, o, VXFS_BLKSZ, LOG_ALLOC) ? o : 0;
}

static void test_logs(void) {
  memdev *d = memdev_new(2052);
  vxfs fs = fresh(d, 2, 1024, 256);
  vxfs_arena_hdr h[2];

  // Allocations spread over both arenas, some freed: a reload sees the same.
  uint64_t addr[600];
  for (uint32_t i = 0; i < 600; i++) {
    if (i == 300) fs.rr++; // as after a few thousand writes: the next arena
    vxfs_blk *b = vxfs_new_block(&fs, VXFS_TDAT);
    CHECK(b != nullptr);
    if (!b) return;
    addr[i] = b->bp.addr;
    CHECK(vxfs_write_block(&fs, b));
    vxfs_drop(&fs, b);
  }
  CHECK(fs.arenas[0].used > VXFS_BLKSZ && fs.arenas[1].used > VXFS_BLKSZ);
  for (uint32_t i = 0; i < 600; i += 3) CHECK(block_dealloc(&fs, addr[i]));
  for (uint32_t i = 0; i < 2; i++) CHECK(arena_sane(&fs.arenas[i]));
  seal(&fs, h);
  vxfs r = reload(d, h, 2);
  CHECK(r.err == VX_OK);
  for (uint32_t i = 0; i < 2; i++) CHECK(arenas_equal(&fs.arenas[i], &r.arenas[i]));
  vxfs_close(&r);

  // A commit's header, then more logged and written: a reload by that
  // header sees the log as it was, even with the tail block written over
  // since (torn, here: its own header and hash garbage).
  vxfs_arena *a = &fs.arenas[0];
  seal(&fs, h);
  vxfs_arena before = copy_arena(a);
  for (uint32_t i = 0; i < 40; i++) CHECK(take_logged(&fs, a));
  CHECK(vxfs_log_flush(&fs, a));
  memset(d->bytes + h[0].logtl, 0xa5, 12); // type, size and hash
  r = reload(d, h, 2);
  CHECK(r.err == VX_OK && arenas_equal(&before, &r.arenas[0]));
  CHECK(r.arenas[0].logtl->logsz == h[0].tailsz);
  vxfs_close(&r);
  free(before.free);
  // A covered entry damaged: refused.
  d->bytes[h[0].logtl + VXFS_LOGHDSZ + 8] ^= 0x40;
  vxfs bad;
  CHECK(vxfs_open(&bad, dev_of(d), MEM, 256) && vxfs_arenas(&bad, 1));
  CHECK(!vxfs_arena_load(&bad, &bad.arenas[0], &h[0]) && bad.err == VX_ERR_INVALID);
  vxfs_close(&bad);
  d->bytes[h[0].logtl + VXFS_LOGHDSZ + 8] ^= 0x40;
  seal(&fs, h);
  r = reload(d, h, 2);
  CHECK(r.err == VX_OK && arenas_equal(a, &r.arenas[0]));
  vxfs_close(&r);

  // Enough to chain the log across blocks.
  uint64_t nlog = a->nlog;
  for (uint32_t round = 0; round < 6; round++) {
    uint64_t got[300];
    uint32_t n = 0;
    for (; n < 300; n++)
      if (!(got[n] = take_logged(&fs, a))) break;
    for (uint32_t i = 0; i < n; i++) CHECK(block_dealloc(&fs, got[i]));
  }
  CHECK(a->nlog > nlog && arena_sane(a));
  seal(&fs, h);
  r = reload(d, h, 2);
  CHECK(r.err == VX_OK && arenas_equal(a, &r.arenas[0]) && r.arenas[0].nlog == a->nlog);
  vxfs_close(&r);
  // A header whose tail is not on the chain: refused.
  vxfs_arena_hdr wrong = h[0];
  wrong.logtl = wrong.base + 900ull * VXFS_BLKSZ;
  CHECK(vxfs_open(&bad, dev_of(d), MEM, 256) && vxfs_arenas(&bad, 1));
  CHECK(!vxfs_arena_load(&bad, &bad.arenas[0], &wrong) && bad.err == VX_ERR_INVALID);
  vxfs_close(&bad);

  // Compressed: the free ranges alone, in fewer blocks. The old chain stays
  // taken until it is retired (deferred) and the deferred blocks freed,
  // after the commit; only then do the logs say it is free.
  uint64_t old_head = a->loghd.addr, longer = a->nlog;
  CHECK(vxfs_log_compress(&fs, a));
  CHECK(a->nlog < longer && a->loghd.addr != old_head && a->nretired == longer && arena_sane(a));
  CHECK(!is_free(a, old_head));
  CHECK(!vxfs_log_compress(&fs, a) && fs.err == VX_ERR_BAD_STATE); // not again before the commit
  fs.err = VX_OK;
  seal(&fs, h);
  r = reload(d, h, 2);
  CHECK(r.err == VX_OK && !is_free(&r.arenas[0], old_head) && arena_sane(&r.arenas[0]));
  CHECK(arenas_equal(a, &r.arenas[0]));
  vxfs_close(&r);
  CHECK(vxfs_log_retire(&fs, a) && fs.ndeferred == longer && !is_free(a, old_head));
  CHECK(vxfs_free_deferred(&fs) && is_free(a, old_head) && arena_sane(a) && fs.ndeferred == 0);
  seal(&fs, h);
  r = reload(d, h, 2);
  CHECK(r.err == VX_OK && is_free(&r.arenas[0], old_head) && arenas_equal(a, &r.arenas[0]));
  vxfs_close(&r);

  // A loop in a log's chain is refused, not followed for ever.
  vxfs_blk *tl = a->logtl;
  tl->logp = a->loghd;
  CHECK(vxfs_write_block(&fs, tl));
  wrong = h[0];
  wrong.logtl = wrong.base + 1000ull * VXFS_BLKSZ; // not on the chain, which loops
  CHECK(vxfs_open(&bad, dev_of(d), MEM, 256) && vxfs_arenas(&bad, 1));
  CHECK(!vxfs_arena_load(&bad, &bad.arenas[0], &wrong) && bad.err == VX_ERR_INVALID);
  vxfs_close(&bad);

  vxfs_close(&fs);
  memdev_free(d);
}

// Freeing, by the tree a block left: this generation's at the operation's
// end; a branch's older ones killed, or left to the branch they came from;
// the snapshot tree's deferred.
static void test_free(void) {
  memdev *d = memdev_new(66);
  vxfs fs = fresh(d, 1, 64, 256);
  vxfs_arena *a = &fs.arenas[0];
  vxfs_bptr bp[4];
  for (uint32_t i = 0; i < 4; i++) {
    vxfs_blk *b = vxfs_new_block(&fs, VXFS_TDAT);
    bp[i] = b->bp;
    vxfs_drop(&fs, b);
  }
  CHECK(bp[0].gen == 1);
  fs.gen = 2; // committed since: they are the last commit's
  vxfs_blk *b = vxfs_new_block(&fs, VXFS_TDAT);
  vxfs_bptr now = b->bp;
  vxfs_drop(&fs, b);
  CHECK(vxfs_free(&fs, now) && vxfs_free(&fs, bp[0]));
  CHECK(fs.nlimbo == 1 && fs.ndead == 1 && !is_free(a, now.addr));
  CHECK(fs.dead[0].addr == bp[0].addr && fs.dead[0].birth == 1 && fs.dead[0].death == 2);
  CHECK(vxfs_end_op(&fs) && fs.nlimbo == 0 && is_free(a, now.addr) && arena_sane(a));
  fs.base = 1; // a branch forked at 1: its blocks born then are the other branch's
  CHECK(vxfs_free(&fs, bp[1]) && fs.ndead == 1 && fs.ndeferred == 0);
  fs.base = 0, fs.snaptree = true;
  CHECK(vxfs_free(&fs, bp[2]) && fs.ndeferred == 1 && !is_free(a, bp[2].addr));
  CHECK(vxfs_free_deferred(&fs) && is_free(a, bp[2].addr) && arena_sane(a));
  fs.snaptree = false;

  // Full: every block taken, then NO_MEMORY; the reserve is the commit's.
  uint32_t n = 0;
  a->reserve = 4ull * VXFS_BLKSZ;
  while (vxfs_new_block(&fs, VXFS_TDAT)) n++;
  CHECK(fs.err == VX_ERR_NO_MEMORY);
  fs.err = VX_OK, fs.use_reserve = true;
  uint32_t more = 0;
  while (vxfs_new_block(&fs, VXFS_TDAT)) more++;
  CHECK(fs.err == VX_ERR_NO_MEMORY && more == 4 &&
        n + more == 64 - 4); // the log, bp[0], bp[1] and bp[3] held
  vxfs_close(&fs);
  memdev_free(d);
}

// Every block in the cache held, and one more wanted.
static void test_cache(void) {
  memdev *d = memdev_new(1026);
  vxfs fs = fresh(d, 1, 1024, 8); // raised to the least it takes
  CHECK(fs.nblocks == 4 * VXFS_MAXHEIGHT);
  vxfs_blk *held[4 * VXFS_MAXHEIGHT];
  uint32_t n = 0;
  for (; n < fs.nblocks; n++)
    if (!(held[n] = vxfs_new_block(&fs, VXFS_TDAT))) break;
  CHECK(n == fs.nblocks - 1); // the log's open block is held too
  CHECK(fs.err == VX_ERR_NO_MEMORY);
  vxfs_close(&fs);

  // A dirty block dropped is not evicted: its contents would be lost.
  fs = fresh(d, 1, 1024, 8);
  vxfs_blk *dirty = vxfs_new_block(&fs, VXFS_TDAT);
  dirty->data[0] = 0x5a;
  vxfs_drop(&fs, dirty);
  for (n = 0; n < 200; n++) {
    vxfs_blk *b = vxfs_new_block(&fs, VXFS_TDAT);
    CHECK(b && b != dirty);
    if (!b) break;
    CHECK(vxfs_write_block(&fs, b));
    vxfs_drop(&fs, b);
  }
  CHECK(dirty->data[0] == 0x5a && (dirty->flags & VXFS_BCACHED));
  vxfs_close(&fs);
  memdev_free(d);
}

int main(void) {
  test_xxh64();
  test_packing();
  test_ranges();
  test_blocks();
  test_malformed();
  test_logs();
  test_free();
  test_cache();
  return check_result();
}
