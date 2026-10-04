// vx-gpt: the GUID partition table (UEFI 2.10 §5.3), read and checked, and
// written (install, M5 step 9c). Pure code over read and write callbacks, so
// it builds for the host's tests and fuzzing as well as for partd
// (docs/proto/block.md §6) and install.
//
// The disk is untrusted. The primary header (LBA 1) is used if it and its
// entries pass every check; otherwise the backup (the disk's last LBA). A
// header passes if its signature, revision, size and CRC are right, it says it
// is where it was read, and its usable range and entry array lie inside the
// disk. Entries pass if their CRC matches and every partition in use lies in
// the usable range and overlaps no other. A table that fails both ways is
// refused whole: nothing on it is served.

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

static constexpr uint32_t VX_GPT_MAX = 128;               // partitions kept
static constexpr uint32_t VX_GPT_ENTRY_BYTES = 64u << 10; // the entry array read, at most
static constexpr uint32_t VX_GPT_NAME = 36 * 3 + 1;       // 36 UTF-16 units, as UTF-8, and a NUL

typedef struct vx_gpt_part {
  uint8_t type[16], guid[16]; // as stored on the disk
  uint64_t first, last;       // LBAs, inclusive
  uint64_t attributes;
  char name[VX_GPT_NAME]; // UTF-8, NUL-terminated
} vx_gpt_part;

typedef struct vx_gpt {
  uint32_t sector;  // bytes
  uint64_t sectors; // the disk's
  bool backup;      // the backup table was used: the primary is damaged
  uint8_t disk_guid[16];
  uint64_t first_usable, last_usable;
  uint32_t count; // partitions in use, in table order
  vx_gpt_part parts[VX_GPT_MAX];
  uint8_t buf[VX_GPT_ENTRY_BYTES]; // where the entries are read
} vx_gpt;

// Reads `count` sectors from `lba` into buf; false if it cannot.
typedef bool vx_gpt_read_fn(void *ctx, uint64_t lba, uint32_t count, uint8_t *buf);

