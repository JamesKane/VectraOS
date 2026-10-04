// vx-fat: FAT12, FAT16 and FAT32 (docs/11 §11), for dosfs: the boot
// sector's BPB, the FAT's cluster chains, directories with long names, and
// files' bytes; and writing them (M5 step 8b). After 9front's dossrv,
// reimplemented in C23. Pure code over a device's callbacks, so it builds
// for the host's tests as well as for dosfs.
//
// Writes go through to the device as they are made (the cache is
// write-through), in an order that leaves a volume a crash cuts short with,
// at worst, lost clusters, never one file's clusters in another: a file's
// clusters are taken in the FAT before its data is written and before its
// directory entry names them or its new size; a removed entry is marked
// free before its clusters are. Both FATs are written, and FAT32's FSInfo
// (its free count and next free cluster) at fat_flush.
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
  bool (*write)(void *ctx, uint64_t off, uint32_t len, const uint8_t *buf); // nullptr: read-only
  bool (*flush)(void *ctx);                                                 // what was written is durable
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
  char label[12];                 // the BPB's, trailing spaces cut; empty if NO NAME
  int64_t now;                    // the time writes stamp, seconds since 1970: the caller's to set
  uint32_t free_hint, free_count; // where to look for a free cluster; how many (FSInfo's on FAT32)
  uint32_t fsinfo_sector;         // FAT32's FSInfo, or 0
  bool fsinfo_dirty;
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

[[maybe_unused]] static uint16_t fat_u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
[[maybe_unused]] static uint32_t fat_u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

