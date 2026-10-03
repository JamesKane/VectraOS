// vx-fs files (docs/11 §4): directories, files and symbolic links as keys
// in a branch's tree, for fsd (step 4) and host/vxfs alike.
//
// An entry is Kent(pqid, name), its value vxfs_dir; the root's is
// Kent(0, ""). Every entry has Kup(qid), naming its own Kent key, whose
// pqid is its parent (gefs has one for directories; fsd names files by
// qid, so it needs one for every entry, which with no hard links is one to
// one). Renaming an entry changes its Kup and no other, so its children's
// stay right. A
// file's data is Kdat(qid, off) for each block-aligned offset that holds
// any: a block pointer (VXFS_VREF) to a block of it, or the block's first
// bytes inline (VXFS_VINL), the rest zeros. A missing key reads as zeros. A
// file of no more than VXFS_INLINE bytes is kept inline whole; a longer one
// in blocks. A symbolic link is a file whose qid type has VXFS_QTSYMLINK,
// its target its data.
//
// Every change is one batch of upserts where it can be, so it is atomic:
// a create with its parent's new mtime, a rename across directories with a
// moved directory's Kup. A write or truncation that spans more blocks than
// one batch holds is several, each whole. Semantics are tmpfs's, so the two
// servers agree: a directory is removed only when empty (EXISTS if not), a
// rename replaces a file by a file or an empty directory by a directory, and
// a directory cannot be moved inside itself.

#pragma once

#include "vol.c"

enum : uint8_t { VXFS_QTDIR = 0x80, VXFS_QTSYMLINK = 0x02 };
enum : uint32_t { VXFS_DMDIR = 0x8000'0000, VXFS_DMSYMLINK = 0x0200'0000 };
static constexpr uint32_t VXFS_NAMEMAX = VXFS_KEYMAX - 9;
static constexpr uint32_t VXFS_INLINE = VXFS_INLMAX - 1; // a whole file kept inline, at most

// An entry, and the key it is found by.
typedef struct vxfs_file {
  vxfs_dir d;
  uint8_t key[VXFS_KEYMAX];
  uint16_t nkey;
} vxfs_file;

static uint16_t key_ent(uint8_t *k, uint64_t pqid, const uint8_t *name, uint16_t n) {
  k[0] = VXFS_KENT;
  vxfs_kput64(k + 1, pqid);
  if (n) memcpy(k + 9, name, n);
  return (uint16_t)(9 + n);
}

static uint16_t key_dat(uint8_t *k, uint64_t qid, uint64_t off) {
  k[0] = VXFS_KDAT;
  vxfs_kput64(k + 1, qid), vxfs_kput64(k + 9, off);
  return 17;
}

static uint16_t key_up(uint8_t *k, uint64_t qid) {
  k[0] = VXFS_KUP;
  vxfs_kput64(k + 1, qid);
  return 9;
}

static bool is_dir(const vxfs_file *f) { return f->d.mode & VXFS_DMDIR; }

static vx_status file_at(vxfs_vol *v, const vxfs_tree *t, const uint8_t *k, uint16_t nk, vxfs_file *f) {
  uint8_t val[VXFS_INLMAX];
  uint16_t nv = 0;
  vx_status st = vxfs_lookup(&v->fs, t, k, nk, val, &nv);
  if (st != VX_OK) return st;
  if (nv != VXFS_DIRSZ) return vol_bad(v);
  f->d = vxfs_unpackdir(val);
  memcpy(f->key, k, nk);
  f->nkey = nk;
  return VX_OK;
}

// A name a directory may hold: not empty, ".", "..", or with a '/' or NUL.
static bool name_ok(const char *name, uint16_t n) {
  if (!n || n > VXFS_NAMEMAX || (n == 1 && name[0] == '.') || (n == 2 && name[0] == '.' && name[1] == '.'))
    return false;
  for (uint16_t i = 0; i < n; i++)
    if (name[i] == '/' || !name[i]) return false;
  return true;
}

// --- Batches ---

typedef struct fbatch {
  vxfs_msg m[96];
  uint8_t bytes[96 * (VXFS_KEYMAX + 64)];
  uint32_t n, used, size;
} fbatch;

static vx_status fb_flush(vxfs_vol *v, vxfs_tree *t, fbatch *b) {
  vx_status st = vxfs_upsert(&v->fs, t, b->m, b->n);
  b->n = b->used = b->size = 0;
  if (st == VX_OK && !vxfs_end_op(&v->fs)) st = v->fs.err;
  return st;
}

