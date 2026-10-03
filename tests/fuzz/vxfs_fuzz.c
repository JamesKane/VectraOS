// vxfs_fuzz.c: arbitrary bytes as a vx-fs block, for its checks. The first
// byte picks a pivot, a leaf or a log. The next bytes, up to 64 of them, are
// the header and the front of the block, and the rest go at its end, where a
// table's entries are. A tree block that parse_block accepts must have every
// entry inside the block. A log (its own hash made to match) is replayed as
// an arena's whole log, and an arena it accepts must have sane free space.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-fs/blk.c"

static constexpr uint64_t ARENA_BLOCKS = 64;
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

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static vxfs_blk b;
  if (size < 1) return 0;
  static const uint16_t TYPES[] = {VXFS_TPIVOT, VXFS_TLEAF, VXFS_TLOG};
  uint16_t type = TYPES[data[0] % 3];
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

  // A log: its hash made to match, then replayed at the arena's first block.
  uint16_t logsz = vxfs_get16(b.buf + 2);
  if (logsz > VXFS_LOGSPC) return 0;
  vxfs_put64(b.buf + 4, vxfs_xxh64(b.buf + VXFS_LOGHDSZ, logsz, 0));
  memset(disk, 0, sizeof disk);
  memcpy(disk + VXFS_BLKSZ, b.buf, VXFS_BLKSZ);
  vxfs fs;
  vxfs_dev dev = {.read = d_read, .write = d_write, .barrier = d_barrier, .size = sizeof disk};
  if (!vxfs_open(&fs, dev, (vxfs_mem){.alloc = m_alloc, .free = m_free}, 0) || !vxfs_arenas(&fs, 1)) abort();
  vxfs_arena *a = &fs.arenas[0];
  if (vxfs_arena_load(&fs, a, 0, ARENA_BLOCKS, (vxfs_bptr){.addr = VXFS_BLKSZ}, 1000)) {
    if (!arena_sane(a)) abort();
    // It goes on: all it has allocated but two (for the log to chain), then freed.
    uint64_t got[ARENA_BLOCKS], room = (a->size - a->used) / VXFS_BLKSZ;
    uint32_t n = 0;
    while (n + 2 < room && (got[n] = block_alloc(&fs, VXFS_TDAT))) n++;
    for (uint32_t i = 0; i < n; i++)
      if (!block_dealloc(&fs, got[i])) abort();
    if (fs.err != VX_OK || !arena_sane(a) || range_has(a, VXFS_BLKSZ)) abort();
  }
  vxfs_close(&fs);
  return 0;
}