// A sector, through the cache: nullptr if the device fails.
[[maybe_unused]] static const uint8_t *fat_sector(fat_vol *v, uint64_t sector) {
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

[[maybe_unused]] static bool fat_pow2(uint32_t x) { return x && !(x & (x - 1)); }

// The volume on dev, from its boot sector. INVALID if it is not FAT.
[[maybe_unused]] static vx_status fat_mount(fat_vol *v, fat_dev dev) {
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
  v->free_hint = 2, v->free_count = UINT32_MAX; // not known until counted
  if (v->type == 32 && fat_u16(b + 48) && fat_u16(b + 48) < reserved) v->fsinfo_sector = fat_u16(b + 48);
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

[[maybe_unused]] static uint64_t fat_cluster_sector(const fat_vol *v, uint32_t c) {
  return v->data_start + (uint64_t)(c - 2) * v->spc;
}

[[maybe_unused]] static bool fat_valid(const fat_vol *v, uint32_t c) {
  return c >= 2 && c <= v->clusters + 1;
}

// The FAT's byte at off (from the first FAT's start), or -1.
[[maybe_unused]] static int fat_byte(fat_vol *v, uint64_t off) {
  const uint8_t *s = fat_sector(v, v->fat_start + off / v->bps);
  return s ? s[off % v->bps] : -1;
}

// The first FAT's entry for cluster c, as it is: 0 free, an end or bad
// mark, or the next cluster.
[[maybe_unused]] static vx_status fat_raw(fat_vol *v, uint32_t c, uint32_t *e) {
  if (v->type == 12) {
    uint64_t off = c + c / 2;
    int lo = fat_byte(v, off), hi = fat_byte(v, off + 1);
    if (lo < 0 || hi < 0) return VX_ERR_IO;
    *e = (uint32_t)(lo | hi << 8);
    *e = c & 1 ? *e >> 4 : *e & 0xfff;
    return VX_OK;
  }
  uint64_t off = (uint64_t)c * (v->type / 8);
  const uint8_t *s = fat_sector(v, v->fat_start + off / v->bps); // entries never straddle sectors
  if (!s) return VX_ERR_IO;
  *e = v->type == 16 ? fat_u16(s + off % v->bps) : fat_u32(s + off % v->bps) & 0x0fff'ffff;
  return VX_OK;
}

[[maybe_unused]] static uint32_t fat_end_mark(const fat_vol *v) {
  if (v->type == 12) return 0xff8;
  return v->type == 16 ? 0xfff8 : 0x0fff'fff8;
}

// The cluster after c: *next is 0 at the chain's end. IO if the FAT is
// broken there (a free or bad cluster, or one out of range, in a chain).
[[maybe_unused]] static vx_status fat_next(fat_vol *v, uint32_t c, uint32_t *next) {
  if (!fat_valid(v, c)) return VX_ERR_IO;
  uint32_t e, end = fat_end_mark(v), bad = end - 1;
  vx_status st = fat_raw(v, c, &e);
  if (st != VX_OK) return st;
  if (e >= end) {
    *next = 0;
    return VX_OK;
  }
  if (e == bad || !fat_valid(v, e)) return VX_ERR_IO;
  *next = e;
  return VX_OK;
}

// The chain's k-th cluster from c (0: c itself); *out 0 if the chain ends first.
[[maybe_unused]] static vx_status fat_walk(fat_vol *v, uint32_t c, uint64_t k, uint32_t *out) {
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

[[maybe_unused]] static fat_iter fat_iter_at(const fat_vol *v, uint32_t dir) {
  if (v->type == 32 && dir == 0) dir = v->root_cluster; // ".." naming the root
  return (fat_iter){.dir = dir, .cluster = dir};
}

[[maybe_unused]] static uint32_t fat_dir_of(const fat_vol *v, uint64_t node) {
  if (node != FAT_ROOT) return (uint32_t)(node >> 21) & 0x0fff'ffff;
  return v->type == 32 ? v->root_cluster : 0;
}

[[maybe_unused]] static uint64_t fat_node(uint32_t dir, uint32_t index) {
  return 1ull << 62 | (uint64_t)dir << 21 | index;
}

// The slot at it->index, and the iterator past it. NOT_FOUND past the end.
[[maybe_unused]] static vx_status fat_slot(fat_vol *v, fat_iter *it, const uint8_t **slot) {
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

[[maybe_unused]] static uint8_t fat_checksum(const uint8_t *short_name) {
  uint8_t sum = 0;
  for (int i = 0; i < 11; i++) sum = (uint8_t)(((sum & 1) << 7) + (sum >> 1) + short_name[i]);
  return sum;
}

// UTF-8 for a code point into out[*n...]; out has room (FAT_NAME_MAX).
[[maybe_unused]] static void fat_put_utf8(char *out, size_t *n, uint32_t c) {
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
[[maybe_unused]] static int64_t fat_time(uint16_t date, uint16_t time) {
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
[[maybe_unused]] static void fat_short_name(const uint8_t *e, char *out, bool apply_case, bool as_alias) {
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
[[maybe_unused]] static vx_status fat_dir_next(fat_vol *v, fat_iter *it, fat_entry *e) {
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

[[maybe_unused]] static bool fat_same_name(const char *a, const char *b, size_t blen) {
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
[[maybe_unused]] static void fat_root_entry(const fat_vol *v, fat_entry *e) {
  *e = (fat_entry){.node = FAT_ROOT, .attr = FAT_DIRECTORY, .cluster = v->type == 32 ? v->root_cluster : 0};
  e->name[0] = '/';
}

// An iterator over directory d's entries, for fat_dir_next.
[[maybe_unused]] static vx_status fat_open_dir(const fat_vol *v, const fat_entry *d, fat_iter *it) {
  if (!(d->attr & FAT_DIRECTORY)) return VX_ERR_INVALID;
  *it = fat_iter_at(v, d->node == FAT_ROOT ? fat_dir_of(v, FAT_ROOT) : d->cluster);
  return it->dir || d->node == FAT_ROOT ? VX_OK : VX_ERR_IO; // a directory with no cluster
}

// The entry named name in directory d (an entry with FAT_DIRECTORY, or the root's).
[[maybe_unused]] static vx_status fat_lookup(fat_vol *v, const fat_entry *d, const char *name, size_t len,
                                             fat_entry *e) {
  fat_iter it;
  vx_status st = fat_open_dir(v, d, &it);
  if (st != VX_OK) return st;
  while ((st = fat_dir_next(v, &it, e)) == VX_OK)
    if (fat_same_name(e->name, name, len) || fat_same_name(e->alias, name, len)) return VX_OK;
  return st;
}

// The entry for a node.
[[maybe_unused]] static vx_status fat_get(fat_vol *v, uint64_t node, fat_entry *e) {
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
[[maybe_unused]] static vx_status fat_parent(fat_vol *v, uint64_t node, uint64_t *parent) {
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
[[maybe_unused]] static vx_status fat_read(fat_vol *v, fat_entry *f, uint64_t offset, uint8_t *buf,
                                           uint32_t *count) {
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

// --- Writing (M5 step 8b) ---

// Sectors written: to the device, and to their cached copies.
[[maybe_unused]] static bool fat_store(fat_vol *v, uint64_t sector, uint32_t count, const uint8_t *data) {
  if (!v->dev.write || sector + count > v->sectors) return false;
  if (!v->dev.write(v->dev.ctx, sector * v->bps, count * v->bps, data)) return false;
  for (uint32_t i = 0; i < FAT_CACHE; i++)
    if (v->cache[i].valid && v->cache[i].sector >= sector && v->cache[i].sector < sector + count)
      memcpy(v->cache[i].data, data + (v->cache[i].sector - sector) * v->bps, v->bps);
  return true;
}

// A cached sector to change; fat_store it after.
[[maybe_unused]] static uint8_t *fat_sector_rw(fat_vol *v, uint64_t sector) {
  return (uint8_t *)fat_sector(v, sector);
}

[[maybe_unused]] static void fat_put16(uint8_t *p, uint32_t x) {
  p[0] = (uint8_t)x, p[1] = (uint8_t)(x >> 8);
}
[[maybe_unused]] static void fat_put32(uint8_t *p, uint32_t x) { fat_put16(p, x), fat_put16(p + 2, x >> 16); }

// A byte of FAT copy f, changed: its sector stored.
[[maybe_unused]] static bool fat_set_byte(fat_vol *v, uint32_t f, uint64_t off, uint8_t keep, uint8_t value) {
  uint64_t sector = v->fat_start + (uint64_t)f * v->fat_sectors + off / v->bps;
  uint8_t *s = fat_sector_rw(v, sector);
  if (!s) return false;
  s[off % v->bps] = (uint8_t)((s[off % v->bps] & keep) | value);
  return fat_store(v, sector, 1, s);
}

// Cluster c's entry set to value, in every FAT.
[[maybe_unused]] static vx_status fat_set(fat_vol *v, uint32_t c, uint32_t value) {
  if (!fat_valid(v, c)) return VX_ERR_IO;
  for (uint32_t f = 0; f < v->nfats; f++) {
    bool ok;
    if (v->type == 12) {
      uint64_t off = c + c / 2;
      if (c & 1)
        ok = fat_set_byte(v, f, off, 0x0f, (uint8_t)(value << 4)) &&
             fat_set_byte(v, f, off + 1, 0, (uint8_t)(value >> 4));
      else
        ok = fat_set_byte(v, f, off, 0, (uint8_t)value) &&
             fat_set_byte(v, f, off + 1, 0xf0, (uint8_t)(value >> 8 & 15));
    } else {
      uint64_t off = (uint64_t)c * (v->type / 8);
      uint64_t sector = v->fat_start + (uint64_t)f * v->fat_sectors + off / v->bps;
      uint8_t *s = fat_sector_rw(v, sector);
      if (!s) return VX_ERR_IO;
      if (v->type == 16)
        fat_put16(s + off % v->bps, value);
      else
        fat_put32(s + off % v->bps, (fat_u32(s + off % v->bps) & 0xf000'0000) | (value & 0x0fff'ffff));
      ok = fat_store(v, sector, 1, s);
    }
    if (!ok) return VX_ERR_IO;
  }
  return VX_OK;
}

// The free clusters, counted once (FAT32's FSInfo may say, but is only a hint).
[[maybe_unused]] static vx_status fat_count_free(fat_vol *v) {
  if (v->free_count != UINT32_MAX) return VX_OK;
  uint32_t n = 0;
  for (uint32_t c = 2; c <= v->clusters + 1; c++) {
    uint32_t e;
    vx_status st = fat_raw(v, c, &e);
    if (st != VX_OK) return st;
    n += e == 0;
  }
  v->free_count = n;
  return VX_OK;
}

// Zeros over a cluster's sectors.
[[maybe_unused]] static vx_status fat_zero_cluster(fat_vol *v, uint32_t c) {
  static const uint8_t zeros[FAT_MAX_SECTOR];
  for (uint32_t i = 0; i < v->spc; i++)
    if (!fat_store(v, fat_cluster_sector(v, c) + i, 1, zeros)) return VX_ERR_IO;
  return VX_OK;
}

// A free cluster, marked as a chain's end, and linked after prev (0: none).
[[maybe_unused]] static vx_status fat_alloc(fat_vol *v, uint32_t prev, uint32_t *out) {
  vx_status st = fat_count_free(v);
  if (st != VX_OK) return st;
  if (!v->free_count) return VX_ERR_NO_SPACE;
  uint32_t c = fat_valid(v, v->free_hint) ? v->free_hint : 2;
  for (uint32_t tried = 0; tried < v->clusters; tried++, c = c == v->clusters + 1 ? 2 : c + 1) {
    uint32_t e;
    if ((st = fat_raw(v, c, &e)) != VX_OK) return st;
    if (e) continue;
    if ((st = fat_set(v, c, 0x0fff'ffff)) != VX_OK) return st; // masked to the FAT's width
    if (prev && (st = fat_set(v, prev, c)) != VX_OK) return st;
    v->free_count--, v->free_hint = c == v->clusters + 1 ? 2 : c + 1, v->fsinfo_dirty = true;
    *out = c;
    return VX_OK;
  }
  return VX_ERR_NO_SPACE; // the count was wrong
}

// The chain from c freed.
[[maybe_unused]] static vx_status fat_free_chain(fat_vol *v, uint32_t c) {
  for (uint32_t steps = 0; c; steps++) {
    if (steps > v->clusters) return VX_ERR_IO;
    uint32_t next;
    vx_status st = fat_next(v, c, &next);
    if (st == VX_OK) st = fat_set(v, c, 0);
    if (st != VX_OK) return st;
    if (v->free_count != UINT32_MAX) v->free_count++;
    v->fsinfo_dirty = true;
    c = next;
  }
  return VX_OK;
}

// FAT's date and time for seconds since 1970 (as UTC): date, then time.
[[maybe_unused]] static void fat_stamp(int64_t t, uint16_t *date, uint16_t *time) {
  if (t < 315'532'800) t = 315'532'800; // FAT's epoch, 1980-01-01
  int64_t days = t / 86400 + 719468, secs = t % 86400;
  int64_t era = days / 146097;
  uint32_t doe = (uint32_t)(days - era * 146097);
  uint32_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  uint32_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153;
  uint32_t d = doy - (153 * mp + 2) / 5 + 1, m = mp < 10 ? mp + 3 : mp - 9;
  int64_t y = (int64_t)yoe + era * 400 + (m <= 2);
  if (y > 2107) y = 2107;
  *date = (uint16_t)((y - 1980) << 9 | m << 5 | d);
  *time = (uint16_t)(secs / 3600 << 11 | secs % 3600 / 60 << 5 | secs % 60 / 2);
}

// The sector and offset of slot index in directory dir (0: the fixed root).
[[maybe_unused]] static vx_status fat_slot_place(fat_vol *v, uint32_t dir, uint32_t index, uint64_t *sector,
                                                 uint32_t *at) {
  uint64_t off = (uint64_t)index * 32;
  if (dir == 0) {
    if (index >= v->root_entries) return VX_ERR_NOT_FOUND;
    *sector = v->root_start + off / v->bps;
  } else {
    uint32_t c;
    vx_status st = fat_walk(v, dir, off / v->cluster_bytes, &c);
    if (st != VX_OK) return st;
    if (!c) return VX_ERR_NOT_FOUND;
    *sector = fat_cluster_sector(v, c) + off % v->cluster_bytes / v->bps;
  }
  *at = (uint32_t)(off % v->bps);
  return VX_OK;
}

// A slot's 32 bytes written.
[[maybe_unused]] static vx_status fat_put_slot(fat_vol *v, uint32_t dir, uint32_t index,
                                               const uint8_t slot[32]) {
  uint64_t sector;
  uint32_t at;
  vx_status st = fat_slot_place(v, dir, index, &sector, &at);
  if (st != VX_OK) return st;
  uint8_t *s = fat_sector_rw(v, sector);
  if (!s) return VX_ERR_IO;
  memcpy(s + at, slot, 32);
  return fat_store(v, sector, 1, s) ? VX_OK : VX_ERR_IO;
}

[[maybe_unused]] static vx_status fat_get_slot(fat_vol *v, uint32_t dir, uint32_t index, uint8_t slot[32]) {
  uint64_t sector;
  uint32_t at;
  vx_status st = fat_slot_place(v, dir, index, &sector, &at);
  if (st != VX_OK) return st;
  const uint8_t *s = fat_sector(v, sector);
  if (!s) return VX_ERR_IO;
  memcpy(slot, s + at, 32);
  return VX_OK;
}

[[maybe_unused]] static uint32_t fat_index_of(uint64_t node) { return (uint32_t)(node & ((1u << 21) - 1)); }

// An entry's cluster, size, attributes and times, written to its short slot.
[[maybe_unused]] static vx_status fat_put_entry(fat_vol *v, const fat_entry *e) {
  if (e->node == FAT_ROOT) return VX_OK; // the root has no entry
  uint32_t dir = fat_dir_of(v, e->node), index = fat_index_of(e->node);
  uint8_t s[32];
  vx_status st = fat_get_slot(v, dir, index, s);
  if (st != VX_OK) return st;
  uint16_t date, time;
  s[11] = e->attr;
  fat_put16(s + 20, v->type == 32 ? e->cluster >> 16 : 0);
  fat_put16(s + 26, e->cluster & 0xffff);
  fat_put32(s + 28, e->attr & FAT_DIRECTORY ? 0 : e->size);
  fat_stamp(e->mtime, &date, &time);
  fat_put16(s + 22, time), fat_put16(s + 24, date);
  fat_stamp(e->atime ? e->atime : e->mtime, &date, &time);
  fat_put16(s + 18, date);
  return fat_put_slot(v, dir, index, s);
}

// The cluster count a file of size bytes has.
[[maybe_unused]] static uint64_t fat_clusters_for(const fat_vol *v, uint64_t size) {
  return (size + v->cluster_bytes - 1) / v->cluster_bytes;
}

// The file's chain made at least want clusters long.
[[maybe_unused]] static vx_status fat_grow(fat_vol *v, fat_entry *f, uint64_t want) {
  uint64_t have = fat_clusters_for(v, f->size);
  vx_status st = VX_OK;
  uint32_t last = 0;
  if (have) {
    bool ahead = f->at_cluster && f->at_index < have;
    st = fat_walk(v, ahead ? f->at_cluster : f->cluster, ahead ? have - 1 - f->at_index : have - 1, &last);
    if (st == VX_OK && !last) st = VX_ERR_IO; // shorter than its size
  }
  for (; st == VX_OK && have < want; have++) {
    uint32_t c;
    st = fat_alloc(v, last, &c);
    if (st != VX_OK) break;
    if (!f->cluster) f->cluster = c;
    f->at_cluster = c, f->at_index = have;
    last = c;
  }
  return st;
}

// Bytes written into the file's clusters at offset (which it has).
[[maybe_unused]] static vx_status fat_put_bytes(fat_vol *v, fat_entry *f, uint64_t offset, const uint8_t *buf,
                                                uint32_t count) {
  uint64_t index = offset / v->cluster_bytes;
  uint32_t c;
  bool ahead = f->at_cluster && f->at_index <= index;
  vx_status st = fat_walk(v, ahead ? f->at_cluster : f->cluster, ahead ? index - f->at_index : index, &c);
  for (uint32_t done = 0; st == VX_OK && done < count;) {
    if (!c) return VX_ERR_IO;
    uint32_t in = (uint32_t)(offset % v->cluster_bytes);
    uint64_t sector = fat_cluster_sector(v, c) + in / v->bps;
    uint32_t at = in % v->bps, n = v->bps - at;
    if (n > count - done) n = count - done;
    if (at == 0 && n == v->bps) { // whole sectors, to the cluster's end at most
      uint32_t run = (v->cluster_bytes - in) / v->bps, want = (count - done) / v->bps;
      if (run > want) run = want;
      if (!fat_store(v, sector, run, buf + done)) return VX_ERR_IO;
      n = run * v->bps;
    } else {
      uint8_t *s = fat_sector_rw(v, sector);
      if (!s) return VX_ERR_IO;
      memcpy(s + at, buf + done, n);
      if (!fat_store(v, sector, 1, s)) return VX_ERR_IO;
    }
    f->at_cluster = c, f->at_index = index;
    done += n, offset += n;
    if (offset % v->cluster_bytes == 0 && done < count) {
      st = fat_next(v, c, &c);
      index++;
    }
  }
  return st;
}

// count bytes of buf written at offset, the file grown (with zeros between
// its end and offset) as it must be; its entry's size and time then.
[[maybe_unused]] static vx_status fat_write(fat_vol *v, fat_entry *f, uint64_t offset, const uint8_t *buf,
                                            uint32_t count) {
  if (f->attr & FAT_DIRECTORY) return VX_ERR_INVALID;
  if (!v->dev.write) return VX_ERR_ACCESS;
  if (offset + count > UINT32_MAX) return VX_ERR_NO_SPACE; // FAT's files end at 4 GiB
  uint64_t end = offset + count;
  vx_status st = fat_grow(v, f, fat_clusters_for(v, end > f->size ? end : f->size));
  static const uint8_t zeros[FAT_MAX_SECTOR];
  for (uint64_t at = f->size; st == VX_OK && at < offset;) { // the gap
    uint32_t n = offset - at < sizeof zeros ? (uint32_t)(offset - at) : (uint32_t)sizeof zeros;
    st = fat_put_bytes(v, f, at, zeros, n);
    at += n;
  }
  if (st == VX_OK) st = fat_put_bytes(v, f, offset, buf, count);
  if (st != VX_OK && st != VX_ERR_NO_SPACE) return st;
  // What was written is the file's even if the volume filled part way: the
  // clusters were taken first, so its size can only cover written bytes.
  if (st == VX_OK && end > f->size) f->size = (uint32_t)end;
  f->mtime = v->now, f->attr |= FAT_ARCHIVE;
  vx_status put = fat_put_entry(v, f);
  return st != VX_OK ? st : put;
}

// The file cut, or grown with zeros, to size.
[[maybe_unused]] static vx_status fat_truncate(fat_vol *v, fat_entry *f, uint64_t size) {
  if (f->attr & FAT_DIRECTORY) return VX_ERR_INVALID;
  if (!v->dev.write) return VX_ERR_ACCESS;
  if (size > UINT32_MAX) return VX_ERR_NO_SPACE;
  if (size > f->size) {
    static const uint8_t zeros[FAT_MAX_SECTOR];
    vx_status st = VX_OK;
    while (st == VX_OK && f->size < size) {
      uint32_t n = size - f->size < sizeof zeros ? (uint32_t)(size - f->size) : (uint32_t)sizeof zeros;
      st = fat_write(v, f, f->size, zeros, n);
    }
    return st;
  }
  uint64_t keep = fat_clusters_for(v, size);
  uint32_t cut = 0; // the first cluster to free
  vx_status st = VX_OK;
  if (!keep) {
    cut = f->cluster;
    f->cluster = 0;
  } else if (f->cluster) {
    uint32_t last;
    st = fat_walk(v, f->cluster, keep - 1, &last);
    if (st == VX_OK && last) st = fat_next(v, last, &cut);
    if (st == VX_OK && last && cut) st = fat_set(v, last, 0x0fff'ffff);
  }
  f->size = (uint32_t)size, f->mtime = v->now, f->attr |= FAT_ARCHIVE;
  f->at_cluster = 0, f->at_index = 0;
  if (st == VX_OK) st = fat_put_entry(v, f); // the entry before the clusters go
  if (st == VX_OK && cut) st = fat_free_chain(v, cut);
  return st;
}

// --- Names for new entries ---

[[maybe_unused]] static bool fat_in(const char *set, uint32_t c) {
  for (; *set; set++)
    if ((uint8_t)*set == c) return true;
  return false;
}

[[maybe_unused]] static bool fat_short_char(uint32_t c) {
  if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return true;
  return c < 0x80 && fat_in("!#$%&'()-@^_`{}~", c);
}

// The name's UTF-16 units, or 0 if it cannot be a FAT name: control
// characters, "*/:<>?\|, or a trailing dot or space (Windows would drop them).
[[maybe_unused]] static uint32_t fat_utf16(const char *name, size_t len, uint16_t units[260]) {
  uint32_t n = 0;
  if (!len || name[len - 1] == '.' || name[len - 1] == ' ') return 0;
  if ((len == 1 && name[0] == '.') || (len == 2 && name[0] == '.' && name[1] == '.')) return 0;
  for (size_t i = 0; i < len;) {
    uint8_t b = (uint8_t)name[i];
    uint32_t c, more;
    if (b < 0x80)
      c = b, more = 0;
    else if ((b & 0xe0) == 0xc0)
      c = b & 0x1f, more = 1;
    else if ((b & 0xf0) == 0xe0)
      c = b & 0x0f, more = 2;
    else if ((b & 0xf8) == 0xf0)
      c = b & 0x07, more = 3;
    else
      return 0;
    if (i + 1 + more > len) return 0;
    for (uint32_t k = 1; k <= more; k++) {
      if (((uint8_t)name[i + k] & 0xc0) != 0x80) return 0;
      c = c << 6 | ((uint8_t)name[i + k] & 0x3f);
    }
    i += 1 + more;
    if (c < 0x20 || (c < 0x80 && fat_in("\"*/:<>?\\|", c)) || (c >= 0xd800 && c < 0xe000) || c > 0x10'ffff)
      return 0;
    if (c >= 0x1'0000) {
      if (n + 2 > 255) return 0;
      units[n++] = (uint16_t)(0xd800 + ((c - 0x1'0000) >> 10));
      units[n++] = (uint16_t)(0xdc00 + ((c - 0x1'0000) & 0x3ff));
    } else {
      if (n + 1 > 255) return 0;
      units[n++] = (uint16_t)c;
    }
  }
  return n;
}

// The name as an 8.3 name with no long name, if it is one: upper case, or
// each part all lower case (NT's flags in *nt). False if it needs a long name.
[[maybe_unused]] static bool fat_fits_short(const char *name, size_t len, uint8_t out[11], uint8_t *nt) {
  memset(out, ' ', 11);
  *nt = 0;
  size_t dot = len;
  for (size_t i = 0; i < len; i++)
    if (name[i] == '.') {
      if (dot != len) return false; // two dots
      dot = i;
    }
  size_t base = dot, ext = dot == len ? 0 : len - dot - 1;
  if (!base || base > 8 || ext > 3 || (dot != len && !ext)) return false;
  for (int part = 0; part < 2; part++) {
    const char *p = part ? name + dot + 1 : name;
    size_t n = part ? ext : base;
    bool upper = false, lower = false;
    for (size_t i = 0; i < n; i++) {
      char c = p[i];
      if (c >= 'a' && c <= 'z')
        lower = true, c = (char)(c - 32);
      else if (c >= 'A' && c <= 'Z')
        upper = true;
      if (!fat_short_char((uint8_t)c)) return false;
      out[(part ? 8 : 0) + i] = (uint8_t)c;
    }
    if (upper && lower) return false;
    if (lower) *nt |= part ? 0x10 : 0x08;
  }
  if (out[0] == 0xe5) out[0] = 0x05;
  return true;
}

// Whether directory d has an entry whose 8.3 name is short (11 bytes).
[[maybe_unused]] static vx_status fat_alias_taken(fat_vol *v, uint32_t dir, const uint8_t short_name[11],
                                                  bool *taken) {
  fat_iter it = fat_iter_at(v, dir);
  *taken = false;
  for (;;) {
    const uint8_t *s;
    vx_status st = fat_slot(v, &it, &s);
    if (st == VX_ERR_NOT_FOUND || (st == VX_OK && s[0] == 0)) return VX_OK;
    if (st != VX_OK) return st;
    if (s[0] != 0xe5 && (s[11] & 0x3f) != FAT_LONG_NAME && memcmp(s, short_name, 11) == 0) {
      *taken = true;
      return VX_OK;
    }
  }
}

// An 8.3 alias for a long name, unique in the directory: Windows' basis
// name (upper case, characters 8.3 cannot hold as '_', spaces and dots but
// the last dropped), the first six of it with ~N.
[[maybe_unused]] static vx_status fat_make_alias(fat_vol *v, uint32_t dir, const uint16_t *units, uint32_t n,
                                                 uint8_t out[11]) {
  int dot = -1;
  for (uint32_t i = 0; i < n; i++)
    if (units[i] == '.') dot = (int)i;
  uint8_t base[8], ext[3];
  int nb = 0, ne = 0;
  for (uint32_t i = 0; i < n && nb < 8; i++) {
    if ((int)i == dot) break;
    uint16_t c = units[i];
    if (c == ' ' || c == '.') continue;
    if (c >= 'a' && c <= 'z') c = (uint16_t)(c - 32);
    base[nb++] = fat_short_char(c) ? (uint8_t)c : '_';
  }
  for (uint32_t i = (uint32_t)dot + 1; dot >= 0 && i < n && ne < 3; i++) {
    uint16_t c = units[i];
    if (c == ' ') continue;
    if (c >= 'a' && c <= 'z') c = (uint16_t)(c - 32);
    ext[ne++] = fat_short_char(c) ? (uint8_t)c : '_';
  }
  if (!nb) base[nb++] = '_';
  for (uint32_t k = 1; k < 1'000'000; k++) {
    char tail[8];
    int nt = 0;
    for (uint32_t x = k; x; x /= 10) tail[nt++] = (char)('0' + x % 10);
    int keep = nb < 7 - nt ? nb : 7 - nt;
    memset(out, ' ', 11);
    memcpy(out, base, (size_t)keep);
    out[keep] = '~';
    for (int i = 0; i < nt; i++) out[keep + 1 + i] = (uint8_t)tail[nt - 1 - i];
    memcpy(out + 8, ext, (size_t)ne);
    bool taken;
    vx_status st = fat_alias_taken(v, dir, out, &taken);
    if (st != VX_OK) return st;
    if (!taken) return VX_OK;
  }
  return VX_ERR_EXISTS;
}

// count free slots in a row in directory dir: the first's index. The
// directory is grown by a zeroed cluster when it has no such run (the fixed
// root cannot be: NO_SPACE).
[[maybe_unused]] static vx_status fat_find_slots(fat_vol *v, uint32_t dir, uint32_t count, uint32_t *first) {
  fat_iter it = fat_iter_at(v, dir);
  uint32_t run = 0, start = 0, last = dir;
  for (;;) {
    const uint8_t *s;
    vx_status st = fat_slot(v, &it, &s);
    if (st == VX_ERR_NOT_FOUND) break;
    if (st != VX_OK) return st;
    if (it.cluster) last = it.cluster;
    if (s[0] == 0 || s[0] == 0xe5) {
      if (!run++) start = it.index - 1;
      if (run == count) {
        *first = start;
        return VX_OK;
      }
    } else {
      run = 0;
    }
  }
  if (dir == 0 || it.index + count > (1u << 21)) return VX_ERR_NO_SPACE;
  uint32_t c; // a cluster more, zeroed before the chain reaches it
  vx_status st = fat_alloc(v, 0, &c);
  if (st == VX_OK) st = fat_zero_cluster(v, c);
  if (st == VX_OK) st = fat_set(v, last, c);
  if (st != VX_OK) return st;
  if (!run) start = it.index;
  if (run + v->cluster_bytes / 32 < count) return VX_ERR_NO_SPACE; // a name longer than a cluster's slots
  *first = start;
  return VX_OK;
}

// A new entry in directory d named name: a file, or with FAT_DIRECTORY a
// directory, given its first cluster (with "." and ".."); or, with like, a
// copy of like's cluster, size, attributes and times (a rename). *out is
// the new entry. EXISTS if the name is taken.
[[maybe_unused]] static vx_status fat_add(fat_vol *v, const fat_entry *d, const char *name, size_t len,
                                          uint8_t attr, const fat_entry *like, fat_entry *out) {
  if (!(d->attr & FAT_DIRECTORY)) return VX_ERR_INVALID;
  if (!v->dev.write) return VX_ERR_ACCESS;
  uint16_t units[260];
  uint32_t n = fat_utf16(name, len, units);
  if (!n) return VX_ERR_INVALID;
  fat_entry e;
  vx_status st = fat_lookup(v, d, name, len, &e);
  if (st == VX_OK) return VX_ERR_EXISTS;
  if (st != VX_ERR_NOT_FOUND) return st;
  uint32_t dir = d->node == FAT_ROOT ? fat_dir_of(v, FAT_ROOT) : d->cluster;
  uint8_t short_name[11], nt;
  bool lfn = !fat_fits_short(name, len, short_name, &nt);
  if (!lfn) {
    bool taken;
    if ((st = fat_alias_taken(v, dir, short_name, &taken)) != VX_OK) return st;
    lfn = taken; // its 8.3 form is another entry's alias: give it a long name and an alias of its own
  }
  if (lfn && (st = fat_make_alias(v, dir, units, n, short_name)) != VX_OK) return st;
  if (lfn) nt = 0;
  uint32_t slots = lfn ? (n + 12) / 13 : 0, first;
  if ((st = fat_find_slots(v, dir, slots + 1, &first)) != VX_OK) return st;
  // A new directory's cluster, with "." and "..", before any entry names it.
  uint32_t cluster = like ? like->cluster : 0;
  if (!like && (attr & FAT_DIRECTORY)) {
    if ((st = fat_alloc(v, 0, &cluster)) == VX_OK) st = fat_zero_cluster(v, cluster);
    uint8_t dot[32] = {'.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', FAT_DIRECTORY};
    uint16_t date, time;
    fat_stamp(v->now, &date, &time);
    fat_put16(dot + 14, time), fat_put16(dot + 16, date), fat_put16(dot + 18, date);
    fat_put16(dot + 22, time), fat_put16(dot + 24, date);
    for (int k = 0; st == VX_OK && k < 2; k++) {
      uint32_t parent = d->node == FAT_ROOT ? 0 : d->cluster; // ".." of a root child is 0
      uint32_t c = k ? parent : cluster;
      if (k) dot[1] = '.';
      fat_put16(dot + 20, v->type == 32 ? c >> 16 : 0), fat_put16(dot + 26, c & 0xffff);
      st = fat_put_slot(v, cluster, (uint32_t)k, dot);
    }
    if (st != VX_OK) return st;
  }
  uint8_t sum = fat_checksum(short_name);
  for (uint32_t k = 0; k < slots; k++) { // the long name, its last part first
    uint32_t seq = slots - k;
    uint8_t s[32] = {};
    s[0] = (uint8_t)(seq | (k == 0 ? 0x40 : 0)), s[11] = FAT_LONG_NAME, s[13] = sum;
    static const uint8_t at[13] = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};
    for (uint32_t i = 0; i < 13; i++) {
      uint32_t u = (seq - 1) * 13 + i;
      uint32_t unit = u == n ? 0 : 0xffff; // a NUL after the name, then padding
      fat_put16(s + at[i], u < n ? units[u] : unit);
    }
    if ((st = fat_put_slot(v, dir, first + k, s)) != VX_OK) return st;
  }
  uint8_t s[32] = {};
  memcpy(s, short_name, 11);
  s[11] = like ? like->attr : (uint8_t)(attr | (attr & FAT_DIRECTORY ? 0 : FAT_ARCHIVE));
  s[12] = nt;
  uint16_t date, time;
  fat_stamp(like ? like->ctime : v->now, &date, &time);
  fat_put16(s + 14, time), fat_put16(s + 16, date);
  fat_stamp(like ? like->mtime : v->now, &date, &time);
  fat_put16(s + 18, date), fat_put16(s + 22, time), fat_put16(s + 24, date);
  fat_put16(s + 20, v->type == 32 ? cluster >> 16 : 0), fat_put16(s + 26, cluster & 0xffff);
  fat_put32(s + 28, like && !(like->attr & FAT_DIRECTORY) ? like->size : 0);
  if ((st = fat_put_slot(v, dir, first + slots, s)) != VX_OK) return st;
  return fat_get(v, fat_node(dir, first + slots), out);
}

[[maybe_unused]] static vx_status fat_create(fat_vol *v, const fat_entry *d, const char *name, size_t len,
                                             uint8_t attr, fat_entry *out) {
  return fat_add(v, d, name, len, attr, nullptr, out);
}

// The entry's slots, its long name's and its own, marked free.
[[maybe_unused]] static vx_status fat_unlink(fat_vol *v, const fat_entry *e) {
  uint32_t dir = fat_dir_of(v, e->node), index = fat_index_of(e->node);
  uint8_t s[32];
  vx_status st = fat_get_slot(v, dir, index, s);
  if (st != VX_OK) return st;
  uint8_t sum = fat_checksum(s);
  s[0] = 0xe5;
  if ((st = fat_put_slot(v, dir, index, s)) != VX_OK) return st;
  for (uint32_t i = index, k = 0; i > 0 && k < 20; k++) { // its long name, just before it
    uint8_t l[32];
    if ((st = fat_get_slot(v, dir, --i, l)) != VX_OK) return st;
    if ((l[11] & 0x3f) != FAT_LONG_NAME || l[0] == 0xe5 || l[13] != sum) break;
    bool first = l[0] & 0x40; // the name's last part: its first slot
    l[0] = 0xe5;
    if ((st = fat_put_slot(v, dir, i, l)) != VX_OK) return st;
    if (first) break;
  }
  return VX_OK;
}

// An entry removed, and its clusters freed after. A directory must be empty
// (EXISTS if not).
[[maybe_unused]] static vx_status fat_remove(fat_vol *v, const fat_entry *e) {
  if (e->node == FAT_ROOT) return VX_ERR_ACCESS;
  if (!v->dev.write) return VX_ERR_ACCESS;
  if (e->attr & FAT_DIRECTORY) {
    fat_iter it;
    fat_entry child;
    vx_status st = fat_open_dir(v, e, &it);
    if (st == VX_OK) st = fat_dir_next(v, &it, &child);
    if (st == VX_OK) return VX_ERR_EXISTS;
    if (st != VX_ERR_NOT_FOUND) return st;
  }
  vx_status st = fat_unlink(v, e);
  return st == VX_OK && e->cluster ? fat_free_chain(v, e->cluster) : st;
}

// An entry moved to directory to, named name: a new entry made like it, the
// old one's slots freed; a directory's ".." then names its new parent. What
// the name had is replaced, as POSIX's rename does, if it is a file (and so
// is e) or an empty directory (and so is e). *out is the new entry.
[[maybe_unused]] static vx_status fat_rename(fat_vol *v, const fat_entry *e, const fat_entry *to,
                                             const char *name, size_t len, fat_entry *out) {
  if (e->node == FAT_ROOT || !(to->attr & FAT_DIRECTORY)) return VX_ERR_INVALID;
  if (!v->dev.write) return VX_ERR_ACCESS;
  bool dir = e->attr & FAT_DIRECTORY;
  if (dir) { // not into itself or below it
    for (uint64_t up = to->node, steps = 0; up != FAT_ROOT; steps++) {
      if (up == e->node || steps > 4096) return VX_ERR_INVALID;
      vx_status st = fat_parent(v, up, &up);
      if (st != VX_OK) return st;
    }
  }
  fat_entry old;
  vx_status st = fat_lookup(v, to, name, len, &old);
  if (st == VX_OK) {
    if (old.node == e->node) { // the same entry: only its case changes, or nothing
      fat_entry keep = *e;
      if ((st = fat_unlink(v, e)) != VX_OK) return st;
      return fat_add(v, to, name, len, 0, &keep, out);
    }
    if (dir != !!(old.attr & FAT_DIRECTORY)) return VX_ERR_EXISTS;
    if ((st = fat_remove(v, &old)) != VX_OK) return st;
  } else if (st != VX_ERR_NOT_FOUND) {
    return st;
  }
  if ((st = fat_add(v, to, name, len, 0, e, out)) != VX_OK) return st;
  if ((st = fat_unlink(v, e)) != VX_OK) return st;
  if (dir && fat_dir_of(v, e->node) != (to->node == FAT_ROOT ? fat_dir_of(v, FAT_ROOT) : to->cluster)) {
    uint8_t s[32];
    if ((st = fat_get_slot(v, e->cluster, 1, s)) != VX_OK) return st;
    uint32_t c = to->node == FAT_ROOT ? 0 : to->cluster;
    fat_put16(s + 20, v->type == 32 ? c >> 16 : 0), fat_put16(s + 26, c & 0xffff);
    if ((st = fat_put_slot(v, e->cluster, 1, s)) != VX_OK) return st;
  }
  return VX_OK;
}

// FAT32's FSInfo brought up to date, and the device flushed.
[[maybe_unused]] static vx_status fat_flush(fat_vol *v) {
  if (!v->dev.write) return VX_OK;
  if (v->fsinfo_sector && v->fsinfo_dirty) {
    uint8_t *s = fat_sector_rw(v, v->fsinfo_sector);
    if (!s) return VX_ERR_IO;
    if (fat_u32(s) == 0x4161'5252 && fat_u32(s + 484) == 0x6141'7272) {
      fat_put32(s + 488, v->free_count);
      fat_put32(s + 492, v->free_hint);
      if (!fat_store(v, v->fsinfo_sector, 1, s)) return VX_ERR_IO;
    }
    v->fsinfo_dirty = false;
  }
  return !v->dev.flush || v->dev.flush(v->dev.ctx) ? VX_OK : VX_ERR_IO;
}

// --- Formatting (M5 step 9c: install's ESP) ---

// A new FAT32 volume of `sectors` 512-byte sectors on dev (which must write),
// labelled label (up to 11 characters, upper case), with serial; `hidden` is
// the sectors before it on its disk (its partition's first LBA). Laid out as
// Microsoft's specification has it: 32 reserved sectors (FSInfo at 1, the
// boot sector's backup at 6), two FATs, the root directory at cluster 2,
// clusters of 512 bytes up to 260 MiB, 4 KiB to 8 GiB, larger beyond.
// INVALID if the volume is too small for FAT32's 65525 clusters (about 33 MiB).
[[maybe_unused]] static vx_status fat_format(fat_dev dev, uint64_t sectors, uint64_t hidden,
                                             const char *label, uint32_t serial) {
  if (!dev.write || sectors > 0xffff'ffff) return VX_ERR_INVALID;
  uint32_t spc = 1;
  if (sectors > 532'480) spc = 8;     // 260 MiB
  if (sectors > 16'777'216) spc = 16; // 8 GiB
  if (sectors > 33'554'432) spc = 32; // 16 GiB
  if (sectors > 67'108'864) spc = 64; // 32 GiB
  uint32_t reserved = 32, nfats = 2;
  uint64_t tmp1 = sectors - reserved, tmp2 = (256ull * spc + nfats) / 2;
  uint32_t fatsz = (uint32_t)((tmp1 + tmp2 - 1) / tmp2);
  uint64_t clusters = (sectors - reserved - (uint64_t)nfats * fatsz) / spc;
  if (clusters < 65525 || clusters > 0x0fff'fff5) return VX_ERR_INVALID;
  static uint8_t s[512];
  // The boot sector.
  memset(s, 0, sizeof s);
  s[0] = 0xeb, s[1] = 0x58, s[2] = 0x90;
  for (int i = 0; i < 8; i++) s[3 + i] = (uint8_t)"VECTRAOS"[i]; // the OEM name
  fat_put16(s + 11, 512);
  s[13] = (uint8_t)spc;
  fat_put16(s + 14, (uint16_t)reserved);
  s[16] = (uint8_t)nfats;
  s[21] = 0xf8;                                  // a fixed disk
  fat_put16(s + 24, 63), fat_put16(s + 26, 255); // geometry no one uses
  fat_put32(s + 28, (uint32_t)hidden);
  fat_put32(s + 32, (uint32_t)sectors);
  fat_put32(s + 36, fatsz);
  fat_put32(s + 44, 2); // the root directory's cluster
  fat_put16(s + 48, 1); // FSInfo
  fat_put16(s + 50, 6); // the boot sector's backup
  s[64] = 0x80, s[66] = 0x29;
  fat_put32(s + 67, serial);
  memset(s + 71, ' ', 11);
  for (int i = 0; i < 11 && label[i]; i++) s[71 + i] = (uint8_t)label[i];
  for (int i = 0; i < 8; i++) s[82 + i] = (uint8_t)"FAT32   "[i];
  s[510] = 0x55, s[511] = 0xaa;
  if (!dev.write(dev.ctx, 0, 512, s) || !dev.write(dev.ctx, 6ull * 512, 512, s)) return VX_ERR_IO;
  // FSInfo, and its backup.
  memset(s, 0, sizeof s);
  fat_put32(s, 0x4161'5252);
  fat_put32(s + 484, 0x6141'7272);
  fat_put32(s + 488, (uint32_t)clusters - 1); // all free but the root's
  fat_put32(s + 492, 3);
  fat_put32(s + 508, 0xaa55'0000);
  if (!dev.write(dev.ctx, 512, 512, s) || !dev.write(dev.ctx, 7ull * 512, 512, s)) return VX_ERR_IO;
  // The other reserved sectors, the FATs and the root's cluster: zeros, with
  // the FATs' first three entries (the media byte, the end marker, the root's
  // chain's end).
  static uint8_t zeros[64 * 512];
  uint64_t end = reserved + (uint64_t)nfats * fatsz + spc;
  for (uint64_t at = 2; at < end;) {
    if (at == 6) {
      at = 8;
      continue;
    }
    uint64_t n = end - at > 64 ? 64 : end - at;
    if (at < 6 && at + n > 6) n = 6 - at;
    if (!dev.write(dev.ctx, at * 512, (uint32_t)n * 512, zeros)) return VX_ERR_IO;
    at += n;
  }
  memset(s, 0, sizeof s);
  fat_put32(s, 0x0fff'fff8), fat_put32(s + 4, 0x0fff'ffff), fat_put32(s + 8, 0x0fff'ffff);
  for (uint32_t f = 0; f < nfats; f++)
    if (!dev.write(dev.ctx, ((uint64_t)reserved + (uint64_t)f * fatsz) * 512, 512, s)) return VX_ERR_IO;
  // The label again, as the root directory's first entry: fsck.fat and
  // Windows read it from there.
  memset(s, 0, sizeof s);
  memset(s, ' ', 11);
  for (int i = 0; i < 11 && label[i]; i++) s[i] = (uint8_t)label[i];
  s[11] = FAT_LABEL;
  return dev.write(dev.ctx, ((uint64_t)reserved + (uint64_t)nfats * fatsz) * 512, 512, s) ? VX_OK : VX_ERR_IO;
}
