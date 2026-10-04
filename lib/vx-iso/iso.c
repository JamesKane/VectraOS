// vx-iso: ISO 9660 with Rock Ridge and Joliet, read-only (docs/11 §11, M5
// step 8c), for isofs. After 9front's 9660srv, reimplemented in C23. Pure
// code over one callback, a device that reads 2048-byte sectors, so it
// builds for the host's tests as well as for isofs.
//
// A volume is read one of three ways, the first it has unless told not to:
// - Rock Ridge (RRIP 1991A or IEEE 1282, over SUSP, found by the root's SP
//   and ER): the primary tree, with real names (NM), POSIX modes (PX), times
//   (TF), symbolic links (SL), continuation areas (CE), and deep
//   directories relocated (CL, PL, RE). Names are matched exactly.
// - Joliet (a supplementary descriptor with escape %/@, %/C or %/E): its
//   own tree, names in UCS-2 (read as UTF-16) to UTF-8. Matched ignoring
//   ASCII case.
// - ISO 9660 alone: the primary tree's names lower-cased, without ";1" or
//   a trailing dot, as 9660srv shows them. Matched ignoring ASCII case.
//
// A node is a directory record's place: the extent (LBA) of the directory
// it is in and its offset there. The root has no record of its own: it is
// ISO_ROOT. A directory's parent is found through its ".." record, then the
// record in the grandparent naming its extent.

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

enum : uint32_t { ISO_SECTOR = 2048, ISO_CACHE = 16, ISO_NAME_MAX = 255 * 3 + 1, ISO_LINK_MAX = 1024 };
static constexpr uint64_t ISO_ROOT = 1;

typedef struct iso_dev {
  void *ctx;
  // len bytes from off, both multiples of ISO_SECTOR.
  bool (*read)(void *ctx, uint64_t off, uint32_t len, uint8_t *buf);
} iso_dev;

enum iso_kind : uint32_t { ISO_PLAIN = 1, ISO_JOLIET = 2, ISO_ROCK = 4 };

typedef struct iso_vol {
  iso_dev dev;
  uint32_t kind;               // what it is read as: one of iso_kind
  uint32_t root_lba, root_len; // the tree read's root directory
  uint32_t susp_skip;          // SP's: bytes to skip in each record's system use
  uint64_t sectors;            // the volume's
  char label[33];              // the primary descriptor's volume identifier, trailing spaces cut
  struct {
    uint64_t sector, last;
    bool valid;
    uint8_t data[ISO_SECTOR];
  } cache[ISO_CACHE];
  uint64_t tick;
} iso_vol;

typedef struct iso_entry {
  uint64_t node;
  uint32_t lba, size; // the extent: the file's bytes, or the directory's records
  bool dir, link;
  uint32_t mode;             // POSIX permissions (Rock Ridge's PX), else 0444, or 0555 for a directory
  int64_t mtime;             // seconds since 1970, UTC
  char name[ISO_NAME_MAX];   // UTF-8, NUL-terminated
  char target[ISO_LINK_MAX]; // a symbolic link's
} iso_entry;

static uint32_t iso_u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

// A sector, through the cache: nullptr if the device fails or it is past the volume.
static const uint8_t *iso_sector(iso_vol *v, uint64_t sector) {
  uint32_t victim = 0;
  for (uint32_t i = 0; i < ISO_CACHE; i++) {
    if (v->cache[i].valid && v->cache[i].sector == sector) {
      v->cache[i].last = ++v->tick;
      return v->cache[i].data;
    }
    if (!v->cache[i].valid || v->cache[i].last < v->cache[victim].last) victim = i;
  }
  if ((v->sectors && sector >= v->sectors) ||
      !v->dev.read(v->dev.ctx, sector * ISO_SECTOR, ISO_SECTOR, v->cache[victim].data))
    return nullptr;
  v->cache[victim].sector = sector, v->cache[victim].valid = true, v->cache[victim].last = ++v->tick;
  return v->cache[victim].data;
}

// --- Records ---

// A record of a directory: its bytes (a copy: the cache may move) and length.
typedef struct iso_rec {
  uint8_t b[256];
  uint32_t len;
} iso_rec;

