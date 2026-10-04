// vx-fat: FAT12, FAT16 and FAT32 (docs/11 §11), for dosfs: the boot
// sector's BPB, the FAT's cluster chains, directories with long names, and
// files' bytes. After 9front's dossrv, reimplemented in C23. Pure code over
// one callback, a device that reads sectors, so it builds for the host's
// tests as well as for dosfs. Read-only so far (M5 step 8a); writing comes
// with step 8b.
//
// A node is a directory entry's place: the first cluster of the directory
// it is in (0 for FAT12's and FAT16's fixed root) and the index of its short
// entry there. That is unique and lasts as long as the entry does, and is
// enough to find the entry's long name (the slots before it) and its parent
// (the directory's ".." entry, then the entry in the grandparent naming the
// directory). The root has no entry: it is FAT_ROOT.
//
// Names: a long name (UTF-16 in the format) is given as UTF-8; an entry with
// none gets its 8.3 name, lower-cased where Windows NT's flags say. Short
// names' bytes past ASCII are in a DOS code page that the volume does not
// name, and come out as U+FFFD. Lookups ignore ASCII case, as FAT does, and
// match an entry's long name or its 8.3 alias. Times are FAT's local time,
// taken as UTC: there are no time zones yet.

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

typedef struct fat_dev {
  void *ctx;
  // len bytes from off: both multiples of 512 (the boot sector), else of the
  // volume's sector size.
  bool (*read)(void *ctx, uint64_t off, uint32_t len, uint8_t *buf);
} fat_dev;

enum : uint32_t { FAT_CACHE = 32, FAT_MAX_SECTOR = 4096, FAT_NAME_MAX = 255 * 3 + 1 };
static constexpr uint64_t FAT_ROOT = 1;

enum : uint8_t {
  FAT_READ_ONLY = 0x01,
  FAT_HIDDEN = 0x02,
  FAT_SYSTEM = 0x04,
  FAT_LABEL = 0x08,
  FAT_DIRECTORY = 0x10,
  FAT_ARCHIVE = 0x20,
  FAT_LONG_NAME = 0x0f, // read-only, hidden, system and label: a long name's slot
};

typedef struct fat_vol {
  fat_dev dev;
  uint32_t type; // 12, 16 or 32
  uint32_t bps, spc, cluster_bytes;
  uint32_t fat_start, fat_sectors, nfats;
  uint32_t root_start, root_entries; // FAT12's and FAT16's fixed root
  uint32_t root_cluster;             // FAT32's root directory
  uint32_t data_start;               // cluster 2's first sector
  uint32_t clusters;                 // valid clusters are 2 .. clusters + 1
  uint64_t sectors;
  char label[12]; // the BPB's, trailing spaces cut; empty if NO NAME
  struct {
    uint64_t sector, last;
    bool valid;
    uint8_t data[FAT_MAX_SECTOR];
  } cache[FAT_CACHE];
  uint64_t tick;
} fat_vol;

typedef struct fat_entry {
  uint64_t node;
  uint8_t attr;
  uint32_t cluster;            // the first; 0 for an empty file
  uint32_t size;               // bytes; 0 for a directory
  int64_t mtime, atime, ctime; // seconds since 1970, as UTC
  char name[FAT_NAME_MAX];     // UTF-8, NUL-terminated
  char alias[13];              // the 8.3 name, as stored: "ALONGD~1.TXT"
  // fat_read's place in the chain, kept between reads of the same entry so
  // a file read in order is not walked from its start each time: the
  // at_index-th cluster is at_cluster (0: none yet).
  uint32_t at_cluster;
  uint64_t at_index;
} fat_entry;

// --- Bytes ---

static uint16_t fat_u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t fat_u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