// True if the message fits; flush first when it says so.
static bool fb_room(const fbatch *b, uint16_t nk, uint16_t nv) {
  return b->n < 96 && b->size + 7u + nk + nv <= VXFS_BUFSPC && b->used + nk + nv <= sizeof b->bytes;
}

static void fb_add(fbatch *b, uint8_t op, const uint8_t *k, uint16_t nk, const uint8_t *val, uint16_t nv) {
  uint8_t *p = b->bytes + b->used;
  memcpy(p, k, nk);
  if (nv) memcpy(p + nk, val, nv);
  b->m[b->n++] = (vxfs_msg){.op = op, .k = p, .nk = nk, .v = nv ? p + nk : nullptr, .nv = nv};
  b->used += nk + nv, b->size += 7u + nk + nv;
}

static vx_status fb_put(vxfs_vol *v, vxfs_tree *t, fbatch *b, uint8_t op, const uint8_t *k, uint16_t nk,
                        const uint8_t *val, uint16_t nv) {
  if (!fb_room(b, nk, nv)) {
    vx_status st = fb_flush(v, t, b);
    if (st != VX_OK) return st;
  }
  fb_add(b, op, k, nk, val, nv);
  return VX_OK;
}

// An Owstat for f: the fields `flags` names, from d.
static vx_status fb_wstat(vxfs_vol *v, vxfs_tree *t, fbatch *b, const uint8_t *k, uint16_t nk, uint8_t flags,
                          const vxfs_dir *d) {
  uint8_t w[1 + 8 + 4 + 8 + 8 + 4 + 4 + 4 + 8], *p = w + 1;
  w[0] = flags;
  if (flags & VXFS_WSIZE) vxfs_put64(p, d->length), p += 8;
  if (flags & VXFS_WMODE) vxfs_put32(p, d->mode), p += 4;
  if (flags & VXFS_WMTIME) vxfs_put64(p, (uint64_t)d->mtime), p += 8;
  if (flags & VXFS_WATIME) vxfs_put64(p, (uint64_t)d->atime), p += 8;
  if (flags & VXFS_WUID) vxfs_put32(p, d->uid), p += 4;
  if (flags & VXFS_WGID) vxfs_put32(p, d->gid), p += 4;
  if (flags & VXFS_WMUID) vxfs_put32(p, d->muid), p += 4;
  if (flags & VXFS_WCTIME) vxfs_put64(p, (uint64_t)d->ctime), p += 8;
  return fb_put(v, t, b, VXFS_OWSTAT, k, nk, w, (uint16_t)(p - w));
}

static fbatch *fb_new(vxfs_vol *v) {
  fbatch *b = fs_alloc(&v->fs, sizeof *b);
  if (b) b->n = b->used = b->size = 0;
  return b;
}

static vx_status fb_done(vxfs_vol *v, vxfs_tree *t, fbatch *b, vx_status st) {
  if (st == VX_OK && b->n) st = fb_flush(v, t, b);
  fs_release(&v->fs, b, sizeof *b);
  return st;
}

// --- Finding things ---

// The root of tree t.
[[maybe_unused]] static vx_status vxfs_root(vxfs_vol *v, const vxfs_tree *t, vxfs_file *f) {
  uint8_t k[9];
  return file_at(v, t, k, key_ent(k, 0, nullptr, 0), f);
}

// Name in directory dir: an entry, ".", or "..".
[[maybe_unused]] static vx_status vxfs_walk(vxfs_vol *v, const vxfs_tree *t, const vxfs_file *dir,
                                            const char *name, vxfs_file *f) {
  if (!is_dir(dir)) return VX_ERR_INVALID;
  uint16_t n = vxfs_namelen(name, VXFS_NAMEMAX);
  if (n == 1 && name[0] == '.') {
    *f = *dir;
    return VX_OK;
  }
  if (n == 2 && name[0] == '.' && name[1] == '.') {
    if (dir->nkey == 9 && vxfs_kget64(dir->key + 1) == 0) { // the root is its own parent
      *f = *dir;
      return VX_OK;
    }
    // The parent is the pqid of dir's own key; its entry is the key its Kup names.
    uint64_t pqid = vxfs_kget64(dir->key + 1);
    uint8_t k[9], up[VXFS_INLMAX];
    uint16_t nup = 0;
    vx_status st = vxfs_lookup(&v->fs, t, k, key_up(k, pqid), up, &nup);
    if (st != VX_OK) return st == VX_ERR_NOT_FOUND ? vol_bad(v) : st; // a directory has a Kup
    if (nup < 9 || nup > VXFS_KEYMAX || up[0] != VXFS_KENT) return vol_bad(v);
    return file_at(v, t, up, nup, f);
  }
  if (!name_ok(name, n)) return n > VXFS_NAMEMAX ? VX_ERR_RANGE : VX_ERR_NOT_FOUND;
  uint8_t k[VXFS_KEYMAX];
  return file_at(v, t, k, key_ent(k, dir->d.qid_path, (const uint8_t *)name, n), f);
}

