// vxfs_fuzz.c: arbitrary bytes for vx-fs. The first byte picks what they
// are. As messages, they go to a tree in batches: whatever the tree accepts,
// a scan must give keys in order whose lookups agree, and no batch may fault.
// As a block, the first byte picks a pivot, a leaf or a log. The next bytes, up to 64 of them, are
// the header and the front of the block, and the rest go at its end, where a
// table's entries are. A tree block that parse_block accepts must have every
// entry inside the block. A log (its own hash made to match) is replayed as
// an arena's whole log, and an arena it accepts must have sane free space.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-fs/tree.c"

static constexpr uint64_t ARENA_BLOCKS = 192;
static uint8_t disk[(ARENA_BLOCKS + 2) * VXFS_BLKSZ];

static vx_status d_read([[maybe_unused]] void *ctx, uint64_t addr, void *buf) {
  memcpy(buf, disk + addr, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status d_write([[maybe_unused]] void *ctx, uint64_t addr, const void *buf) {
  memcpy(disk + addr, buf, VXFS_BLKSZ);
  return VX_OK;
}
static vx_status d_barrier([[maybe_unused]] void *ctx) { return VX_OK; }
static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }

// Every entry of a table that check_table accepted, read to its end.
static void walk(const uint8_t *d, uint32_t spc, uint16_t n, bool msgs) {
  for (uint16_t i = 0; i < n; i++) {
    uint32_t at = vxfs_get16(d + (size_t)2 * i) + (msgs ? 1u : 0u);
    uint16_t nk = vxfs_get16(d + at);
    uint16_t nv = vxfs_get16(d + at + 2 + nk);
    if (at + 4u + nk + nv > spc) abort();
  }
}

static bool arena_sane(const vxfs_arena *a) {
  uint64_t free = 0, lo = a->base + VXFS_BLKSZ, hi = lo + a->size;
  for (uint32_t i = 0; i < a->nfree; i++) {
    const vxfs_range *r = &a->free[i];
    if (!r->len || r->off < lo || r->off + r->len > hi) return false;
    if (i && a->free[i - 1].off + a->free[i - 1].len >= r->off) return false;
    free += r->len;
  }
  return free + a->used == a->size;
}

// Messages from bytes: op, key length (1-8), key bytes from a small
// alphabet, value length; the value is the length's byte repeated, times 8.
static void messages(const uint8_t *data, size_t size) {
  vxfs fs;
  vxfs_dev dev = {.read = d_read, .write = d_write, .barrier = d_barrier, .size = sizeof disk};
  if (!vxfs_open(&fs, dev, (vxfs_mem){.alloc = m_alloc, .free = m_free}, 0) || !vxfs_arenas(&fs, 1) ||
      !vxfs_arena_init(&fs, &fs.arenas[0], 0, ARENA_BLOCKS))
    abort();
  vxfs_tree t = {};
  if (!vxfs_tree_init(&fs, &t)) abort();
  static uint8_t keys[1024][8], vals[1024][VXFS_INLMAX];
  static vxfs_msg m[1024];
  uint32_t n = 0, bytes = 0;
  for (size_t at = 0; at + 3 <= size && fs.err == VX_OK;) {
    uint8_t op = (uint8_t)(1 + data[at] % 4); // insert, delete, clearb, clobber; wstat needs entries
    uint16_t nk = (uint16_t)(1 + data[at + 1] % 8), nv = (uint16_t)(data[at + 2] % 65 * 8);
    at += 3;
    if (at + nk > size) break;
    if (op != VXFS_OINSERT) nv = 0;
    uint32_t sz = 2 + 1 + 2 + nk + 2 + nv;
    if (bytes + sz > VXFS_BUFSPC || n == 1024) { // a batch: the tree takes it, or calls it damaged and stops
      vx_status st = vxfs_upsert(&fs, &t, m, n);
      if (st != VX_OK && st != VX_ERR_INVALID) abort();
      if (st != VX_OK || !vxfs_end_op(&fs)) break;
      n = bytes = 0;
    }
    uint8_t *k = keys[n], *v = vals[n];
    for (uint16_t i = 0; i < nk; i++) k[i] = (uint8_t)(data[at + i] % 6);
    at += nk;
    memset(v, (uint8_t)nv, nv);
    m[n++] = (vxfs_msg){.op = op, .k = k, .nk = nk, .v = nv ? v : nullptr, .nv = nv};
    bytes += sz;
  }
  if (fs.err == VX_OK && n && vxfs_upsert(&fs, &t, m, n) == VX_OK) vxfs_end_op(&fs);
  if (fs.err == VX_OK) {
    vxfs_scan s;
    vxfs_scan_start(&s, &t, nullptr, 0);
    vxfs_kvp kv;
    uint8_t prev[VXFS_KEYMAX], got[VXFS_INLMAX];
    uint16_t nprev = 0, ngot = 0;
    bool first = true;
    while (vxfs_scan_next(&fs, &s, &kv)) {
      if (!first && vxfs_keycmp(prev, nprev, kv.k, kv.nk) >= 0) abort();
      if (vxfs_lookup(&fs, &t, kv.k, kv.nk, got, &ngot) != VX_OK || ngot != kv.nv ||
          (ngot && memcmp(got, kv.v, ngot) != 0))
        abort();
      memcpy(prev, kv.k, kv.nk), nprev = kv.nk, first = false;
    }
    if (fs.err != VX_OK) abort();
    vxfs_scan_end(&fs, &s);
  }
  vxfs_close(&fs);
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static vxfs_blk b;
  if (size < 1) return 0;
  if (data[0] % 4 == 3) {
    messages(data + 1, size - 1); // every block it reads it wrote first
    return 0;
  }
  static const uint16_t TYPES[] = {VXFS_TPIVOT, VXFS_TLEAF, VXFS_TLOG};
  uint16_t type = TYPES[data[0] % 4];
  data++, size--;
  memset(b.buf, 0, sizeof b.buf);
  vxfs_put16(b.buf, type);
  size_t front = size < 64 ? size : 64;
  memcpy(b.buf + 2, data, front);
  memcpy(b.buf + VXFS_BLKSZ - (size - front), data + front, size - front);

  if (type != VXFS_TLOG) {
    if (!parse_block(&b, VXFS_TTREE)) return 0;
    if (b.type == VXFS_TPIVOT) {
      walk(b.data, VXFS_PIVSPC, b.nval, false);
      walk(b.data + VXFS_PIVSPC, VXFS_BUFSPC, b.nbuf, true);
    } else {
      walk(b.data, VXFS_LEAFSPC, b.nval, false);
    }
    return 0;
  }

  // A log at the arena's first block, replayed as a header says. As the
  // tail (the first byte's top bit clear): its covered prefix's hash made to
  // match. As a whole block before the tail: its own hash made to match, and
  // its chain led to an empty tail.
  bool whole = data[-1] & 0x80;
  uint16_t logsz = vxfs_get16(b.buf + 2);
  if (logsz > VXFS_LOGSPC) return 0;
  vxfs_arena_hdr h = {.blocks = ARENA_BLOCKS, .loghd = VXFS_BLKSZ, .logtl = VXFS_BLKSZ, .tailsz = logsz};
  memset(disk, 0, sizeof disk);
  if (whole) {
    vxfs_packbp(b.buf + 12, (vxfs_bptr){.addr = 2ull * VXFS_BLKSZ});
    vxfs_put64(b.buf + 4, vxfs_xxh64(b.buf + VXFS_LOGHDSZ, logsz, 0));
    h.logtl = 2ull * VXFS_BLKSZ, h.tailsz = 0, h.tailhash = vxfs_xxh64(disk, 0, 0);
  } else {
    h.tailsz &= (uint16_t)~7u;
    h.tailhash = vxfs_xxh64(b.buf + VXFS_LOGHDSZ, h.tailsz, 0);
  }
  memcpy(disk + VXFS_BLKSZ, b.buf, VXFS_BLKSZ);
  vxfs fs;
  vxfs_dev dev = {.read = d_read, .write = d_write, .barrier = d_barrier, .size = sizeof disk};
  if (!vxfs_open(&fs, dev, (vxfs_mem){.alloc = m_alloc, .free = m_free}, 0) || !vxfs_arenas(&fs, 1)) abort();
  vxfs_arena *a = &fs.arenas[0];
  if (vxfs_arena_load(&fs, a, &h)) {
    if (!arena_sane(a)) abort();
    // It goes on: all it has allocated but two (for the log to chain), then freed.
    uint64_t got[ARENA_BLOCKS], room = (a->size - a->used) / VXFS_BLKSZ;
    uint32_t n = 0;
    while (n + 2 < room && (got[n] = block_alloc(&fs, VXFS_TDAT))) n++;
    for (uint32_t i = 0; i < n; i++)
      if (!block_dealloc(&fs, got[i])) abort();
    if (fs.err != VX_OK || !arena_sane(a) || range_has(a, VXFS_BLKSZ) || range_has(a, h.logtl)) abort();
  }
  vxfs_close(&fs);
  return 0;
}