// A sector, through the cache: nullptr if the device fails.
static const uint8_t *fat_sector(fat_vol *v, uint64_t sector) {
  uint32_t victim = 0;
  for (uint32_t i = 0; i < FAT_CACHE; i++) {
    if (v->cache[i].valid && v->cache[i].sector == sector) {
      v->cache[i].last = ++v->tick;
      return v->cache[i].data;
    }
    if (!v->cache[i].valid || v->cache[i].last < v->cache[victim].last) victim = i;
  }
  if (sector >= v->sectors || !v->dev.read(v->dev.ctx, sector * v->bps, v->bps, v->cache[victim].data))
    return nullptr;
  v->cache[victim].sector = sector, v->cache[victim].valid = true, v->cache[victim].last = ++v->tick;
  return v->cache[victim].data;
}

// --- Mounting ---

static bool fat_pow2(uint32_t x) { return x && !(x & (x - 1)); }

// The volume on dev, from its boot sector. INVALID if it is not FAT.
static vx_status fat_mount(fat_vol *v, fat_dev dev) {
  memset(v, 0, sizeof *v);
  v->dev = dev;
  static uint8_t boot[512];
  if (!dev.read(dev.ctx, 0, sizeof boot, boot)) return VX_ERR_IO;
  const uint8_t *b = boot;
  uint32_t bps = fat_u16(b + 11), spc = b[13], reserved = fat_u16(b + 14), nfats = b[16];
  uint32_t root_entries = fat_u16(b + 17), total16 = fat_u16(b + 19), fat16 = fat_u16(b + 22);
  uint32_t total32 = fat_u32(b + 32), fat32 = fat_u32(b + 36);
  if ((b[0] != 0xeb && b[0] != 0xe9) || b[510] != 0x55 || b[511] != 0xaa) return VX_ERR_INVALID;
  if (bps < 512 || bps > FAT_MAX_SECTOR || !fat_pow2(bps) || !fat_pow2(spc) || spc > 128 || !reserved ||
      !nfats)
    return VX_ERR_INVALID;
  uint64_t sectors = total16 ? total16 : total32;
  uint32_t fat_sectors = fat16 ? fat16 : fat32;
  uint32_t root_sectors = (root_entries * 32 + bps - 1) / bps;
  uint64_t data_start = reserved + (uint64_t)nfats * fat_sectors + root_sectors;
  if (!fat_sectors || !sectors || data_start >= sectors) return VX_ERR_INVALID;
  uint64_t clusters = (sectors - data_start) / spc;
  // The type is the cluster count's, as Microsoft's specification has it.
  v->type = 32;
  if (clusters < 65525) v->type = 16;
  if (clusters < 4085) v->type = 12;
  if ((v->type == 32) != (root_entries == 0) || clusters > 0x0fff'fff5) return VX_ERR_INVALID;
  // The FAT must have an entry for every cluster.
  uint64_t entries = (uint64_t)fat_sectors * bps * 8 / v->type;
  if (entries < clusters + 2) return VX_ERR_INVALID;
  v->bps = bps, v->spc = spc, v->cluster_bytes = bps * spc;
  v->fat_start = reserved, v->fat_sectors = fat_sectors, v->nfats = nfats;
  v->root_start = reserved + nfats * fat_sectors, v->root_entries = root_entries;
  v->data_start = (uint32_t)data_start, v->clusters = (uint32_t)clusters, v->sectors = sectors;
  const uint8_t *label = b + 43;
  if (v->type == 32) {
    v->root_cluster = fat_u32(b + 44);
    label = b + 71;
    if (fat_u16(b + 42) != 0 || v->root_cluster < 2 || v->root_cluster > v->clusters + 1)
      return VX_ERR_INVALID;
  }
  if (b[v->type == 32 ? 66 : 38] == 0x29) { // the extended boot signature: the label is there
    memcpy(v->label, label, 11);
    int n = 11;
    while (n > 0 && v->label[n - 1] == ' ') n--;
    v->label[n] = 0;
    if (memcmp(v->label, "NO NAME", 8) == 0) v->label[0] = 0;
  }
  return VX_OK;
}

// --- The FAT ---

static uint64_t fat_cluster_sector(const fat_vol *v, uint32_t c) {
  return v->data_start + (uint64_t)(c - 2) * v->spc;
}

static bool fat_valid(const fat_vol *v, uint32_t c) { return c >= 2 && c <= v->clusters + 1; }

// The FAT's byte at off (from the first FAT's start), or -1.
static int fat_byte(fat_vol *v, uint64_t off) {
  const uint8_t *s = fat_sector(v, v->fat_start + off / v->bps);
  return s ? s[off % v->bps] : -1;
}

// The cluster after c: *next is 0 at the chain's end. IO if the FAT is
// broken there (a free or bad cluster, or one out of range, in a chain).
static vx_status fat_next(fat_vol *v, uint32_t c, uint32_t *next) {
  if (!fat_valid(v, c)) return VX_ERR_IO;
  uint32_t e, end, bad;
  if (v->type == 12) {
    uint64_t off = c + c / 2;
    int lo = fat_byte(v, off), hi = fat_byte(v, off + 1);
    if (lo < 0 || hi < 0) return VX_ERR_IO;
    e = (uint32_t)(lo | hi << 8);
    e = c & 1 ? e >> 4 : e & 0xfff;
    end = 0xff8, bad = 0xff7;
  } else {
    uint64_t off = (uint64_t)c * (v->type / 8);
    const uint8_t *s = fat_sector(v, v->fat_start + off / v->bps); // entries never straddle sectors
    if (!s) return VX_ERR_IO;
    e = v->type == 16 ? fat_u16(s + off % v->bps) : fat_u32(s + off % v->bps) & 0x0fff'ffff;
    end = v->type == 16 ? 0xfff8 : 0x0fff'fff8;
    bad = end - 1;
  }
  if (e >= end) {
    *next = 0;
    return VX_OK;
  }
  if (e == bad || !fat_valid(v, e)) return VX_ERR_IO;
  *next = e;
  return VX_OK;
}

// The chain's k-th cluster from c (0: c itself); *out 0 if the chain ends first.
static vx_status fat_walk(fat_vol *v, uint32_t c, uint64_t k, uint32_t *out) {
  if (k > v->clusters) return VX_ERR_IO; // longer than the volume: a loop
  for (; k && c; k--) {
    vx_status st = fat_next(v, c, &c);
    if (st != VX_OK) return st;
  }
  *out = c;
  return VX_OK;
}

// --- Directories ---

typedef struct fat_iter {
  uint32_t dir;     // its first cluster; 0: the fixed root
  uint32_t cluster; // the one index is in (not the fixed root's)
  uint32_t index;   // the next slot
  uint32_t steps;   // clusters followed, against loops
} fat_iter;

static fat_iter fat_iter_at(const fat_vol *v, uint32_t dir) {
  if (v->type == 32 && dir == 0) dir = v->root_cluster; // ".." naming the root
  return (fat_iter){.dir = dir, .cluster = dir};
}

static uint32_t fat_dir_of(const fat_vol *v, uint64_t node) {
  if (node != FAT_ROOT) return (uint32_t)(node >> 21) & 0x0fff'ffff;
  return v->type == 32 ? v->root_cluster : 0;
}

static uint64_t fat_node(uint32_t dir, uint32_t index) { return 1ull << 62 | (uint64_t)dir << 21 | index; }

// The slot at it->index, and the iterator past it. NOT_FOUND past the end.
static vx_status fat_slot(fat_vol *v, fat_iter *it, const uint8_t **slot) {
  uint64_t off = (uint64_t)it->index * 32;
  uint64_t sector;
  if (it->dir == 0) {
    if (it->index >= v->root_entries) return VX_ERR_NOT_FOUND;
    sector = v->root_start + off / v->bps;
  } else {
    if (it->index >= (1u << 21)) return VX_ERR_NOT_FOUND;
    if (it->index && off % v->cluster_bytes == 0) { // into the next cluster
      if (++it->steps > v->clusters) return VX_ERR_IO;
      vx_status st = fat_next(v, it->cluster, &it->cluster);
      if (st != VX_OK) return st;
    }
    if (!it->cluster) return VX_ERR_NOT_FOUND;
    sector = fat_cluster_sector(v, it->cluster) + off % v->cluster_bytes / v->bps;
  }
  const uint8_t *s = fat_sector(v, sector);
  if (!s) return VX_ERR_IO;
  *slot = s + off % v->bps;
  it->index++;
  return VX_OK;
}

static uint8_t fat_checksum(const uint8_t *short_name) {
  uint8_t sum = 0;
  for (int i = 0; i < 11; i++) sum = (uint8_t)(((sum & 1) << 7) + (sum >> 1) + short_name[i]);
  return sum;
}

// UTF-8 for a code point into out[*n...]; out has room (FAT_NAME_MAX).
static void fat_put_utf8(char *out, size_t *n, uint32_t c) {
  if (c < 0x80) {
    out[(*n)++] = (char)c;
  } else if (c < 0x800) {
    out[(*n)++] = (char)(0xc0 | c >> 6), out[(*n)++] = (char)(0x80 | (c & 0x3f));
  } else if (c < 0x1'0000) {
    out[(*n)++] = (char)(0xe0 | c >> 12), out[(*n)++] = (char)(0x80 | (c >> 6 & 0x3f));
    out[(*n)++] = (char)(0x80 | (c & 0x3f));
  } else {
    out[(*n)++] = (char)(0xf0 | c >> 18), out[(*n)++] = (char)(0x80 | (c >> 12 & 0x3f));
    out[(*n)++] = (char)(0x80 | (c >> 6 & 0x3f)), out[(*n)++] = (char)(0x80 | (c & 0x3f));
  }
}

// FAT's date and time (local, taken as UTC) as seconds since 1970.
static int64_t fat_time(uint16_t date, uint16_t time) {
  if (!date) return 0;
  int64_t y = 1980 + (date >> 9);
  uint32_t m = date >> 5 & 15, d = date & 31;
  if (m < 1 || m > 12 || d < 1) return 0;
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  uint32_t yoe = (uint32_t)(y - era * 400);
  uint32_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  uint32_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  int64_t days = era * 146097 + (int64_t)doe - 719468;
  return days * 86400 + (int64_t)(time >> 11) * 3600 + (int64_t)(time >> 5 & 63) * 60 +
         (int64_t)(time & 31) * 2;
}

// The 8.3 name as a file name: "README.TXT", lower-cased where NT's flags say.
static void fat_short_name(const uint8_t *e, char *out, bool apply_case, bool as_alias) {
  size_t n = 0;
  for (int part = 0; part < 2; part++) {
    int from = part ? 8 : 0, len = part ? 3 : 8;
    while (len > 0 && e[from + len - 1] == ' ') len--;
    if (part && len) out[n++] = '.';
    bool lower = apply_case && (e[12] & (part ? 0x10 : 0x08));
    for (int i = 0; i < len; i++) {
      uint8_t c = e[from + i];
      if (i == 0 && !part && c == 0x05) c = 0xe5; // a name that starts with 0xe5
      if (as_alias) {
        out[n++] = (char)c;
      } else if (c >= 0x80) {
        fat_put_utf8(out, &n, 0xfffd);
      } else {
        out[n++] = (char)(lower && c >= 'A' && c <= 'Z' ? c + 32 : c);
      }
    }
  }
  out[n] = 0;
}

// The next entry in the directory, its long name assembled: NOT_FOUND at
// its end. Deleted entries, the volume label, "." and ".." are skipped; so
// are long-name slots whose sequence or checksum do not hold.
static vx_status fat_dir_next(fat_vol *v, fat_iter *it, fat_entry *e) {
  uint16_t units[260];
  int expect = 0, count = 0; // the next long-name slot's sequence number; the name's slots
  uint8_t sum = 0;
  for (;;) {
    const uint8_t *s;
    vx_status st = fat_slot(v, it, &s);
    if (st != VX_OK) return st;
    if (s[0] == 0x00) return VX_ERR_NOT_FOUND; // the end
    if (s[0] == 0xe5) {
      expect = 0;
      continue;
    }
    if ((s[11] & 0x3f) == FAT_LONG_NAME) {
      int seq = s[0] & 0x1f;
      if (s[0] & 0x40) { // the name's last part, its first slot
        if (seq < 1 || seq > 20) {
          expect = 0;
          continue;
        }
        count = seq, sum = s[13];
      } else if (seq != expect || s[13] != sum) {
        expect = 0;
        continue;
      }
      static const uint8_t at[13] = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};
      for (int i = 0; i < 13; i++) units[(seq - 1) * 13 + i] = fat_u16(s + at[i]);
      expect = seq - 1;
      continue;
    }
    bool have_long = expect == 0 && count && fat_checksum(s) == sum;
    expect = 0;
    int n = count;
    count = 0;
    if ((s[11] & FAT_LABEL) && !(s[11] & FAT_DIRECTORY)) continue; // the volume label
    if (s[0] == '.' && (s[1] == ' ' || (s[1] == '.' && s[2] == ' '))) continue;
    *e = (fat_entry){.node = fat_node(it->dir, it->index - 1),
                     .attr = s[11],
                     .cluster = (v->type == 32 ? (uint32_t)fat_u16(s + 20) << 16 : 0) | fat_u16(s + 26),
                     .size = s[11] & FAT_DIRECTORY ? 0 : fat_u32(s + 28),
                     .mtime = fat_time(fat_u16(s + 24), fat_u16(s + 22)),
                     .atime = fat_time(fat_u16(s + 18), 0),
                     .ctime = fat_time(fat_u16(s + 16), fat_u16(s + 14))};
    fat_short_name(s, e->alias, false, true);
    size_t len = 0;
    if (have_long) {
      for (int i = 0; i < n * 13 && units[i] != 0 && units[i] != 0xffff; i++) {
        uint32_t c = units[i];
        if (c >= 0xd800 && c < 0xdc00 && i + 1 < n * 13 && units[i + 1] >= 0xdc00 && units[i + 1] < 0xe000)
          c = 0x1'0000 + ((c - 0xd800) << 10) + (units[++i] - 0xdc00);
        else if (c >= 0xd800 && c < 0xe000)
          c = 0xfffd; // a lone surrogate
        if (c == '/' || c == 0) c = 0xfffd;
        fat_put_utf8(e->name, &len, c);
      }
      e->name[len] = 0;
    }
    if (!len) fat_short_name(s, e->name, true, false);
    return VX_OK;
  }
}