// The entry whose qid is qid, by its Kup.
[[maybe_unused]] static vx_status vxfs_file_by_qid(vxfs_vol *v, const vxfs_tree *t, uint64_t qid,
                                                   vxfs_file *f) {
  uint8_t k[9], key[VXFS_INLMAX];
  uint16_t nk = 0;
  vx_status st = vxfs_lookup(&v->fs, t, k, key_up(k, qid), key, &nk);
  if (st != VX_OK) return st;
  bool orphan = nk == 9 && key[0] == VXFS_KORPHAN;
  if (!orphan && (nk < 9 || nk > VXFS_KEYMAX || key[0] != VXFS_KENT)) return vol_bad(v);
  st = file_at(v, t, key, nk, f);
  if (st == VX_OK && f->d.qid_path != qid) return vol_bad(v);
  return st;
}

// A path from the root, '/'-separated.
[[maybe_unused]] static vx_status vxfs_walk_path(vxfs_vol *v, const vxfs_tree *t, const char *path,
                                                 vxfs_file *f) {
  vx_status st = vxfs_root(v, t, f);
  char name[VXFS_NAMEMAX + 1];
  while (st == VX_OK && *path) {
    while (*path == '/') path++;
    uint32_t n = 0;
    while (path[n] && path[n] != '/') n++;
    if (!n) break;
    if (n > VXFS_NAMEMAX) return VX_ERR_RANGE;
    memcpy(name, path, n);
    name[n] = 0;
    vxfs_file next;
    st = vxfs_walk(v, t, f, name, &next);
    *f = next;
    path += n;
  }
  return st;
}

// Each entry of directory dir, to fn, in name order; fn returns false to stop.
[[maybe_unused]] static vx_status
vxfs_readdir(vxfs_vol *v, const vxfs_tree *t, const vxfs_file *dir,
             bool (*fn)(void *ctx, const char *name, uint16_t n, const vxfs_dir *d), void *ctx) {
  if (!is_dir(dir)) return VX_ERR_INVALID;
  uint8_t pfx[9];
  key_ent(pfx, dir->d.qid_path, nullptr, 0);
  vxfs_scan s;
  vxfs_scan_start(&s, t, pfx, 9);
  vxfs_kvp kv;
  bool go = true;
  while (go && vxfs_scan_next(&v->fs, &s, &kv)) {
    if (kv.nv != VXFS_DIRSZ || kv.nk <= 9) {
      vxfs_scan_end(&v->fs, &s);
      return vol_bad(v);
    }
    vxfs_dir d = vxfs_unpackdir(kv.v);
    go = fn(ctx, (const char *)kv.k + 9, (uint16_t)(kv.nk - 9), &d);
  }
  vxfs_scan_end(&v->fs, &s);
  return v->fs.err;
}

static bool any_entry(void *ctx, [[maybe_unused]] const char *name, [[maybe_unused]] uint16_t n,
                      [[maybe_unused]] const vxfs_dir *d) {
  *(bool *)ctx = true;
  return false;
}

static vx_status dir_empty(vxfs_vol *v, const vxfs_tree *t, const vxfs_file *dir, bool *empty) {
  bool any = false;
  vx_status st = vxfs_readdir(v, t, dir, any_entry, &any);
  *empty = !any;
  return st;
}

// --- Making things ---

// The root of a new, empty tree: a directory of `mode`, owned by uid.
[[maybe_unused]] static vx_status vxfs_mkroot(vxfs_vol *v, vxfs_tree *t, uint32_t mode, uint32_t uid,
                                              uint32_t gid, int64_t now) {
  uint8_t k[9], val[VXFS_DIRSZ];
  vxfs_dir d = {.qid_path = v->nextqid++,
                .qid_type = VXFS_QTDIR,
                .mode = (mode & 07777) | VXFS_DMDIR,
                .atime = now,
                .mtime = now,
                .ctime = now,
                .btime = now,
                .uid = uid,
                .gid = gid,
                .muid = uid};
  vxfs_packdir(val, &d);
  uint8_t uk[9];
  uint16_t nk = key_ent(k, 0, nullptr, 0);
  vxfs_msg m[2] = {{.op = VXFS_OINSERT, .k = k, .nk = nk, .v = val, .nv = VXFS_DIRSZ},
                   {.op = VXFS_OINSERT, .k = uk, .nk = key_up(uk, d.qid_path), .v = k, .nv = nk}};
  vx_status st = vxfs_upsert(&v->fs, t, m, 2);
  if (st == VX_OK && !vxfs_end_op(&v->fs)) st = v->fs.err;
  return st;
}