// The record at offset off of directory [lba, lba + len): NOT_FOUND past
// the end; *next is where the one after it is (records never straddle a
// sector: a zero length byte means the rest of the sector is padding).
static vx_status iso_record_at(iso_vol *v, uint32_t lba, uint32_t len, uint32_t off, iso_rec *r,
                               uint32_t *next) {
  while (off < len) {
    const uint8_t *s = iso_sector(v, (uint64_t)lba + off / ISO_SECTOR);
    if (!s) return VX_ERR_IO;
    uint32_t at = off % ISO_SECTOR, n = s[at];
    if (n == 0) { // the sector's padding
      off = (off / ISO_SECTOR + 1) * ISO_SECTOR;
      continue;
    }
    if (n < 34 || at + n > ISO_SECTOR || s[at + 32] + 33u > n) return VX_ERR_IO;
    memcpy(r->b, s + at, n);
    r->len = n;
    *next = off + n;
    return VX_OK;
  }
  return VX_ERR_NOT_FOUND;
}

static bool iso_is_dot(const iso_rec *r) { return r->b[32] == 1 && r->b[33] <= 1; } // "." or ".."

// --- System use (SUSP and Rock Ridge) ---

// Calls each SUSP entry of the record, following continuation areas (CE).
// fn returns false to stop.
typedef bool (*iso_su_fn)(void *ctx, const uint8_t *e, uint32_t len);

static vx_status iso_each_su(iso_vol *v, const iso_rec *r, uint32_t skip, iso_su_fn fn, void *ctx) {
  uint32_t nlen = r->b[32], at = 33 + nlen + !(nlen & 1) + skip;
  static uint8_t area[ISO_SECTOR];
  const uint8_t *p = r->b;
  uint32_t end = r->len;
  for (int hops = 0; hops < 16;) {
    uint32_t ce_lba = 0, ce_off = 0, ce_len = 0;
    while (at + 4 <= end) {
      const uint8_t *e = p + at;
      uint32_t len = e[2];
      if (len < 4 || at + len > end) break;
      if (e[0] == 'S' && e[1] == 'T') return VX_OK; // the terminator
      if (e[0] == 'C' && e[1] == 'E' && len >= 28)
        ce_lba = iso_u32(e + 4), ce_off = iso_u32(e + 12), ce_len = iso_u32(e + 20);
      else if (!fn(ctx, e, len))
        return VX_OK;
      at += len;
    }
    if (!ce_len) return VX_OK;
    if (ce_off >= ISO_SECTOR || ce_len > ISO_SECTOR - ce_off) return VX_ERR_IO;
    const uint8_t *s = iso_sector(v, ce_lba);
    if (!s) return VX_ERR_IO;
    memcpy(area, s, ISO_SECTOR);
    p = area, at = ce_off, end = ce_off + ce_len, hops++;
  }
  return VX_ERR_IO; // a chain of continuations that does not end
}

// What a record's Rock Ridge entries say.
typedef struct iso_rr {
  char name[ISO_NAME_MAX];
  uint32_t name_len;
  bool have_name, name_done, have_mode, have_time, relocated, link, link_done;
  uint32_t mode, child_lba, parent_lba; // PX's; CL's; PL's
  int64_t mtime;
  char target[ISO_LINK_MAX];
  uint32_t target_len;
  bool target_sep; // a component was added: the next needs a '/'
} iso_rr;

// A 7-byte record date (and Rock Ridge's short form) as seconds since 1970, UTC.
static int64_t iso_time7(const uint8_t *d) {
  int64_t y = 1900 + d[0];
  uint32_t m = d[1], day = d[2];
  if (m < 1 || m > 12 || day < 1 || day > 31) return 0;
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  uint32_t yoe = (uint32_t)(y - era * 400);
  uint32_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + day - 1;
  uint32_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  int64_t t =
      (era * 146097 + (int64_t)doe - 719468) * 86400 + (int64_t)d[3] * 3600 + (int64_t)d[4] * 60 + d[5];
  return t - (int64_t)(int8_t)d[6] * 15 * 60; // the offset from GMT, in quarter hours
}

static void iso_target_put(iso_rr *rr, const char *s, uint32_t n) {
  if (rr->target_len + n < ISO_LINK_MAX) memcpy(rr->target + rr->target_len, s, n), rr->target_len += n;
}