static bool fat_same_name(const char *a, const char *b, size_t blen) {
  size_t i = 0;
  for (; i < blen && a[i]; i++) {
    char x = a[i], y = b[i];
    if (x >= 'a' && x <= 'z') x = (char)(x - 32);
    if (y >= 'a' && y <= 'z') y = (char)(y - 32);
    if (x != y) return false;
  }
  return i == blen && !a[i];
}

// The root, as an entry.
static void fat_root_entry(const fat_vol *v, fat_entry *e) {
  *e = (fat_entry){.node = FAT_ROOT, .attr = FAT_DIRECTORY, .cluster = v->type == 32 ? v->root_cluster : 0};
  e->name[0] = '/';
}

// An iterator over directory d's entries, for fat_dir_next.
static vx_status fat_open_dir(const fat_vol *v, const fat_entry *d, fat_iter *it) {
  if (!(d->attr & FAT_DIRECTORY)) return VX_ERR_INVALID;
  *it = fat_iter_at(v, d->node == FAT_ROOT ? fat_dir_of(v, FAT_ROOT) : d->cluster);
  return it->dir || d->node == FAT_ROOT ? VX_OK : VX_ERR_IO; // a directory with no cluster
}

// The entry named name in directory d (an entry with FAT_DIRECTORY, or the root's).
static vx_status fat_lookup(fat_vol *v, const fat_entry *d, const char *name, size_t len, fat_entry *e) {
  fat_iter it;
  vx_status st = fat_open_dir(v, d, &it);
  if (st != VX_OK) return st;
  while ((st = fat_dir_next(v, &it, e)) == VX_OK)
    if (fat_same_name(e->name, name, len) || fat_same_name(e->alias, name, len)) return VX_OK;
  return st;
}