// A new entry `name` in dir: a directory if mode has VXFS_DMDIR, a symbolic
// link if VXFS_DMSYMLINK (its target written after), else a file. The
// directory's mtime and ctime become now.
[[maybe_unused]] static vx_status vxfs_create(vxfs_vol *v, vxfs_tree *t, const vxfs_file *dir,
                                              const char *name, uint32_t mode, uint32_t uid, uint32_t gid,
                                              int64_t now, vxfs_file *f) {
  if (!is_dir(dir)) return VX_ERR_INVALID;
  uint16_t n = vxfs_namelen(name, VXFS_NAMEMAX);
  if (!name_ok(name, n)) return n > VXFS_NAMEMAX ? VX_ERR_RANGE : VX_ERR_INVALID;
  if ((mode & VXFS_DMDIR) && (mode & VXFS_DMSYMLINK)) return VX_ERR_INVALID;
  vxfs_file there;
  vx_status st = vxfs_walk(v, t, dir, name, &there);
  if (st == VX_OK) return VX_ERR_EXISTS;
  if (st != VX_ERR_NOT_FOUND) return st;
  uint8_t qtype = 0;
  if (mode & VXFS_DMDIR) qtype = VXFS_QTDIR;
  if (mode & VXFS_DMSYMLINK) qtype = VXFS_QTSYMLINK;
  f->d = (vxfs_dir){.qid_path = v->nextqid++,
                    .qid_type = qtype,
                    .mode = mode & (VXFS_DMDIR | VXFS_DMSYMLINK | 07777),
                    .atime = now,
                    .mtime = now,
                    .ctime = now,
                    .btime = now,
                    .uid = uid,
                    .gid = gid,
                    .muid = uid};
  f->nkey = key_ent(f->key, dir->d.qid_path, (const uint8_t *)name, n);
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  uint8_t val[VXFS_DIRSZ];
  vxfs_packdir(val, &f->d);
  fb_add(b, VXFS_OINSERT, f->key, f->nkey, val, VXFS_DIRSZ);
  uint8_t k[9];
  fb_add(b, VXFS_OINSERT, k, key_up(k, f->d.qid_path), f->key, f->nkey);
  vxfs_dir pd = {.mtime = now, .ctime = now};
  st = fb_wstat(v, t, b, dir->key, dir->nkey, VXFS_WMTIME | VXFS_WCTIME, &pd);
  return fb_done(v, t, b, st);
}

// --- Data ---

// Block `off` of file qid (VXFS_BLKSZ bytes, zeros where it holds none).
static vx_status read_block(vxfs_vol *v, const vxfs_tree *t, uint64_t qid, uint64_t off, uint8_t *buf) {
  uint8_t k[17], val[VXFS_INLMAX];
  uint16_t nv = 0;
  vx_status st = vxfs_lookup(&v->fs, t, k, key_dat(k, qid, off), val, &nv);
  memset(buf, 0, VXFS_BLKSZ);
  if (st == VX_ERR_NOT_FOUND) return VX_OK;
  if (st != VX_OK) return st;
  if (nv >= 1 && val[0] == VXFS_VINL) {
    memcpy(buf, val + 1, nv - 1u);
    return VX_OK;
  }
  if (nv != 1 + VXFS_PTRSZ || val[0] != VXFS_VREF) return vol_bad(v);
  vxfs_blk *b = vxfs_get(&v->fs, vxfs_unpackbp(val + 1), VXFS_TDAT);
  if (!b) return v->fs.err;
  memcpy(buf, b->data, VXFS_BLKSZ);
  vxfs_drop(&v->fs, b);
  return VX_OK;
}