static bool iso_rr_entry(void *ctx, const uint8_t *e, uint32_t len) {
  iso_rr *rr = ctx;
  if (e[0] == 'P' && e[1] == 'X' && len >= 36) {
    rr->mode = iso_u32(e + 4), rr->have_mode = true;
  } else if (e[0] == 'N' && e[1] == 'M' && len >= 5 && !rr->name_done) {
    if (e[4] & 0x06) return true; // CURRENT or PARENT: "." or ".."
    uint32_t n = len - 5;
    if (rr->name_len + n >= ISO_NAME_MAX) n = ISO_NAME_MAX - 1 - rr->name_len;
    memcpy(rr->name + rr->name_len, e + 5, n);
    rr->name_len += n, rr->have_name = true;
    rr->name_done = !(e[4] & 0x01); // CONTINUE
  } else if (e[0] == 'T' && e[1] == 'F' && len >= 5) {
    uint32_t flags = e[4], size = flags & 0x80 ? 17 : 7, at = 5;
    for (uint32_t bit = 0; bit < 7; bit++) {
      if (!(flags & 1u << bit)) continue;
      if (at + size > len) break;
      if (bit == 1 && size == 7) rr->mtime = iso_time7(e + at), rr->have_time = true; // modification
      at += size;
    }
  } else if (e[0] == 'S' && e[1] == 'L' && len >= 5 && !rr->link_done) {
    rr->link = true;
    for (uint32_t at = 5; at + 2 <= len;) {
      uint32_t flags = e[at], n = e[at + 1];
      if (at + 2 + n > len) break;
      if (rr->target_sep) iso_target_put(rr, "/", 1);
      if (flags & 0x08)
        iso_target_put(rr, "/", 1), rr->target_sep = false; // ROOT
      else if (flags & 0x02)
        iso_target_put(rr, ".", 1), rr->target_sep = true;
      else if (flags & 0x04)
        iso_target_put(rr, "..", 2), rr->target_sep = true;
      else
        iso_target_put(rr, (const char *)e + at + 2, n),
            rr->target_sep = !(flags & 0x01); // CONTINUE: the same component goes on
      at += 2 + n;
    }
    rr->link_done = !(e[4] & 0x01);
  } else if (e[0] == 'C' && e[1] == 'L' && len >= 12) {
    rr->child_lba = iso_u32(e + 4);
  } else if (e[0] == 'P' && e[1] == 'L' && len >= 12) {
    rr->parent_lba = iso_u32(e + 4);
  } else if (e[0] == 'R' && e[1] == 'E') {
    rr->relocated = true;
  }
  return true;
}

// --- Names ---

