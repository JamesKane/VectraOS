// vx-tar: the boot image's archive format, ustar (POSIX.1-1988), read by svcd
// and bootfs and written by build's mkbootfs (docs/04 §3.4). Builds for the
// target and the host.
//
// Only what a boot image holds: regular files, directories, and hard links
// to a regular file earlier in the archive, read as that file's contents (one
// program under many names: sbase's box, ADR-0016). The reader is
// strict, because a boot image may be built by anyone with access to the ESP:
// every header's checksum and octal fields are checked, every file lies inside
// the image, and every path is relative, has no empty, "." or ".." component,
// and fits its fields. The first bad header ends the archive with INVALID; no
// entry after it is returned.
//
// The writer is deterministic: the same files in the same order give the same
// bytes (mtime, uid and gid are zero; names are as given), so images are
// reproducible (04 §3.3).

#pragma once

#include "../../abi/vx/abi.h"
#include "../vx-utf/utf.h"

static constexpr size_t VX_TAR_BLOCK = 512;
static constexpr size_t VX_TAR_MAX_PATH = 256; // prefix (155), '/', name (100)

typedef struct vx_tar_header {
  char name[100], mode[8], uid[8], gid[8], size[12], mtime[12], chksum[8];
  char typeflag, linkname[100], magic[6], version[2], uname[32], gname[32];
  char devmajor[8], devminor[8], prefix[155], pad[12];
} vx_tar_header;
static_assert(sizeof(vx_tar_header) == VX_TAR_BLOCK);

typedef struct vx_tar_entry {
  vx_str path; // into `buf`: "boot/svc/bootfs.ndb", without a trailing '/'
  bool dir;
  uint32_t mode;       // permission bits
  const uint8_t *data; // into the image; nullptr for a directory
  uint64_t size;
  char buf[VX_TAR_MAX_PATH + 1];
} vx_tar_entry;

typedef struct vx_tar {
  const uint8_t *image;
  size_t size, pos;
  bool done, failed;
} vx_tar;

// An octal field: digits, then NUL or space padding to its end. The field
// must hold at least one digit.
static bool tar_octal(const char *f, size_t n, uint64_t *out) {
  uint64_t v = 0;
  size_t i = 0;
  while (i < n && f[i] == ' ') i++; // some writers pad the front
  size_t digits = 0;
  for (; i < n && f[i] >= '0' && f[i] <= '7'; i++, digits++) {
    if (v >> 61) return false; // would overflow
    v = v * 8 + (uint64_t)(f[i] - '0');
  }
  for (; i < n; i++)
    if (f[i] != 0 && f[i] != ' ') return false;
  *out = v;
  return digits > 0;
}

// The length of a NUL-padded field, or n if it fills it.
static size_t tar_field_len(const char *f, size_t n) {
  size_t len = 0;
  while (len < n && f[len]) len++;
  for (size_t i = len; i < n; i++)
    if (f[i]) return SIZE_MAX; // bytes after the terminator
  return len;
}

// A relative path with no empty, "." or ".." component, and nothing
// unprintable. A directory's one trailing '/' is removed before this.
static bool tar_path_ok(vx_str p) {
  if (p.len == 0) return false;
  size_t start = 0;
  for (size_t i = 0; i <= p.len; i++) {
    if (i < p.len && p.ptr[i] != '/') continue;
    size_t n = i - start;
    if (n == 0 || (n == 1 && p.ptr[start] == '.') ||
        (n == 2 && p.ptr[start] == '.' && p.ptr[start + 1] == '.') || !vx_utf_name(p.ptr + start, n))
      return false; // and names as ADR-0013 has them: UTF-8, no control characters
    start = i + 1;
  }
  return true;
}

static uint32_t tar_checksum(const vx_tar_header *h) {
  const uint8_t *b = (const uint8_t *)h;
  uint32_t sum = 0;
  for (size_t i = 0; i < VX_TAR_BLOCK; i++)
    sum += (i >= 148 && i < 156) ? ' ' : b[i]; // the checksum field counts as spaces
  return sum;
}

[[maybe_unused]] static vx_tar vx_tar_open(const void *image, size_t size) {
  return (vx_tar){.image = image, .size = size};
}

static bool tar_zero_block(const uint8_t *b) {
  for (size_t i = 0; i < VX_TAR_BLOCK; i++)
    if (b[i]) return false;
  return true;
}