// Up to n bytes of f from off; the count read in *got (0 at or past the end).
[[maybe_unused]] static vx_status vxfs_read(vxfs_vol *v, const vxfs_tree *t, const vxfs_file *f, uint64_t off,
                                            void *buf, uint64_t n, uint64_t *got) {
  *got = 0;
  if (is_dir(f)) return VX_ERR_INVALID;
  if (off >= f->d.length) return VX_OK;
  if (n > f->d.length - off) n = f->d.length - off;
  static uint8_t blk[VXFS_BLKSZ];
  uint8_t *out = buf;
  while (*got < n) {
    uint64_t at = off + *got, base = at / VXFS_BLKSZ * VXFS_BLKSZ, in = at - base;
    uint64_t take = VXFS_BLKSZ - in < n - *got ? VXFS_BLKSZ - in : n - *got;
    vx_status st = read_block(v, t, f->d.qid_path, base, blk);
    if (st != VX_OK) return st;
    memcpy(out + *got, blk + in, take);
    *got += take;
  }
  return VX_OK;
}

// Block `off` of f as `data`: a new data block, or inline if f is small.
static vx_status put_block(vxfs_vol *v, vxfs_tree *t, fbatch *b, const vxfs_file *f, uint64_t off,
                           const uint8_t *data, uint64_t len) {
  uint8_t k[17], val[VXFS_INLMAX];
  uint16_t nk = key_dat(k, f->d.qid_path, off);
  if (len <= VXFS_INLINE) { // the whole file
    val[0] = VXFS_VINL;
    memcpy(val + 1, data, len);
    return fb_put(v, t, b, VXFS_OINSERT, k, nk, val, (uint16_t)(1 + len));
  }
  vxfs_blk *d = vxfs_new_data(&v->fs, t);
  if (!d) return v->fs.err;
  memcpy(d->data, data, VXFS_BLKSZ);
  bool ok = vxfs_write_block(&v->fs, d);
  val[0] = VXFS_VREF;
  vxfs_packbp(val + 1, d->bp);
  vxfs_drop(&v->fs, d);
  if (!ok) return v->fs.err;
  return fb_put(v, t, b, VXFS_OINSERT, k, nk, val, 1 + VXFS_PTRSZ);
}

// Writes n bytes at off to f (and f's entry, in memory too): its length if
// it grows, mtime and ctime now, muid.
[[maybe_unused]] static vx_status vxfs_write(vxfs_vol *v, vxfs_tree *t, vxfs_file *f, uint64_t off,
                                             const void *data, uint64_t n, int64_t now, uint32_t muid) {
  if (is_dir(f)) return VX_ERR_INVALID;
  if (off + n < off) return VX_ERR_RANGE;
  uint64_t was = f->d.length, len = off + n > was ? off + n : was;
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  static uint8_t blk[VXFS_BLKSZ];
  const uint8_t *in = data;
  vx_status st = VX_OK;
  if (len <= VXFS_INLINE) { // small: kept inline, whole
    st = read_block(v, t, f->d.qid_path, 0, blk);
    if (st == VX_OK) memcpy(blk + off, in, n), st = put_block(v, t, b, f, 0, blk, len);
  } else {
    // A file that was inline is in blocks from now: its block 0 is written
    // as one even if this write does not touch it.
    bool convert = was && was <= VXFS_INLINE && off >= VXFS_BLKSZ;
    if (convert && (st = read_block(v, t, f->d.qid_path, 0, blk)) == VX_OK)
      st = put_block(v, t, b, f, 0, blk, VXFS_BLKSZ);
    for (uint64_t at = off; st == VX_OK && at < off + n;) {
      uint64_t base = at / VXFS_BLKSZ * VXFS_BLKSZ, inb = at - base;
      uint64_t take = VXFS_BLKSZ - inb < off + n - at ? VXFS_BLKSZ - inb : off + n - at;
      if (take < VXFS_BLKSZ)
        st = read_block(v, t, f->d.qid_path, base, blk); // part of a block: the rest kept
      if (st != VX_OK) break;
      memcpy(blk + inb, in + (at - off), take);
      st = put_block(v, t, b, f, base, blk, VXFS_BLKSZ);
      at += take;
    }
  }
  f->d.length = len, f->d.mtime = f->d.ctime = now, f->d.muid = muid, f->d.qid_vers++;
  if (st == VX_OK)
    st = fb_wstat(v, t, b, f->key, f->nkey, (uint8_t)(VXFS_WSIZE | VXFS_WMTIME | VXFS_WCTIME | VXFS_WMUID),
                  &f->d);
  return fb_done(v, t, b, st);
}