static void iso_put_utf8(char *out, size_t *n, uint32_t c) {
  if (*n + 4 >= ISO_NAME_MAX) return;
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

// A record's identifier as a name: Joliet's UTF-16BE, or ISO 9660's
// d-characters lower-cased; ";N" and a trailing dot dropped from a file's.
static void iso_plain_name(const iso_rec *r, bool joliet, char *out) {
  const uint8_t *id = r->b + 33;
  uint32_t n = r->b[32];
  size_t len = 0;
  if (joliet) {
    for (uint32_t i = 0; i + 1 < n; i += 2) {
      uint32_t c = (uint32_t)id[i] << 8 | id[i + 1];
      if (c >= 0xd800 && c < 0xdc00 && i + 3 < n) {
        uint32_t lo = (uint32_t)id[i + 2] << 8 | id[i + 3];
        if (lo >= 0xdc00 && lo < 0xe000)
          c = 0x1'0000 + ((c - 0xd800) << 10) + (lo - 0xdc00), i += 2;
        else
          c = 0xfffd;
      } else if (c >= 0xd800 && c < 0xe000) {
        c = 0xfffd;
      }
      if (c == '/' || c == 0) c = 0xfffd;
      iso_put_utf8(out, &len, c);
    }
  } else {
    for (uint32_t i = 0; i < n; i++) {
      uint8_t c = id[i];
      if (c >= 0x80 || c == '/' || c == 0) c = '_';
      out[len++] = (char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
    }
  }
  out[len] = 0;
  if (!(r->b[25] & 0x02)) { // a file: NAME.EXT;1
    char *semi = nullptr;
    for (size_t i = 0; i < len; i++)
      if (out[i] == ';') semi = out + i;
    if (semi) *semi = 0, len = (size_t)(semi - out);
    if (len > 1 && out[len - 1] == '.') out[--len] = 0;
  }
}

static uint64_t iso_node(uint32_t dir_lba, uint32_t off) {
  return 1ull << 62 | (uint64_t)dir_lba << 24 | off;
}
static uint32_t iso_node_dir(uint64_t node) { return (uint32_t)(node >> 24); }
static uint32_t iso_node_off(uint64_t node) { return (uint32_t)(node & 0xff'ffff); }

// An entry from its record, found at off in directory dir_lba. NOT_FOUND
// for one Rock Ridge hides (a relocated directory, RE, seen where it was moved to).
static vx_status iso_decode(iso_vol *v, const iso_rec *r, uint32_t dir_lba, uint32_t off, iso_entry *e) {
  *e = (iso_entry){.node = iso_node(dir_lba, off),
                   .lba = iso_u32(r->b + 2),
                   .size = iso_u32(r->b + 10),
                   .dir = r->b[25] & 0x02,
                   .mtime = iso_time7(r->b + 18)};
  e->mode = e->dir ? 0555 : 0444;
  if (v->kind == ISO_ROCK) {
    static iso_rr rr;
    memset(&rr, 0, sizeof rr);
    vx_status st = iso_each_su(v, r, v->susp_skip, iso_rr_entry, &rr);
    if (st != VX_OK) return st;
    if (rr.relocated) return VX_ERR_NOT_FOUND;
    if (rr.child_lba) { // a directory moved elsewhere: it is here, and its records there
      e->dir = true, e->lba = rr.child_lba;
      iso_rec dot;
      uint32_t next;
      if (iso_record_at(v, rr.child_lba, ISO_SECTOR, 0, &dot, &next) != VX_OK) return VX_ERR_IO;
      e->size = iso_u32(dot.b + 10);
    }
    if (rr.have_mode) {
      e->mode = rr.mode & 07777;
      uint32_t type = rr.mode & 0170000;
      if (type == 040000) e->dir = true;
      if (type == 0120000) e->link = true;
    }
    if (rr.have_time) e->mtime = rr.mtime;
    if (rr.have_name) {
      for (uint32_t i = 0; i < rr.name_len; i++)
        if (rr.name[i] == '/' || rr.name[i] == 0) rr.name[i] = '_';
      memcpy(e->name, rr.name, rr.name_len);
      e->name[rr.name_len] = 0;
    } else {
      iso_plain_name(r, false, e->name);
    }
    if (rr.link) memcpy(e->target, rr.target, rr.target_len), e->target[rr.target_len] = 0, e->link = true;
    return VX_OK;
  }
  iso_plain_name(r, v->kind == ISO_JOLIET, e->name);
  return VX_OK;
}

// --- Mounting ---

static bool iso_er_rock(void *ctx, const uint8_t *e, uint32_t len) {
  bool *rock = ctx;
  if (e[0] == 'E' && e[1] == 'R' && len >= 8) {
    uint32_t idl = e[4];
    if (8 + idl <= len &&
        ((idl == 10 && (memcmp(e + 8, "RRIP_1991A", 10) == 0 || memcmp(e + 8, "IEEE_P1282", 10) == 0)) ||
         (idl == 9 && memcmp(e + 8, "IEEE_1282", 9) == 0)))
      *rock = true;
  }
  if (e[0] == 'R' && e[1] == 'R') *rock = true; // RRIP 1.09's marker, which some writers still put
  return !*rock;
}

// The volume on dev, read the first way it has of those not in avoid (a
// mask of iso_kind; ISO_PLAIN cannot be avoided). INVALID if it is not ISO 9660.
static vx_status iso_mount(iso_vol *v, iso_dev dev, uint32_t avoid) {
  memset(v, 0, sizeof *v);
  v->dev = dev;
  uint32_t pvd_lba = 0, pvd_len = 0, joliet_lba = 0, joliet_len = 0;
  for (uint32_t s = 16; s < 16 + 64; s++) {
    const uint8_t *d = iso_sector(v, s);
    if (!d) return VX_ERR_IO;
    if (memcmp(d + 1, "CD001", 5) != 0 || d[6] != 1) return pvd_lba ? VX_ERR_IO : VX_ERR_INVALID;
    if (d[0] == 255) break;
    if (d[0] == 1 && !pvd_lba) {
      if (iso_u32(d + 128) % 0x1'0000 != ISO_SECTOR || d[156] < 34)
        return VX_ERR_UNSUPPORTED; // another block size
      pvd_lba = iso_u32(d + 156 + 2), pvd_len = iso_u32(d + 156 + 10), v->sectors = iso_u32(d + 80);
      memcpy(v->label, d + 40, 32);
      int n = 32;
      while (n > 0 && v->label[n - 1] == ' ') n--;
      v->label[n] = 0;
    }
    if (d[0] == 2 && d[88] == '%' && d[89] == '/' && (d[90] == '@' || d[90] == 'C' || d[90] == 'E') &&
        !joliet_lba)
      joliet_lba = iso_u32(d + 156 + 2), joliet_len = iso_u32(d + 156 + 10);
  }
  if (!pvd_lba) return VX_ERR_INVALID;
  // Rock Ridge: the root's "." begins with SP, and an ER names RRIP.
  iso_rec dot;
  uint32_t next;
  vx_status st = iso_record_at(v, pvd_lba, pvd_len, 0, &dot, &next);
  if (st != VX_OK) return st;
  uint32_t su = 34; // after "."'s one-byte name, no padding
  bool rock = false;
  if (!(avoid & ISO_ROCK) && dot.len >= su + 7 && dot.b[su] == 'S' && dot.b[su + 1] == 'P' &&
      dot.b[su + 4] == 0xbe && dot.b[su + 5] == 0xef) {
    v->susp_skip = dot.b[su + 6];
    if ((st = iso_each_su(v, &dot, 0, iso_er_rock, &rock)) != VX_OK) return st;
  }
  if (rock) {
    v->kind = ISO_ROCK, v->root_lba = pvd_lba, v->root_len = pvd_len;
  } else if (joliet_lba && !(avoid & ISO_JOLIET)) {
    v->kind = ISO_JOLIET, v->root_lba = joliet_lba, v->root_len = joliet_len, v->susp_skip = 0;
  } else {
    v->kind = ISO_PLAIN, v->root_lba = pvd_lba, v->root_len = pvd_len, v->susp_skip = 0;
  }
  return VX_OK;
}

// --- Directories and files ---

static void iso_root_entry(const iso_vol *v, iso_entry *e) {
  *e = (iso_entry){.node = ISO_ROOT, .lba = v->root_lba, .size = v->root_len, .dir = true, .mode = 0555};
  e->name[0] = '/';
}

typedef struct iso_iter {
  uint32_t lba, len, off;
} iso_iter;

static vx_status iso_open_dir(const iso_vol *v, const iso_entry *d, iso_iter *it) {
  (void)v;
  if (!d->dir) return VX_ERR_INVALID;
  *it = (iso_iter){.lba = d->lba, .len = d->size};
  return VX_OK;
}

// The next entry in the directory: NOT_FOUND at its end. "." and "..", and
// directories Rock Ridge relocated, are skipped.
static vx_status iso_dir_next(iso_vol *v, iso_iter *it, iso_entry *e) {
  for (;;) {
    iso_rec r;
    uint32_t at = it->off, next;
    vx_status st = iso_record_at(v, it->lba, it->len, at, &r, &next);
    if (st != VX_OK) return st;
    // where the record actually was: past any padding iso_record_at skipped
    at = next - r.len;
    it->off = next;
    if (iso_is_dot(&r)) continue;
    if (r.b[25] & 0x01 && v->kind != ISO_ROCK) continue; // hidden ("existence")
    st = iso_decode(v, &r, it->lba, at, e);
    if (st == VX_ERR_NOT_FOUND) continue;
    return st;
  }
}

static bool iso_same(const char *a, const char *b, size_t blen, bool exact) {
  size_t i = 0;
  for (; i < blen && a[i]; i++) {
    char x = a[i], y = b[i];
    if (!exact) {
      if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
      if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
    }
    if (x != y) return false;
  }
  return i == blen && !a[i];
}

// The entry named name in directory d.
static vx_status iso_lookup(iso_vol *v, const iso_entry *d, const char *name, size_t len, iso_entry *e) {
  iso_iter it;
  vx_status st = iso_open_dir(v, d, &it);
  while (st == VX_OK && (st = iso_dir_next(v, &it, e)) == VX_OK)
    if (iso_same(e->name, name, len, v->kind == ISO_ROCK)) return VX_OK;
  return st;
}

// The entry for a node.
static vx_status iso_get(iso_vol *v, uint64_t node, iso_entry *e) {
  if (node == ISO_ROOT) {
    iso_root_entry(v, e);
    return VX_OK;
  }
  if (!(node >> 62)) return VX_ERR_NOT_FOUND;
  // The directory's own "." record says how long it is.
  iso_rec r;
  uint32_t next, lba = iso_node_dir(node);
  vx_status st = iso_record_at(v, lba, ISO_SECTOR, 0, &r, &next);
  if (st != VX_OK) return st;
  uint32_t len = iso_u32(r.b + 10), off = iso_node_off(node);
  if ((st = iso_record_at(v, lba, len, off, &r, &next)) != VX_OK) return st;
  if (next - r.len != off || iso_is_dot(&r)) return VX_ERR_NOT_FOUND;
  return iso_decode(v, &r, lba, off, e);
}

static bool iso_pl(void *ctx, const uint8_t *e, uint32_t len) {
  uint32_t *parent = ctx;
  if (e[0] == 'P' && e[1] == 'L' && len >= 12) *parent = iso_u32(e + 4);
  return true;
}

// The directory node holding a node.
static vx_status iso_parent(iso_vol *v, uint64_t node, uint64_t *parent) {
  uint32_t dir = node == ISO_ROOT ? v->root_lba : iso_node_dir(node);
  if (dir == v->root_lba) {
    *parent = ISO_ROOT;
    return VX_OK;
  }
  // The directory's ".." names the grandparent (or Rock Ridge's PL does,
  // for a relocated one); its records, the one naming this directory.
  iso_rec dot, up;
  uint32_t next;
  vx_status st = iso_record_at(v, dir, ISO_SECTOR, 0, &dot, &next);
  if (st == VX_OK) st = iso_record_at(v, dir, iso_u32(dot.b + 10), next, &up, &next);
  if (st != VX_OK) return st == VX_ERR_NOT_FOUND ? VX_ERR_IO : st;
  uint32_t grand = iso_u32(up.b + 2);
  if (v->kind == ISO_ROCK) iso_each_su(v, &up, v->susp_skip, iso_pl, &grand);
  iso_iter it = {.lba = grand, .len = v->root_len};
  if (grand != v->root_lba) {
    iso_rec gdot;
    if ((st = iso_record_at(v, grand, ISO_SECTOR, 0, &gdot, &next)) != VX_OK) return st;
    it.len = iso_u32(gdot.b + 10);
  }
  iso_entry e;
  while ((st = iso_dir_next(v, &it, &e)) == VX_OK)
    if (e.dir && e.lba == dir) {
      *parent = e.node;
      return VX_OK;
    }
  return st == VX_ERR_NOT_FOUND ? VX_ERR_IO : st;
}

// Up to *count bytes of a file from offset into buf; *count, what was read.
static vx_status iso_read(iso_vol *v, const iso_entry *f, uint64_t offset, uint8_t *buf, uint32_t *count) {
  if (f->dir || f->link) return VX_ERR_INVALID;
  if (offset >= f->size) {
    *count = 0;
    return VX_OK;
  }
  if (*count > f->size - offset) *count = (uint32_t)(f->size - offset);
  for (uint32_t done = 0; done < *count;) {
    uint64_t sector = f->lba + (offset + done) / ISO_SECTOR;
    uint32_t at = (uint32_t)((offset + done) % ISO_SECTOR), n = ISO_SECTOR - at;
    if (n > *count - done) n = *count - done;
    if (at == 0 && n == ISO_SECTOR) { // whole sectors: past the cache
      uint32_t run = (*count - done) / ISO_SECTOR;
      if (run > 64) run = 64;
      if ((v->sectors && sector + run > v->sectors) ||
          !v->dev.read(v->dev.ctx, sector * ISO_SECTOR, run * ISO_SECTOR, buf + done))
        return VX_ERR_IO;
      n = run * ISO_SECTOR;
    } else {
      const uint8_t *s = iso_sector(v, sector);
      if (!s) return VX_ERR_IO;
      memcpy(buf + done, s + at, n);
    }
    done += n;
  }
  return VX_OK;
}