static uint32_t gpt_crc32(const uint8_t *p, size_t n) {
  uint32_t c = 0xffffffff;
  for (size_t i = 0; i < n; i++) {
    c ^= p[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c;
}

static uint32_t gpt_u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t gpt_u64(const uint8_t *p) { return gpt_u32(p) | (uint64_t)gpt_u32(p + 4) << 32; }

// A UTF-16LE name of up to 36 units, as UTF-8 (lone surrogates become U+FFFD).
static void gpt_name(const uint8_t *p, char *out) {
  size_t n = 0;
  for (uint32_t i = 0; i < 36; i++) {
    size_t at = (size_t)2 * i;
    uint32_t u = p[at] | p[at + 1] << 8;
    if (!u) break;
    if (u >= 0xd800 && u < 0xdc00 && i + 1 < 36) {
      uint32_t lo = p[at + 2] | p[at + 3] << 8;
      if (lo >= 0xdc00 && lo < 0xe000) {
        u = 0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      } else {
        u = 0xfffd;
      }
    } else if (u >= 0xd800 && u < 0xe000) {
      u = 0xfffd;
    }
    if (u < 0x80) {
      out[n++] = (char)u;
    } else if (u < 0x800) {
      out[n++] = (char)(0xc0 | u >> 6);
      out[n++] = (char)(0x80 | (u & 0x3f));
    } else if (u < 0x10000) {
      out[n++] = (char)(0xe0 | u >> 12);
      out[n++] = (char)(0x80 | (u >> 6 & 0x3f));
      out[n++] = (char)(0x80 | (u & 0x3f));
    } else {
      out[n++] = (char)(0xf0 | u >> 18);
      out[n++] = (char)(0x80 | (u >> 12 & 0x3f));
      out[n++] = (char)(0x80 | (u >> 6 & 0x3f));
      out[n++] = (char)(0x80 | (u & 0x3f));
    }
  }
  out[n] = 0;
}

// One table: the header at `lba`, then its entries. VX_OK, or why it fails.
static vx_status gpt_table(vx_gpt *g, uint64_t lba, vx_gpt_read_fn *read, void *ctx) {
  uint8_t *h = g->buf; // the header first, then the entries, in the same buffer
  if (g->sector > sizeof g->buf || !read(ctx, lba, 1, h)) return VX_ERR_IO;
  static const uint8_t SIGNATURE[8] = {'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T'};
  uint32_t size = gpt_u32(h + 12);
  if (memcmp(h, SIGNATURE, 8) != 0 || gpt_u32(h + 8) != 0x00010000 || size < 92 || size > g->sector)
    return VX_ERR_INVALID;
  uint32_t crc = gpt_u32(h + 16);
  h[16] = h[17] = h[18] = h[19] = 0;
  if (gpt_crc32(h, size) != crc) return VX_ERR_INVALID;
  uint64_t my = gpt_u64(h + 24), first = gpt_u64(h + 40), last = gpt_u64(h + 48), entries = gpt_u64(h + 72);
  uint32_t count = gpt_u32(h + 80), esize = gpt_u32(h + 84), ecrc = gpt_u32(h + 88);
  if (my != lba || first > last || last >= g->sectors || first < 2) return VX_ERR_INVALID;
  if (esize < 128 || esize % 128 || !count || (uint64_t)count * esize > sizeof g->buf) return VX_ERR_INVALID;
  uint64_t bytes = (uint64_t)count * esize, nsect = (bytes + g->sector - 1) / g->sector;
  // The array lies inside the disk, and outside the usable range (it is metadata).
  if (entries < 2 || entries >= g->sectors || nsect > g->sectors - entries) return VX_ERR_INVALID;
  if (!(entries + nsect <= first || entries > last)) return VX_ERR_INVALID;
  uint8_t disk_guid[16];
  memcpy(disk_guid, h + 56, 16);
  if (!read(ctx, entries, (uint32_t)nsect, g->buf)) return VX_ERR_IO;
  if (gpt_crc32(g->buf, bytes) != ecrc) return VX_ERR_INVALID;

  g->count = 0;
  for (uint32_t i = 0; i < count; i++) {
    const uint8_t *e = g->buf + (size_t)i * esize;
    bool used = false;
    for (int k = 0; k < 16 && !used; k++) used = e[k] != 0;
    if (!used) continue;
    if (g->count == VX_GPT_MAX) return VX_ERR_RANGE;
    vx_gpt_part *p = &g->parts[g->count];
    memcpy(p->type, e, 16);
    memcpy(p->guid, e + 16, 16);
    p->first = gpt_u64(e + 32);
    p->last = gpt_u64(e + 40);
    p->attributes = gpt_u64(e + 48);
    gpt_name(e + 56, p->name);
    if (p->first > p->last || p->first < first || p->last > last) return VX_ERR_INVALID;
    for (uint32_t k = 0; k < g->count; k++) // no two overlap
      if (p->first <= g->parts[k].last && g->parts[k].first <= p->last) return VX_ERR_INVALID;
    g->count++;
  }
  memcpy(g->disk_guid, disk_guid, 16);
  g->first_usable = first;
  g->last_usable = last;
  return VX_OK;
}

// Reads the table of a disk of `sectors` sectors of `sector` bytes: the
// primary, or the backup if the primary fails. VX_OK, INVALID if neither
// passes, IO if neither could be read.
[[maybe_unused]] static vx_status vx_gpt_read(vx_gpt *g, uint32_t sector, uint64_t sectors,
                                              vx_gpt_read_fn *read, void *ctx) {
  g->sector = sector;
  g->sectors = sectors;
  g->count = 0;
  g->backup = false;
  if (sector < 512 || sector > 4096 || sector & (sector - 1) || sectors < 68) return VX_ERR_INVALID;
  vx_status st = gpt_table(g, 1, read, ctx);
  if (st == VX_OK) return VX_OK;
  vx_status back = gpt_table(g, sectors - 1, read, ctx);
  if (back != VX_OK) {
    g->count = 0;
    return st == VX_ERR_IO && back == VX_ERR_IO ? VX_ERR_IO : VX_ERR_INVALID;
  }
  g->backup = true;
  return VX_OK;
}

static int gpt_hex(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// A GUID as text (C12A7328-F81F-11D2-BA4B-00A0C93EC93B) as the disk stores
// it: the first three fields little-endian, the rest as written. False if the
// text is not one.
[[maybe_unused]] static bool vx_gpt_guid(const char *text, size_t len, uint8_t out[16]) {
  static const uint8_t ORDER[16] = {3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15};
  uint8_t bytes[16];
  size_t n = 0;
  for (size_t i = 0; i < len; i++) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (text[i] != '-') return false;
      continue;
    }
    if (n == 16 || i + 1 >= len) return false;
    int hi = gpt_hex(text[i]), lo = gpt_hex(text[i + 1]);
    if (hi < 0 || lo < 0) return false;
    bytes[n++] = (uint8_t)(hi << 4 | lo);
    i++;
  }
  if (n != 16 || len != 36) return false;
  for (int i = 0; i < 16; i++) out[i] = bytes[ORDER[i]];
  return true;
}

// --- Writing (M5 step 9c: install) ---

static constexpr size_t GPT_WRITE_ENTRIES = (size_t)128 * 128; // 128 entries of 128 bytes

// Writes `count` sectors from buf at `lba`; false if it cannot.
typedef bool vx_gpt_write_fn(void *ctx, uint64_t lba, uint32_t count, const uint8_t *buf);

static void gpt_put32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static void gpt_put64(uint8_t *p, uint64_t v) {
  gpt_put32(p, (uint32_t)v), gpt_put32(p + 4, (uint32_t)(v >> 32));
}

// A name, UTF-8, as the entry's 36 UTF-16LE units (BMP only; cut at 36).
static void gpt_put_name(uint8_t *p, const char *name) {
  size_t n = 0;
  for (const uint8_t *s = (const uint8_t *)name; *s && n < 36;) {
    uint32_t c = *s++;
    int more = (c >= 0xc0) + (c >= 0xe0) + (c >= 0xf0);
    static const uint8_t lead[4] = {0x7f, 0x1f, 0x0f, 0x07};
    c &= lead[more];
    for (int k = 0; k < more && *s; k++) c = c << 6 | (*s++ & 0x3f);
    if (c > 0xffff) c = 0xfffd;
    p[2 * n] = (uint8_t)c, p[2 * n + 1] = (uint8_t)(c >> 8);
    n++;
  }
}

// One header, for a table at `my` whose copy is at `other` and entries at
// `entries`, into h (a sector).
static void gpt_header(const vx_gpt *g, uint8_t *h, uint64_t my, uint64_t other, uint64_t entries,
                       uint32_t ecrc) {
  memset(h, 0, g->sector);
  for (int i = 0; i < 8; i++) h[i] = (uint8_t)"EFI PART"[i];
  gpt_put32(h + 8, 0x00010000);
  gpt_put32(h + 12, 92);
  gpt_put64(h + 24, my);
  gpt_put64(h + 32, other);
  gpt_put64(h + 40, g->first_usable);
  gpt_put64(h + 48, g->last_usable);
  memcpy(h + 56, g->disk_guid, 16);
  gpt_put64(h + 72, entries);
  gpt_put32(h + 80, 128);
  gpt_put32(h + 84, 128);
  gpt_put32(h + 88, ecrc);
  gpt_put32(h + 16, gpt_crc32(h, 92));
}

// The table g holds (sector, sectors, disk_guid, count and parts) written
// whole: a protective MBR, the primary header and 128 entries at LBA 1 and
// 2, their backups at the disk's end. g's usable range is set from the
// disk's size; a part outside it, or two that overlap, is INVALID and nothing
// is written. g->buf is used for the entries.
[[maybe_unused]] static vx_status vx_gpt_write(vx_gpt *g, vx_gpt_write_fn *write, void *ctx) {
  uint32_t esect = (uint32_t)(GPT_WRITE_ENTRIES / g->sector);
  if (g->sector < 512 || g->sector > 4096 || g->sector & (g->sector - 1) || g->count > 128 ||
      g->sectors < 2 * (2 + (uint64_t)esect) + 1)
    return VX_ERR_INVALID;
  g->first_usable = 2 + esect;
  g->last_usable = g->sectors - 2 - esect;
  for (uint32_t i = 0; i < g->count; i++) {
    const vx_gpt_part *p = &g->parts[i];
    if (p->first > p->last || p->first < g->first_usable || p->last > g->last_usable) return VX_ERR_INVALID;
    for (uint32_t k = 0; k < i; k++)
      if (p->first <= g->parts[k].last && g->parts[k].first <= p->last) return VX_ERR_INVALID;
  }
  uint8_t *e = g->buf;
  memset(e, 0, GPT_WRITE_ENTRIES);
  for (uint32_t i = 0; i < g->count; i++) {
    uint8_t *x = e + (size_t)i * 128;
    memcpy(x, g->parts[i].type, 16);
    memcpy(x + 16, g->parts[i].guid, 16);
    gpt_put64(x + 32, g->parts[i].first);
    gpt_put64(x + 40, g->parts[i].last);
    gpt_put64(x + 48, g->parts[i].attributes);
    gpt_put_name(x + 56, g->parts[i].name);
  }
  uint32_t ecrc = gpt_crc32(e, GPT_WRITE_ENTRIES);
  static uint8_t s[4096];
  // The protective MBR: one partition of type 0xEE over the whole disk (or as much of it as 32 bits hold).
  memset(s, 0, g->sector);
  uint8_t *pe = s + 446;
  pe[1] = 0, pe[2] = 2, pe[4] = 0xee, pe[5] = pe[6] = pe[7] = 0xff;
  gpt_put32(pe + 8, 1);
  gpt_put32(pe + 12, g->sectors - 1 > 0xffffffff ? 0xffffffff : (uint32_t)(g->sectors - 1));
  s[510] = 0x55, s[511] = 0xaa;
  if (!write(ctx, 0, 1, s)) return VX_ERR_IO;
  uint64_t last = g->sectors - 1, backup_entries = last - esect;
  if (!write(ctx, 2, esect, e) || !write(ctx, backup_entries, esect, e)) return VX_ERR_IO;
  gpt_header(g, s, last, 1, backup_entries,
             ecrc); // the backup, then the primary: a torn write leaves one whole
  if (!write(ctx, last, 1, s)) return VX_ERR_IO;
  gpt_header(g, s, 1, last, 2, ecrc);
  return write(ctx, 1, 1, s) ? VX_OK : VX_ERR_IO;
}