// Every Kdat key of qid at or past `from`, cleared: the blocks they name freed.
static vx_status clear_data(vxfs_vol *v, vxfs_tree *t, fbatch *b, uint64_t qid, uint64_t from) {
  uint8_t pfx[9] = {VXFS_KDAT};
  vxfs_kput64(pfx + 1, qid);
  // Collected first: the tree is changed as the batch fills.
  uint64_t *offs = nullptr;
  uint32_t n = 0, cap = 0;
  vxfs_scan s;
  vxfs_scan_start(&s, t, pfx, 9);
  vxfs_kvp kv;
  while (vxfs_scan_next(&v->fs, &s, &kv))
    if (kv.nk == 17 && vxfs_kget64(kv.k + 9) >= from &&
        fs_grow(&v->fs, (void **)&offs, n, &cap, sizeof *offs))
      offs[n++] = vxfs_kget64(kv.k + 9);
  vxfs_scan_end(&v->fs, &s);
  vx_status st = v->fs.err;
  for (uint32_t i = 0; st == VX_OK && i < n; i++) {
    uint8_t k[17];
    st = fb_put(v, t, b, VXFS_OCLEARB, k, key_dat(k, qid, offs[i]), nullptr, 0);
  }
  fs_release(&v->fs, offs, cap * sizeof *offs);
  return st;
}

// --- Changing entries ---

typedef struct vxfs_attr {
  uint8_t valid; // VXFS_W* flags: the fields below to set
  uint64_t length;
  uint32_t mode, uid, gid;
  int64_t atime, mtime;
} vxfs_attr;

// Sets f's attributes as a says; ctime becomes now. A new length truncates
// or extends (with zeros); a directory or link has none to set.
[[maybe_unused]] static vx_status vxfs_setattr(vxfs_vol *v, vxfs_tree *t, vxfs_file *f, const vxfs_attr *a,
                                               int64_t now) {
  if ((a->valid & VXFS_WSIZE) && (is_dir(f) || (f->d.mode & VXFS_DMSYMLINK))) return VX_ERR_INVALID;
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  vx_status st = VX_OK;
  if ((a->valid & VXFS_WSIZE) && a->length < f->d.length) {
    static uint8_t blk[VXFS_BLKSZ];
    uint64_t keep = (a->length + VXFS_BLKSZ - 1) / VXFS_BLKSZ * VXFS_BLKSZ; // blocks wholly past the end go
    st = clear_data(v, t, b, f->d.qid_path, keep);
    uint64_t base = a->length / VXFS_BLKSZ * VXFS_BLKSZ, in = a->length - base;
    if (st == VX_OK && in) { // the last block's tail zeroed
      st = read_block(v, t, f->d.qid_path, base, blk);
      if (st == VX_OK) {
        memset(blk + in, 0, VXFS_BLKSZ - in);
        bool inline_whole = a->length <= VXFS_INLINE && f->d.length <= VXFS_INLINE;
        st = put_block(v, t, b, f, base, blk, inline_whole ? a->length : VXFS_BLKSZ);
      }
    }
  }
  if (a->valid & VXFS_WSIZE) f->d.length = a->length;
  if (a->valid & VXFS_WMODE) f->d.mode = (f->d.mode & (VXFS_DMDIR | VXFS_DMSYMLINK)) | (a->mode & 07777);
  if (a->valid & VXFS_WUID) f->d.uid = a->uid;
  if (a->valid & VXFS_WGID) f->d.gid = a->gid;
  if (a->valid & VXFS_WATIME) f->d.atime = a->atime;
  if (a->valid & VXFS_WMTIME) f->d.mtime = a->mtime;
  f->d.ctime = now;
  f->d.qid_vers++;
  uint8_t flags =
      (uint8_t)((a->valid & (VXFS_WSIZE | VXFS_WMODE | VXFS_WUID | VXFS_WGID | VXFS_WATIME | VXFS_WMTIME)) |
                VXFS_WCTIME);
  if (st == VX_OK) st = fb_wstat(v, t, b, f->key, f->nkey, flags, &f->d);
  return fb_done(v, t, b, st);
}