// The next entry, as its header has it; a link's target path in link (else
// ""), unresolved, with no data. NOT_FOUND at the end of the archive (a zero
// block, or the end of the image); INVALID at a bad header, and for every
// call after it.
static vx_status tar_entry(vx_tar *t, vx_tar_entry *e, char link[101]) {
  link[0] = 0;
  *e = (vx_tar_entry){};
  if (t->failed) return VX_ERR_INVALID;
  if (t->done || t->size - t->pos < VX_TAR_BLOCK || tar_zero_block(t->image + t->pos)) {
    t->done = true;
    return VX_ERR_NOT_FOUND;
  }
  vx_tar_header h;
  const uint8_t *src = t->image + t->pos;
  for (size_t i = 0; i < VX_TAR_BLOCK; i++) ((uint8_t *)&h)[i] = src[i]; // one copy, then checked
  t->failed = true;                                                      // until the header passes

  uint64_t sum, size, mode;
  if (!tar_octal(h.chksum, sizeof h.chksum, &sum) || sum != tar_checksum(&h)) return VX_ERR_INVALID;
  if (h.magic[0] != 'u' || h.magic[1] != 's' || h.magic[2] != 't' || h.magic[3] != 'a' || h.magic[4] != 'r')
    return VX_ERR_INVALID;
  if (!tar_octal(h.size, sizeof h.size, &size) || !tar_octal(h.mode, sizeof h.mode, &mode))
    return VX_ERR_INVALID;
  bool is_link = h.typeflag == '1';
  if (h.typeflag == '5')
    e->dir = true;
  else if (h.typeflag != '0' && h.typeflag != 0 && !is_link)
    return VX_ERR_INVALID; // no symbolic links, devices or extensions
  if (is_link && size) return VX_ERR_INVALID;
  if ((e->dir && size) || mode > 07777) return VX_ERR_INVALID;
  e->mode = (uint32_t)mode;

  size_t plen = tar_field_len(h.prefix, sizeof h.prefix), nlen = tar_field_len(h.name, sizeof h.name);
  if (plen == SIZE_MAX || nlen == SIZE_MAX) return VX_ERR_INVALID;
  size_t len = 0;
  for (size_t i = 0; i < plen; i++) e->buf[len++] = h.prefix[i];
  if (plen) e->buf[len++] = '/';
  for (size_t i = 0; i < nlen; i++) e->buf[len++] = h.name[i];
  if (e->dir && len && e->buf[len - 1] == '/') len--;
  e->buf[len] = 0;
  e->path = (vx_str){e->buf, len};
  if (!tar_path_ok(e->path)) return VX_ERR_INVALID;

  uint64_t blocks = (size + VX_TAR_BLOCK - 1) / VX_TAR_BLOCK;
  if (size > t->size || blocks > (t->size - t->pos) / VX_TAR_BLOCK - 1) return VX_ERR_INVALID;
  e->size = size;
  e->data = e->dir ? nullptr : src + VX_TAR_BLOCK;
  if (is_link) {
    size_t tlen = tar_field_len(h.linkname, sizeof h.linkname);
    if (tlen == SIZE_MAX || !tar_path_ok((vx_str){h.linkname, tlen})) return VX_ERR_INVALID;
    for (size_t i = 0; i < tlen; i++) link[i] = h.linkname[i];
    link[tlen] = 0;
    e->data = nullptr;
  }
  t->pos += (size_t)(1 + blocks) * VX_TAR_BLOCK;
  t->failed = false;
  return VX_OK;
}

// The regular file at path among the archive's first `before` bytes: what a
// link there names. Links are not followed, so none forms a cycle.
static bool tar_target(const uint8_t *image, size_t before, const char *path, vx_tar_entry *e) {
  vx_tar scan = {.image = image, .size = before};
  char link[101];
  while (tar_entry(&scan, e, link) == VX_OK) {
    if (e->dir || link[0]) continue;
    size_t i = 0;
    while (i < e->path.len && e->path.ptr[i] == path[i]) i++;
    if (i == e->path.len && !path[i]) return true;
  }
  return false;
}

// The next entry; a link reads as the regular file it names, earlier in the
// archive. NOT_FOUND at the end of the archive (a zero block, or the end of
// the image); INVALID at a bad header, and for every call after it.
[[maybe_unused]] static vx_status vx_tar_next(vx_tar *t, vx_tar_entry *e) {
  char link[101];
  size_t at = t->pos;
  vx_status st = tar_entry(t, e, link);
  if (st != VX_OK || !link[0]) return st;
  vx_tar_entry target;
  if (!tar_target(t->image, at, link, &target)) {
    t->failed = true;
    return VX_ERR_INVALID;
  }
  e->data = target.data;
  e->size = target.size;
  return VX_OK;
}

