// vx-fs: the system volume's file system (docs/11, ADR-0025), after 9front's
// gefs (Ori Bernstein, MIT): copy-on-write Bε trees in fixed-size blocks.
// This header holds the format: block types and sizes, keys, messages, the
// directory entry, and the library's types. Pure code over two callbacks (a
// device and memory), so the library builds for the host's tests and fuzzing
// as well as for fsd.
//
// Integers in blocks are little-endian, as everything else in VectraOS;
// integers inside keys are big-endian, so keys compare with memcmp and sort
// as their numbers do (a file's data in offset order, a directory's entries
// together).

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

// --- Sizes (11 §3) ---

static constexpr uint32_t VXFS_BLKSZ = 16384;
static constexpr uint32_t VXFS_PTRSZ = 24;   // a block pointer: addr[8] hash[8] gen[8]
static constexpr uint32_t VXFS_KEYMAX = 256; // the longest key
static constexpr uint32_t VXFS_INLMAX = 512; // the longest value kept inline
static constexpr uint32_t VXFS_KVMAX = VXFS_KEYMAX + VXFS_INLMAX;
static constexpr uint32_t VXFS_KPMAX = VXFS_KEYMAX + VXFS_PTRSZ + 2; // a pivot's key, pointer and fill
static constexpr uint32_t VXFS_MSGMAX = 1 + (VXFS_KVMAX > VXFS_KPMAX ? VXFS_KVMAX : VXFS_KPMAX);
static constexpr uint32_t VXFS_MAXHEIGHT = 32;

// Block headers: type[2], then per type.
static constexpr uint32_t VXFS_PIVHDSZ = 2 + 2 + 2 + 2 + 2;      // type nval valsz nbuf bufsz
static constexpr uint32_t VXFS_LEAFHDSZ = 2 + 2 + 2;             // type nval valsz
static constexpr uint32_t VXFS_LOGHDSZ = 2 + 2 + 8 + VXFS_PTRSZ; // type logsz loghash chain

// A pivot's data: its key/pointer area (offsets from the front, entries
// from the back), then its message buffer, laid out the same way.
static constexpr uint32_t VXFS_BUFSPC = (VXFS_BLKSZ - VXFS_PIVHDSZ) / 2;
static constexpr uint32_t VXFS_PIVSPC = VXFS_BLKSZ - VXFS_PIVHDSZ - VXFS_BUFSPC;
static constexpr uint32_t VXFS_LEAFSPC = VXFS_BLKSZ - VXFS_LEAFHDSZ;
static constexpr uint32_t VXFS_LOGSPC = VXFS_BLKSZ - VXFS_LOGHDSZ;
static constexpr uint32_t VXFS_LOGSLOP = 16 + 16 + 8; // an entry, a chaining allocation, and its pointer

enum : uint16_t {
  VXFS_TDAT = 0, // file data: no header, the whole block
  VXFS_TPIVOT = 1,
  VXFS_TLEAF = 2,
  VXFS_TLOG = 3,   // an arena's allocation log
  VXFS_TDLIST = 4, // a deadlist (step 3)
  VXFS_TARENA = 5, // an arena's header or footer (step 3)
};

// --- Keys and values (11 §4) ---

enum : uint8_t {
  VXFS_KDAT = 0,    // qid[8] off[8] -> a block pointer, or inline data
  VXFS_KENT = 1,    // pqid[8] name[] -> the entry
  VXFS_KUP = 2,     // qid[8] -> the parent's Kent key (directories only)
  VXFS_KLABEL = 3,  // name[] -> snapid[8] (snapshot tree)
  VXFS_KSNAP = 4,   // snapid[8] -> a tree (snapshot tree)
  VXFS_KDLIST = 5,  // snap[8] gen[8] -> head, tail (snapshot tree)
  VXFS_KORPHAN = 6, // qid[8] -> nothing: removed while open (ours)
};

// Messages: changes addressed to a key, buffered in pivots on their way to
// the leaves (11 §3).
enum : uint8_t {
  VXFS_ONOP = 0,
  VXFS_OINSERT = 1,  // the value, replacing any
  VXFS_ODELETE = 2,  // the key, which must exist
  VXFS_OCLEARB = 3,  // a Kdat key, if it exists, and its block freed
  VXFS_OCLOBBER = 4, // a key, if it exists
  VXFS_OWSTAT = 5,   // an entry's fields, changed in place; its version bumped
  VXFS_NMSG = 6,
};

// Owstat's value: a byte of these flags, then each field it names, in this order.
enum : uint8_t {
  VXFS_WSIZE = 1 << 0,  // length[8]
  VXFS_WMODE = 1 << 1,  // mode[4]
  VXFS_WMTIME = 1 << 2, // mtime[8], ns
  VXFS_WATIME = 1 << 3, // atime[8], ns
  VXFS_WUID = 1 << 4,   // uid[4]
  VXFS_WGID = 1 << 5,   // gid[4]
  VXFS_WMUID = 1 << 6,  // muid[4]
  VXFS_WCTIME = 1 << 7, // ctime[8], ns
};

// A Kdat value: its kind, then a block pointer, or the bytes themselves
// (a small file's, or the last of one, up to VXFS_INLMAX - 1).
enum : uint8_t { VXFS_VREF = 0, VXFS_VINL = 1 };