// Removes name from dir: a directory only if empty; a file's data cleared.
[[maybe_unused]] static vx_status vxfs_remove(vxfs_vol *v, vxfs_tree *t, const vxfs_file *dir,
                                              const char *name, int64_t now) {
  vxfs_file f;
  vx_status st = vxfs_walk(v, t, dir, name, &f);
  if (st != VX_OK) return st;
  if (f.nkey == dir->nkey && memcmp(f.key, dir->key, f.nkey) == 0) return VX_ERR_INVALID; // "." or ".."
  bool empty = true;
  if (is_dir(&f) && (st = dir_empty(v, t, &f, &empty)) != VX_OK) return st;
  if (!empty) return VX_ERR_EXISTS;
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  if (!is_dir(&f)) st = clear_data(v, t, b, f.d.qid_path, 0);
  uint8_t k[9];
  if (st == VX_OK) st = fb_put(v, t, b, VXFS_ODELETE, k, key_up(k, f.d.qid_path), nullptr, 0);
  if (st == VX_OK) st = fb_put(v, t, b, VXFS_ODELETE, f.key, f.nkey, nullptr, 0);
  vxfs_dir pd = {.mtime = now, .ctime = now};
  if (st == VX_OK) st = fb_wstat(v, t, b, dir->key, dir->nkey, VXFS_WMTIME | VXFS_WCTIME, &pd);
  return fb_done(v, t, b, st);
}

// --- Orphans: files removed while open (11 §4) ---

static uint16_t key_orphan(uint8_t *k, uint64_t qid) {
  k[0] = VXFS_KORPHAN;
  vxfs_kput64(k + 1, qid);
  return 9;
}

[[maybe_unused]] static bool vxfs_is_orphan(const vxfs_file *f) {
  return f->nkey == 9 && f->key[0] == VXFS_KORPHAN;
}

// Removes name, a file, from dir but keeps it: its entry moves to
// Korphan(qid), which its Kup names, so it is found by its qid still, and
// its data stays until vxfs_reap. One batch.
[[maybe_unused]] static vx_status vxfs_orphan(vxfs_vol *v, vxfs_tree *t, const vxfs_file *dir,
                                              const char *name, int64_t now) {
  vxfs_file f;
  vx_status st = vxfs_walk(v, t, dir, name, &f);
  if (st != VX_OK) return st;
  if (is_dir(&f)) return VX_ERR_INVALID; // a directory is removed, empty, or not at all
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  uint8_t ok[9], uk[9], val[VXFS_DIRSZ];
  uint16_t nok = key_orphan(ok, f.d.qid_path);
  vxfs_packdir(val, &f.d);
  fb_add(b, VXFS_ODELETE, f.key, f.nkey, nullptr, 0);
  fb_add(b, VXFS_OINSERT, ok, nok, val, VXFS_DIRSZ);
  fb_add(b, VXFS_OINSERT, uk, key_up(uk, f.d.qid_path), ok, nok);
  vxfs_dir pd = {.mtime = now, .ctime = now};
  st = fb_wstat(v, t, b, dir->key, dir->nkey, VXFS_WMTIME | VXFS_WCTIME, &pd);
  return fb_done(v, t, b, st);
}

// An orphan's end: its data cleared, its Korphan and Kup gone.
[[maybe_unused]] static vx_status vxfs_reap(vxfs_vol *v, vxfs_tree *t, uint64_t qid) {
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  vx_status st = clear_data(v, t, b, qid, 0);
  uint8_t k[9];
  if (st == VX_OK) st = fb_put(v, t, b, VXFS_ODELETE, k, key_orphan(k, qid), nullptr, 0);
  if (st == VX_OK) st = fb_put(v, t, b, VXFS_ODELETE, k, key_up(k, qid), nullptr, 0);
  return fb_done(v, t, b, st);
}

// Every orphan in tree t reaped: what a crash left of files removed while
// open, when the tree is first opened again. The count in *n.
[[maybe_unused]] static vx_status vxfs_reap_all(vxfs_vol *v, vxfs_tree *t, uint32_t *n) {
  *n = 0;
  for (;;) { // a few at a time: the tree changes as each goes
    uint64_t qid[32];
    uint32_t got = 0;
    uint8_t pfx = VXFS_KORPHAN;
    vxfs_scan s;
    vxfs_scan_start(&s, t, &pfx, 1);
    vxfs_kvp kv;
    while (got < 32 && vxfs_scan_next(&v->fs, &s, &kv))
      if (kv.nk == 9) qid[got++] = vxfs_kget64(kv.k + 1);
    vxfs_scan_end(&v->fs, &s);
    if (v->fs.err != VX_OK) return v->fs.err;
    if (!got) return VX_OK;
    for (uint32_t i = 0; i < got; i++) {
      vx_status st = vxfs_reap(v, t, qid[i]);
      if (st != VX_OK) return st;
    }
    *n += got;
  }
}