// The entry for a node.
static vx_status fat_get(fat_vol *v, uint64_t node, fat_entry *e) {
  if (node == FAT_ROOT) {
    fat_root_entry(v, e);
    return VX_OK;
  }
  if (!(node >> 62)) return VX_ERR_NOT_FOUND;
  uint32_t dir = fat_dir_of(v, node);
  fat_iter it = {.dir = dir, .cluster = dir};
  vx_status st;
  while ((st = fat_dir_next(v, &it, e)) == VX_OK)
    if (e->node == node)
      return VX_OK;
    else if (e->node > node)
      break; // past it: the entry is gone
  return st == VX_OK || st == VX_ERR_NOT_FOUND ? VX_ERR_NOT_FOUND : st;
}

// The directory node holding a node: the root, or the entry, in its own
// parent, naming the directory the node is in.
static vx_status fat_parent(fat_vol *v, uint64_t node, uint64_t *parent) {
  uint32_t dir = fat_dir_of(v, node);
  if (node == FAT_ROOT || dir == fat_dir_of(v, FAT_ROOT)) {
    *parent = FAT_ROOT;
    return VX_OK;
  }
  // The directory's ".." (its second slot) names the grandparent's cluster.
  fat_iter it = {.dir = dir, .cluster = dir, .index = 1};
  const uint8_t *s;
  vx_status st = fat_slot(v, &it, &s);
  if (st != VX_OK) return st == VX_ERR_NOT_FOUND ? VX_ERR_IO : st;
  if (s[0] != '.' || s[1] != '.') return VX_ERR_IO;
  uint32_t up = (v->type == 32 ? (uint32_t)fat_u16(s + 20) << 16 : 0) | fat_u16(s + 26);
  fat_iter g = fat_iter_at(v, up);
  fat_entry e;
  while ((st = fat_dir_next(v, &g, &e)) == VX_OK)
    if ((e.attr & FAT_DIRECTORY) && e.cluster == dir) {
      *parent = e.node;
      return VX_OK;
    }
  return st == VX_ERR_NOT_FOUND ? VX_ERR_IO : st;
}