// Finds a file or directory by path. NOT_FOUND if the archive (up to any bad
// header) has none.
[[maybe_unused]] static vx_status vx_tar_find(const void *image, size_t size, vx_str path,
                                              vx_tar_entry *out) {
  vx_tar t = vx_tar_open(image, size);
  vx_status st;
  while ((st = vx_tar_next(&t, out)) == VX_OK) {
    if (out->path.len != path.len) continue;
    size_t i = 0;
    while (i < path.len && out->path.ptr[i] == path.ptr[i]) i++;
    if (i == path.len) return VX_OK;
  }
  return st == VX_ERR_INVALID ? st : VX_ERR_NOT_FOUND;
}

// --- Writing ---

typedef struct vx_tar_writer {
  uint8_t *buf;
  size_t cap, len;
  bool failed; // a bad path, or out of room; every later call is ignored
} vx_tar_writer;

static void tar_put_octal(char *f, size_t n, uint64_t v) {
  f[n - 1] = 0;
  for (size_t i = n - 1; i-- > 0;) {
    f[i] = (char)('0' + (v & 7));
    v >>= 3;
  }
}

// Adds a file (data, size bytes) or, with dir set, a directory, with its
// permission bits. The path is split into prefix and name where it must be.
[[maybe_unused]] static void vx_tar_add(vx_tar_writer *w, vx_str path, bool dir, uint32_t mode,
                                        const void *data, uint64_t size) {
  if (w->failed) return;
  uint64_t blocks = (size + VX_TAR_BLOCK - 1) / VX_TAR_BLOCK;
  vx_tar_header h = {};
  size_t split = 0; // the length of the prefix; 0 if the name holds it all
  bool fits = path.len <= sizeof h.name;
  for (size_t i = path.len; !fits && i-- > 0;)
    if (path.ptr[i] == '/' && i <= sizeof h.prefix && path.len - i - 1 <= sizeof h.name &&
        path.len - i - 1 > 0) {
      split = i;
      fits = true;
    }
  if (!fits || !tar_path_ok(path) || (dir && size) || mode > 07777 ||
      blocks + 1 > (w->cap - w->len) / VX_TAR_BLOCK) {
    w->failed = true;
    return;
  }
  for (size_t i = 0; i < split; i++) h.prefix[i] = path.ptr[i];
  size_t from = split ? split + 1 : 0;
  for (size_t i = from; i < path.len; i++) h.name[i - from] = path.ptr[i];
  tar_put_octal(h.mode, sizeof h.mode, mode);
  tar_put_octal(h.uid, sizeof h.uid, 0);
  tar_put_octal(h.gid, sizeof h.gid, 0);
  tar_put_octal(h.size, sizeof h.size, size);
  tar_put_octal(h.mtime, sizeof h.mtime, 0);
  h.typeflag = dir ? '5' : '0';
  for (int i = 0; i < 6; i++) h.magic[i] = "ustar"[i];
  h.version[0] = h.version[1] = '0';
  tar_put_octal(h.chksum, 7, tar_checksum(&h)); // six digits, a NUL, and a space
  h.chksum[7] = ' ';
  uint8_t *out = w->buf + w->len;
  for (size_t i = 0; i < VX_TAR_BLOCK; i++) out[i] = ((const uint8_t *)&h)[i];
  for (uint64_t i = 0; i < blocks * VX_TAR_BLOCK; i++)
    out[VX_TAR_BLOCK + i] = i < size ? ((const uint8_t *)data)[i] : 0;
  w->len += (size_t)(1 + blocks) * VX_TAR_BLOCK;
}

// Adds a hard link at path to target, a regular file added before it.
[[maybe_unused]] static void vx_tar_add_link(vx_tar_writer *w, vx_str path, vx_str target, uint32_t mode) {
  if (w->failed) return;
  size_t before = w->len;
  vx_tar_add(w, path, false, mode, nullptr, 0);
  if (w->failed) return;
  vx_tar_header *h = (vx_tar_header *)(w->buf + before);
  if (target.len > sizeof h->linkname || !tar_path_ok(target)) {
    w->failed = true;
    return;
  }
  for (size_t i = 0; i < target.len; i++) h->linkname[i] = target.ptr[i];
  h->typeflag = '1';
  for (size_t i = 0; i < sizeof h->chksum; i++) h->chksum[i] = ' ';
  tar_put_octal(h->chksum, 7, tar_checksum(h));
  h->chksum[7] = ' ';
}

// Ends the archive with its two zero blocks. Returns its length, or 0.
[[maybe_unused]] static size_t vx_tar_end(vx_tar_writer *w) {
  if (w->failed || w->cap - w->len < 2 * VX_TAR_BLOCK) return 0;
  for (size_t i = 0; i < 2 * VX_TAR_BLOCK; i++) w->buf[w->len + i] = 0;
  w->len += 2 * VX_TAR_BLOCK;
  return w->len;
}