// Renames from/name to to/newname, replacing as POSIX does (see the top).
[[maybe_unused]] static vx_status vxfs_rename(vxfs_vol *v, vxfs_tree *t, const vxfs_file *from,
                                              const char *name, const vxfs_file *to, const char *newname,
                                              int64_t now) {
  if (!is_dir(to)) return VX_ERR_INVALID;
  uint16_t nn = vxfs_namelen(newname, VXFS_NAMEMAX);
  if (!name_ok(newname, nn)) return nn > VXFS_NAMEMAX ? VX_ERR_RANGE : VX_ERR_INVALID;
  vxfs_file f, there;
  vx_status st = vxfs_walk(v, t, from, name, &f);
  if (st != VX_OK) return st;
  if (!name_ok(name, vxfs_namelen(name, VXFS_NAMEMAX))) return VX_ERR_INVALID;
  // Not into itself: no directory from `to` up to the root is f.
  vxfs_file up = *to;
  for (uint32_t depth = 0;; depth++) {
    if (up.d.qid_path == f.d.qid_path) return VX_ERR_INVALID;
    if (up.nkey == 9 && vxfs_kget64(up.key + 1) == 0) break; // the root
    if (depth > 4096 || (st = vxfs_walk(v, t, &up, "..", &up)) != VX_OK) return st == VX_OK ? vol_bad(v) : st;
  }
  st = vxfs_walk(v, t, to, newname, &there);
  if (st == VX_OK) {
    if (there.d.qid_path == f.d.qid_path) return VX_OK;
    if (is_dir(&there) != is_dir(&f)) return is_dir(&there) ? VX_ERR_EXISTS : VX_ERR_INVALID;
    bool empty = true;
    if (is_dir(&there) && ((st = dir_empty(v, t, &there, &empty)) != VX_OK || !empty))
      return st != VX_OK ? st : VX_ERR_EXISTS;
    if ((st = vxfs_remove(v, t, to, newname, now)) != VX_OK) return st;
  } else if (st != VX_ERR_NOT_FOUND) {
    return st;
  }
  // One batch: the entry moved, a directory's Kup, both directories' times.
  fbatch *b = fb_new(v);
  if (!b) return v->fs.err;
  uint8_t k[VXFS_KEYMAX], val[VXFS_DIRSZ];
  uint16_t nk = key_ent(k, to->d.qid_path, (const uint8_t *)newname, nn);
  f.d.ctime = now;
  vxfs_packdir(val, &f.d);
  fb_add(b, VXFS_ODELETE, f.key, f.nkey, nullptr, 0);
  fb_add(b, VXFS_OINSERT, k, nk, val, VXFS_DIRSZ);
  uint8_t uk[9];
  fb_add(b, VXFS_OINSERT, uk, key_up(uk, f.d.qid_path), k, nk);
  vxfs_dir pd = {.mtime = now, .ctime = now};
  st = fb_wstat(v, t, b, from->key, from->nkey, VXFS_WMTIME | VXFS_WCTIME, &pd);
  if (st == VX_OK && to->d.qid_path != from->d.qid_path)
    st = fb_wstat(v, t, b, to->key, to->nkey, VXFS_WMTIME | VXFS_WCTIME, &pd);
  return fb_done(v, t, b, st);
}

// A symbolic link `name` in dir to target.
[[maybe_unused]] static vx_status vxfs_symlink(vxfs_vol *v, vxfs_tree *t, const vxfs_file *dir,
                                               const char *name, const char *target, uint32_t uid,
                                               uint32_t gid, int64_t now, vxfs_file *f) {
  uint64_t n = 0;
  while (target[n]) n++;
  if (!n || n > 4096) return VX_ERR_INVALID;
  vx_status st = vxfs_create(v, t, dir, name, VXFS_DMSYMLINK | 0777, uid, gid, now, f);
  return st == VX_OK ? vxfs_write(v, t, f, 0, target, n, now, uid) : st;
}

// Formats a volume as vxfs_format does, each branch given a root
// directory of `mode` owned by uid and gid; committed, left mounted.
[[maybe_unused]] static vx_status vxfs_mkfs(vxfs_vol *v, vxfs_dev dev, vxfs_mem mem, uint32_t cache,
                                            uint32_t narenas, const char *const *branches, uint32_t n,
                                            uint32_t mode, uint32_t uid, uint32_t gid, int64_t now) {
  vx_status st = vxfs_format(v, dev, mem, cache, narenas, branches, n);
  for (uint32_t i = 0; st == VX_OK && i < n; i++) {
    vxfs_branch *br;
    st = vxfs_branch_open(v, branches[i], &br);
    if (st == VX_OK) st = vxfs_mkroot(v, &br->t, mode, uid, gid, now);
  }
  if (st == VX_OK) st = vxfs_commit(v);
  return st;
}