// --- Files ---

// Up to *count bytes of a file from offset into buf; *count, what was read
// (0 at or past the end). f's place in its chain is kept, for the next read.
static vx_status fat_read(fat_vol *v, fat_entry *f, uint64_t offset, uint8_t *buf, uint32_t *count) {
  if (f->attr & FAT_DIRECTORY) return VX_ERR_INVALID;
  if (offset >= f->size) {
    *count = 0;
    return VX_OK;
  }
  if (*count > f->size - offset) *count = (uint32_t)(f->size - offset);
  uint32_t c;
  uint64_t index = offset / v->cluster_bytes;
  bool ahead = f->at_cluster && f->at_index <= index;
  vx_status st = fat_walk(v, ahead ? f->at_cluster : f->cluster, ahead ? index - f->at_index : index, &c);
  for (uint32_t done = 0; st == VX_OK && done < *count;) {
    if (!c) return VX_ERR_IO; // the chain is shorter than the file
    uint32_t in = (uint32_t)(offset % v->cluster_bytes);
    uint64_t sector = fat_cluster_sector(v, c) + in / v->bps;
    uint32_t at = in % v->bps, n = v->bps - at;
    if (n > *count - done) n = *count - done;
    if (at == 0 && n == v->bps) { // whole sectors, as many as the cluster has: past the cache
      uint32_t run = (v->cluster_bytes - in) / v->bps, want = (*count - done) / v->bps;
      if (run > want) run = want;
      if (!v->dev.read(v->dev.ctx, sector * v->bps, run * v->bps, buf + done)) return VX_ERR_IO;
      n = run * v->bps;
    } else {
      const uint8_t *s = fat_sector(v, sector);
      if (!s) return VX_ERR_IO;
      memcpy(buf + done, s + at, n);
    }
    f->at_cluster = c, f->at_index = index;
    done += n, offset += n;
    if (offset % v->cluster_bytes == 0 && done < *count) {
      st = fat_next(v, c, &c);
      index++;
    }
  }
  return st;
}