// The entry a Kent key holds (11 §4.1); the name is the key's.
typedef struct vxfs_dir {
  uint64_t flags;
  uint64_t qid_path;
  uint32_t qid_vers;
  uint8_t qid_type;
  uint32_t mode;
  int64_t atime, mtime, ctime, btime; // ns
  uint64_t length;
  uint32_t uid, gid, muid;
} vxfs_dir;
static constexpr uint32_t VXFS_DIRSZ = 8 + 8 + 4 + 1 + 4 + 8 + 8 + 8 + 8 + 8 + 4 + 4 + 4;

typedef struct vxfs_bptr {
  uint64_t addr, hash, gen;
} vxfs_bptr;

typedef struct vxfs_key {
  const uint8_t *k;
  uint16_t nk;
} vxfs_key;

typedef struct vxfs_kvp {
  const uint8_t *k;
  uint16_t nk;
  const uint8_t *v;
  uint16_t nv;
} vxfs_kvp;

typedef struct vxfs_msg {
  uint8_t op;
  const uint8_t *k;
  uint16_t nk;
  const uint8_t *v;
  uint16_t nv;
} vxfs_msg;

// --- Packing ---

static inline void vxfs_put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v, p[1] = (uint8_t)(v >> 8); }
static inline void vxfs_put32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> 8 * i);
}
static inline void vxfs_put64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> 8 * i);
}
static inline uint16_t vxfs_get16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t vxfs_get32(const uint8_t *p) {
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint64_t vxfs_get64(const uint8_t *p) {
  return vxfs_get32(p) | (uint64_t)vxfs_get32(p + 4) << 32;
}

// Big-endian, for integers inside keys.
static inline void vxfs_kput64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> 8 * (7 - i));
}
static inline uint64_t vxfs_kget64(const uint8_t *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = v << 8 | p[i];
  return v;
}

static inline void vxfs_packbp(uint8_t *p, vxfs_bptr bp) {
  vxfs_put64(p, bp.addr), vxfs_put64(p + 8, bp.hash), vxfs_put64(p + 16, bp.gen);
}
static inline vxfs_bptr vxfs_unpackbp(const uint8_t *p) {
  return (vxfs_bptr){vxfs_get64(p), vxfs_get64(p + 8), vxfs_get64(p + 16)};
}

static inline void vxfs_packdir(uint8_t *p, const vxfs_dir *d) {
  vxfs_put64(p, d->flags), p += 8;
  vxfs_put64(p, d->qid_path), p += 8;
  vxfs_put32(p, d->qid_vers), p += 4;
  *p++ = d->qid_type;
  vxfs_put32(p, d->mode), p += 4;
  vxfs_put64(p, (uint64_t)d->atime), p += 8;
  vxfs_put64(p, (uint64_t)d->mtime), p += 8;
  vxfs_put64(p, (uint64_t)d->ctime), p += 8;
  vxfs_put64(p, (uint64_t)d->btime), p += 8;
  vxfs_put64(p, d->length), p += 8;
  vxfs_put32(p, d->uid), p += 4;
  vxfs_put32(p, d->gid), p += 4;
  vxfs_put32(p, d->muid);
}

static inline vxfs_dir vxfs_unpackdir(const uint8_t *p) {
  vxfs_dir d;
  d.flags = vxfs_get64(p), p += 8;
  d.qid_path = vxfs_get64(p), p += 8;
  d.qid_vers = vxfs_get32(p), p += 4;
  d.qid_type = *p++;
  d.mode = vxfs_get32(p), p += 4;
  d.atime = (int64_t)vxfs_get64(p), p += 8;
  d.mtime = (int64_t)vxfs_get64(p), p += 8;
  d.ctime = (int64_t)vxfs_get64(p), p += 8;
  d.btime = (int64_t)vxfs_get64(p), p += 8;
  d.length = vxfs_get64(p), p += 8;
  d.uid = vxfs_get32(p), p += 4;
  d.gid = vxfs_get32(p), p += 4;
  d.muid = vxfs_get32(p);
  return d;
}

static inline int vxfs_keycmp(const uint8_t *a, uint16_t na, const uint8_t *b, uint16_t nb) {
  uint16_t n = na < nb ? na : nb;
  int c = n ? memcmp(a, b, n) : 0;
  if (c) return c < 0 ? -1 : 1;
  if (na == nb) return 0;
  return na < nb ? -1 : 1;
}

// --- The host's side: a device of blocks, and memory ---

// One block (VXFS_BLKSZ bytes) at a byte address that is a multiple of it.
// barrier: everything written before it is durable once it returns VX_OK
// (the block class's FLUSH, docs/proto/block.md §3).
typedef struct vxfs_dev {
  void *ctx;
  vx_status (*read)(void *ctx, uint64_t addr, void *buf);
  vx_status (*write)(void *ctx, uint64_t addr, const void *buf);
  vx_status (*barrier)(void *ctx);
  uint64_t size; // bytes
} vxfs_dev;

typedef struct vxfs_mem {
  void *ctx;
  void *(*alloc)(void *ctx, size_t n); // nullptr when there is none
  void (*free)(void *ctx, void *p, size_t n);
} vxfs_mem;
