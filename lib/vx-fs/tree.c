// vx-fs trees (docs/11 §3): copy-on-write Bε trees, after gefs's tree.c.
//
// A leaf holds values, sorted by key. A pivot holds, in its first half, its
// children (a key, a block pointer and the child's fill each) and, in its
// second, a buffer of messages bound for them. A key belongs to the last
// child whose key is at most it, or to the first child if none is. Changes
// are messages: an upsert adds them to the root's buffer. When they do not
// fit there, the messages for the child that has the most of them are pushed
// into it, recursively; at a leaf they are applied. A node that overflows
// splits into as many as it takes. A child left less than a quarter full is
// merged with a neighbor, or the two share their contents if they do not fit
// in one (a rotation). Every change makes new blocks up the path to a new
// root, and frees the old ones (blk.c).
//
// Where gefs pulls as many of a buffer's messages as fit and splits in two,
// this pushes a child's messages whole and splits as many ways as it needs.
// The format is gefs's (in our byte order).
//
// A lookup applies to the leaf's value the messages for its key buffered on
// the path, the deepest (oldest) first. A scan does the same for one leaf's
// range at a time, entering the tree again from its root for each, so a scan
// sees changes made between its calls and never holds blocks across them.

#pragma once

#include "blk.c"

// A tree, and the context its changes are made in: the generation its new
// blocks are born in, its branch's base, and whether it is the snapshot
// tree (blk.c's frees depend on all three).
typedef struct vxfs_tree {
  vxfs_bptr root;
  uint32_t height; // 1: the root is a leaf
  uint64_t memgen, base;
  bool snap;
} vxfs_tree;

// Changes to t are made from here on.
static void tree_enter(vxfs *fs, const vxfs_tree *t) {
  fs->gen = t->memgen, fs->base = t->base, fs->snaptree = t->snap;
}

// A pivot's child, its key copied out of the block it came from.
typedef struct vxfs_kid {
  vxfs_bptr bp;
  uint16_t fill, nk;
  uint8_t k[VXFS_KEYMAX];
} vxfs_kid;

typedef struct kids {
  vxfs_kid *v;
  uint32_t n, cap;
} kids;

static constexpr uint32_t VXFS_UNDERFULL = VXFS_BLKSZ / 4;

// --- Entries in blocks ---

static vxfs_msg tab_get(const uint8_t *d, uint32_t i, bool msgs) {
  const uint8_t *p = d + vxfs_get16(d + (size_t)2 * i);
  vxfs_msg m = {};
  if (msgs) m.op = *p++;
  m.nk = vxfs_get16(p);
  m.k = p + 2;
  p += 2 + m.nk;
  m.nv = vxfs_get16(p);
  m.v = p + 2;
  return m;
}

// The bytes an entry takes in a table, its offset included.
static uint32_t ent_size(const vxfs_msg *m, bool msgs) {
  return 2u + (msgs ? 1u : 0u) + 2u + m->nk + 2u + m->nv;
}
static uint32_t kid_size(const vxfs_kid *k) { return 2u + 2u + k->nk + 2u + VXFS_PTRSZ + 2u; }

// Packs entries into a table of `spc` bytes at d, entries from the end;
// the bytes they take, offsets apart.
static uint16_t tab_pack(uint8_t *d, uint32_t spc, const vxfs_msg *e, uint32_t n, bool msgs) {
  uint32_t used = 0;
  for (uint32_t i = 0; i < n; i++) {
    used += ent_size(&e[i], msgs) - 2;
    uint8_t *p = d + spc - used;
    vxfs_put16(d + (size_t)2 * i, (uint16_t)(spc - used));
    if (msgs) *p++ = e[i].op;
    vxfs_put16(p, e[i].nk);
    memcpy(p + 2, e[i].k, e[i].nk);
    p += 2 + e[i].nk;
    vxfs_put16(p, e[i].nv);
    if (e[i].nv) memcpy(p + 2, e[i].v, e[i].nv);
  }
  return (uint16_t)used;
}

static uint16_t kids_pack(uint8_t *d, const vxfs_kid *k, uint32_t n) {
  uint32_t used = 0;
  for (uint32_t i = 0; i < n; i++) {
    used += kid_size(&k[i]) - 2;
    uint8_t *p = d + VXFS_PIVSPC - used;
    vxfs_put16(d + (size_t)2 * i, (uint16_t)(VXFS_PIVSPC - used));
    vxfs_put16(p, k[i].nk);
    memcpy(p + 2, k[i].k, k[i].nk);
    p += 2 + k[i].nk;
    vxfs_put16(p, VXFS_PTRSZ + 2);
    vxfs_packbp(p + 2, k[i].bp);
    vxfs_put16(p + 2 + VXFS_PTRSZ, k[i].fill);
  }
  return (uint16_t)used;
}

static uint16_t blk_fill(const vxfs_blk *b) {
  return (uint16_t)(2 * b->nval + b->valsz + 2 * b->nbuf + b->bufsz);
}

static bool kids_push(vxfs *fs, kids *ks, const uint8_t *k, uint16_t nk, vxfs_bptr bp, uint16_t fill) {
  if (!fs_grow(fs, (void **)&ks->v, ks->n, &ks->cap, sizeof *ks->v)) return false;
  vxfs_kid *d = &ks->v[ks->n++];
  d->bp = bp, d->fill = fill, d->nk = nk;
  memcpy(d->k, k, nk);
  return true;
}

static void kids_free(vxfs *fs, kids *ks) {
  fs_release(fs, ks->v, ks->cap * sizeof *ks->v);
  *ks = (kids){};
}

// Replaces ks[at, at + drop) with the entries of `with`.
static bool kids_splice(vxfs *fs, kids *ks, uint32_t at, uint32_t drop, const kids *with) {
  if (ks->n - drop + with->n > ks->cap) {
    uint32_t cap = ks->n - drop + with->n;
    vxfs_kid *more = fs_alloc(fs, cap * sizeof *more);
    if (!more) return false;
    if (ks->n) memcpy(more, ks->v, ks->n * sizeof *more);
    fs_release(fs, ks->v, ks->cap * sizeof *ks->v);
    ks->v = more, ks->cap = cap;
  }
  memmove(&ks->v[at + with->n], &ks->v[at + drop], (ks->n - at - drop) * sizeof *ks->v);
  if (with->n) memcpy(&ks->v[at], with->v, with->n * sizeof *ks->v);
  ks->n = ks->n - drop + with->n;
  return true;
}

// The child of `ks` that key k belongs to.
static uint32_t kids_route(const vxfs_kid *ks, uint32_t n, const uint8_t *k, uint16_t nk) {
  uint32_t lo = 1, hi = n; // the first child takes every key below the second's
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (vxfs_keycmp(ks[mid].k, ks[mid].nk, k, nk) <= 0)
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo - 1;
}

static bool block_kids(vxfs *fs, const vxfs_blk *b, kids *ks) {
  for (uint32_t i = 0; i < b->nval; i++) {
    vxfs_msg v = tab_get(b->data, i, false);
    if (!kids_push(fs, ks, v.k, v.nk, vxfs_unpackbp(v.v), vxfs_get16(v.v + VXFS_PTRSZ))) return false;
  }
  return true;
}

// --- Messages applied to a value ---

// The Kdat value `v` names a block of its own: one that a change to it frees.
static bool owns_block(const vxfs_msg *kv) {
  return kv->nk && kv->k[0] == VXFS_KDAT && kv->nv == 1 + VXFS_PTRSZ && kv->v[0] == VXFS_VREF;
}

// Whether an Owstat's payload is one: its flags byte, then exactly the
// fields those flags name. Checked when the message is taken, so one that
// cannot apply never reaches a buffer (M5 step 10).
static bool wstat_well_formed(const vxfs_msg *m) {
  if (!m->nv) return false;
  static const uint8_t WIDTH[8] = {8, 4, 8, 8, 4, 4, 4, 8};
  uint32_t need = 0;
  for (int i = 0; i < 8; i++)
    if (m->v[0] & 1 << i) need += WIDTH[i];
  return m->nv - 1 == need;
}

// Owstat on a packed entry, in place.
static bool wstat(uint8_t *v, const vxfs_msg *m) {
  if (!wstat_well_formed(m)) return false;
  vxfs_dir d = vxfs_unpackdir(v);
  const uint8_t *p = m->v;
  uint8_t f = *p++;
  d.qid_vers++;
  if (f & VXFS_WSIZE) d.length = vxfs_get64(p), p += 8;
  if (f & VXFS_WMODE) d.mode = vxfs_get32(p), d.qid_type = (uint8_t)(d.mode >> 24), p += 4;
  if (f & VXFS_WMTIME) d.mtime = (int64_t)vxfs_get64(p), p += 8;
  if (f & VXFS_WATIME) d.atime = (int64_t)vxfs_get64(p), p += 8;
  if (f & VXFS_WUID) d.uid = vxfs_get32(p), p += 4;
  if (f & VXFS_WGID) d.gid = vxfs_get32(p), p += 4;
  if (f & VXFS_WMUID) d.muid = vxfs_get32(p), p += 4;
  if (f & VXFS_WCTIME) d.ctime = (int64_t)vxfs_get64(p);
  vxfs_packdir(v, &d);
  return true;
}

// Applies m to the value kv (kv->v nullptr: there is none). `scratch` is a
// buffer of VXFS_DIRSZ bytes the value may be copied to, to be changed.
// False if the message cannot apply: the tree is damaged.
static bool apply(vxfs_msg *kv, const vxfs_msg *m, uint8_t *scratch) {
  switch (m->op) {
  case VXFS_OINSERT: kv->v = m->v ? m->v : (const uint8_t *)"", kv->nv = m->nv; return true;
  case VXFS_ODELETE: // of a key that is not there too: nothing to do (it cannot be told at upsert)
  case VXFS_OCLEARB:
  case VXFS_OCLOBBER: kv->v = nullptr, kv->nv = 0; return true;
  case VXFS_OWSTAT:
    if (!kv->v || kv->nv != VXFS_DIRSZ) return false;
    if (kv->v != scratch) memmove(scratch, kv->v, VXFS_DIRSZ);
    kv->v = scratch;
    return wstat(scratch, m);
  default: return false;
  }
}

// --- Writing nodes ---

// Cuts n entries of the given sizes into parts that each fit `spc`, as even
// as it can: cuts[p] is the first entry after part p. The number of parts.
static uint32_t plan(vxfs *fs, const uint32_t *size, uint32_t n, uint32_t spc, uint32_t **cuts) {
  uint64_t total = 0;
  for (uint32_t i = 0; i < n; i++) total += size[i];
  for (uint32_t parts = (uint32_t)((total + spc - 1) / spc);; parts++) {
    if (!parts) parts = 1;
    uint32_t *c = fs_alloc(fs, parts * sizeof *c);
    if (!c) return 0;
    uint64_t left = total;
    uint32_t i = 0;
    bool fits = true;
    for (uint32_t p = 0; p < parts && fits; p++) {
      uint64_t target = left / (parts - p), sz = 0;
      if (p + 1 == parts) target = left;
      while (i < n && (sz < target || p + 1 == parts) && sz + size[i] <= spc) sz += size[i++];
      left -= sz;
      c[p] = i;
      if (p + 1 == parts && i < n) fits = false;
    }
    if (fits) {
      *cuts = c;
      return parts;
    }
    fs_release(fs, c, parts * sizeof *c);
  }
}

// Writes leaves holding the values e[0, n), and adds them to `out`; the
// first keyed `low` if it has one.
static bool write_leaves(vxfs *fs, const vxfs_msg *e, uint32_t n, const uint8_t *low, uint16_t nlow,
                         kids *out) {
  if (!n) return true;
  uint32_t *size = fs_alloc(fs, n * sizeof *size), *cuts = nullptr, parts = 0;
  if (!size) return false;
  for (uint32_t i = 0; i < n; i++) size[i] = ent_size(&e[i], false);
  parts = plan(fs, size, n, VXFS_LEAFSPC, &cuts);
  bool ok = parts > 0;
  for (uint32_t p = 0, at = 0; ok && p < parts; at = cuts[p++]) {
    vxfs_blk *b = vxfs_new_block(fs, VXFS_TLEAF);
    if (!b) {
      ok = false;
      break;
    }
    b->nval = (uint16_t)(cuts[p] - at);
    b->valsz = tab_pack(b->data, VXFS_LEAFSPC, e + at, b->nval, false);
    ok = vxfs_write_block(fs, b);
    bool uselow = p == 0 && nlow && vxfs_keycmp(low, nlow, e[at].k, e[at].nk) <= 0;
    const uint8_t *k = uselow ? low : e[at].k;
    uint16_t nk = uselow ? nlow : e[at].nk;
    ok = ok && kids_push(fs, out, k, nk, b->bp, blk_fill(b));
    vxfs_drop(fs, b);
  }
  fs_release(fs, cuts, parts * sizeof *cuts);
  fs_release(fs, size, n * sizeof *size);
  return ok;
}

// Writes pivots holding the children ks and the messages m[0, nm) bound
// for them (which fit one buffer), and adds them to `out`.
static bool write_pivots(vxfs *fs, const kids *ks, const vxfs_msg *m, uint32_t nm, const uint8_t *low,
                         uint16_t nlow, kids *out) {
  if (!ks->n) return nm == 0 || fs_fail(fs, VX_ERR_INVALID);
  uint32_t *size = fs_alloc(fs, ks->n * sizeof *size), *cuts = nullptr, parts = 0;
  if (!size) return false;
  for (uint32_t i = 0; i < ks->n; i++) size[i] = kid_size(&ks->v[i]);
  parts = plan(fs, size, ks->n, VXFS_PIVSPC, &cuts);
  bool ok = parts > 0;
  uint32_t mi = 0;
  for (uint32_t p = 0, at = 0; ok && p < parts; at = cuts[p++]) {
    // Its messages: those below the next part's first key.
    uint32_t mend = mi;
    if (cuts[p] == ks->n)
      mend = nm;
    else
      while (mend < nm && vxfs_keycmp(m[mend].k, m[mend].nk, ks->v[cuts[p]].k, ks->v[cuts[p]].nk) < 0) mend++;
    uint32_t bufsz = 0;
    for (uint32_t i = mi; i < mend; i++) bufsz += ent_size(&m[i], true);
    vxfs_blk *b = bufsz <= VXFS_BUFSPC ? vxfs_new_block(fs, VXFS_TPIVOT) : nullptr;
    if (!b) {
      ok = bufsz <= VXFS_BUFSPC ? false : fs_fail(fs, VX_ERR_INVALID);
      break;
    }
    b->nval = (uint16_t)(cuts[p] - at);
    b->valsz = kids_pack(b->data, ks->v + at, b->nval);
    b->nbuf = (uint16_t)(mend - mi);
    b->bufsz = tab_pack(b->data + VXFS_PIVSPC, VXFS_BUFSPC, m + mi, b->nbuf, true);
    mi = mend;
    ok = vxfs_write_block(fs, b);
    const vxfs_kid *first = &ks->v[at];
    bool uselow = p == 0 && nlow && vxfs_keycmp(low, nlow, first->k, first->nk) <= 0;
    const uint8_t *k = uselow ? low : first->k;
    uint16_t nk = uselow ? nlow : first->nk;
    ok = ok && kids_push(fs, out, k, nk, b->bp, blk_fill(b));
    vxfs_drop(fs, b);
  }
  fs_release(fs, cuts, parts * sizeof *cuts);
  fs_release(fs, size, ks->n * sizeof *size);
  return ok;
}

// --- Upserting ---

static bool put(vxfs *fs, vxfs_bptr bp, uint32_t level, const uint8_t *low, uint16_t nlow, const vxfs_msg *in,
                uint32_t nin, kids *out);

// A leaf with messages applied: its new values, written as leaves.
static bool put_leaf(vxfs *fs, vxfs_blk *b, const uint8_t *low, uint16_t nlow, const vxfs_msg *in,
                     uint32_t nin, kids *out) {
  uint32_t nres = 0, nwstat = 0;
  for (uint32_t j = 0; j < nin; j++) nwstat += in[j].op == VXFS_OWSTAT;
  vxfs_msg *res = fs_alloc(fs, ((size_t)b->nval + nin + 1) * sizeof *res);
  uint8_t *scratch = fs_alloc(fs, (size_t)(nwstat + 1) * VXFS_DIRSZ);
  bool ok = res && scratch;
  uint32_t i = 0, j = 0, used = 0;
  while (ok && (i < b->nval || j < nin)) {
    vxfs_msg kv = {};
    int c = 0;
    if (i == b->nval)
      c = 1;
    else if (j == nin)
      c = -1;
    vxfs_msg v = i < b->nval ? tab_get(b->data, i, false) : (vxfs_msg){};
    if (c == 0) c = vxfs_keycmp(v.k, v.nk, in[j].k, in[j].nk);
    if (c < 0) { // a value no message changes
      res[nres++] = v;
      i++;
      continue;
    }
    if (c == 0) {
      kv = v;
      i++;
    } else {
      kv = (vxfs_msg){.k = in[j].k, .nk = in[j].nk};
    }
    uint8_t *slot = scratch + (size_t)used * VXFS_DIRSZ;
    bool wrote = false;
    for (; ok && j < nin && vxfs_keycmp(in[j].k, in[j].nk, kv.k, kv.nk) == 0; j++) {
      // A data block the value names is the tree's to free once the value goes.
      vxfs_msg was = kv;
      if (kv.v && owns_block(&kv) && in[j].op != VXFS_OCLOBBER && in[j].op != VXFS_OWSTAT)
        ok = vxfs_free(fs, vxfs_unpackbp(kv.v + 1));
      ok = ok && apply(&kv, &in[j], slot);
      if (!ok && fs->err == VX_OK) fs_fail(fs, VX_ERR_INVALID);
      wrote = wrote || (kv.v == slot && was.v != slot);
    }
    if (wrote) used++;
    if (kv.v) res[nres++] = kv;
  }
  ok = ok && vxfs_free(fs, b->bp) && write_leaves(fs, res, nres, low, nlow, out);
  fs_release(fs, scratch, (size_t)(nwstat + 1) * VXFS_DIRSZ);
  fs_release(fs, res, ((size_t)b->nval + nin + 1) * sizeof *res);
  return ok;
}

// Merges the children ks[l] and ks[l + 1], both at `level`, into one, or
// shares their contents between two. Pivots are left as they are if their
// buffers together do not fit one.
static bool merge_pair(vxfs *fs, kids *ks, uint32_t l, uint32_t level) {
  uint16_t type = level == 1 ? VXFS_TLEAF : VXFS_TPIVOT;
  vxfs_blk *a = vxfs_get(fs, ks->v[l].bp, type), *b = a ? vxfs_get(fs, ks->v[l + 1].bp, type) : nullptr;
  bool ok = b != nullptr;
  kids made = {}, inner = {};
  vxfs_msg *e = nullptr;
  uint32_t ne = 0, cap = 0;
  if (ok && level == 1) {
    cap = (uint32_t)a->nval + b->nval;
    ok = (e = fs_alloc(fs, (cap + 1) * sizeof *e)) != nullptr;
    for (uint32_t i = 0; ok && i < a->nval; i++) e[ne++] = tab_get(a->data, i, false);
    for (uint32_t i = 0; ok && i < b->nval; i++) e[ne++] = tab_get(b->data, i, false);
    ok = ok && write_leaves(fs, e, ne, ks->v[l].k, ks->v[l].nk, &made);
  } else if (ok) {
    if ((uint32_t)2 * a->nbuf + a->bufsz + 2 * b->nbuf + b->bufsz > VXFS_BUFSPC)
      goto done; // not without a flush
    cap = (uint32_t)a->nbuf + b->nbuf;
    ok = (e = fs_alloc(fs, (cap + 1) * sizeof *e)) != nullptr && block_kids(fs, a, &inner);
    uint32_t first = inner.n;
    ok = ok && block_kids(fs, b, &inner);
    if (ok) { // b's first child keyed as b is, so b's keys below its first key still route to it
      inner.v[first].nk = ks->v[l + 1].nk;
      memcpy(inner.v[first].k, ks->v[l + 1].k, ks->v[l + 1].nk);
    }
    for (uint32_t i = 0; ok && i < a->nbuf; i++) e[ne++] = tab_get(a->data + VXFS_PIVSPC, i, true);
    for (uint32_t i = 0; ok && i < b->nbuf; i++) e[ne++] = tab_get(b->data + VXFS_PIVSPC, i, true);
    ok = ok && write_pivots(fs, &inner, e, ne, ks->v[l].k, ks->v[l].nk, &made);
  }
  ok = ok && vxfs_free(fs, a->bp) && vxfs_free(fs, b->bp) && kids_splice(fs, ks, l, 2, &made);
done:
  fs_release(fs, e, (cap + 1) * sizeof *e);
  kids_free(fs, &inner);
  kids_free(fs, &made);
  vxfs_drop(fs, b);
  vxfs_drop(fs, a);
  return ok;
}

// Messages ordered by key, a's before b's for the same key: b's are newer.
static void merge_msgs(vxfs_msg *to, const vxfs_msg *a, uint32_t na, const vxfs_msg *b, uint32_t nb) {
  uint32_t i = 0, j = 0, n = 0;
  while (i < na || j < nb)
    if (j == nb || (i < na && vxfs_keycmp(a[i].k, a[i].nk, b[j].k, b[j].nk) <= 0))
      to[n++] = a[i++];
    else
      to[n++] = b[j++];
}

static uint32_t msgs_size(const vxfs_msg *m, uint32_t n) {
  uint32_t sz = 0;
  for (uint32_t i = 0; i < n; i++) sz += ent_size(&m[i], true);
  return sz;
}

// A pivot with messages added: those that fit stay in its buffer; for as
// long as they do not, the messages for the child with the most are pushed
// into it.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree is tall, VXFS_MAXHEIGHT at most
static bool put_pivot(vxfs *fs, vxfs_blk *b, uint32_t level, const uint8_t *low, uint16_t nlow,
                      const vxfs_msg *in, uint32_t nin, kids *out) {
  kids ks = {};
  uint32_t nm = b->nbuf + nin, cap = nm + 1;
  vxfs_msg *own = fs_alloc(fs, cap * sizeof *own), *m = own ? fs_alloc(fs, cap * sizeof *m) : nullptr;
  uint32_t *bytes = nullptr, nbytes = 0;
  bool ok = m && block_kids(fs, b, &ks);
  if (ok && !ks.n) ok = fs_fail(fs, VX_ERR_INVALID);
  for (uint32_t i = 0; ok && i < b->nbuf; i++) own[i] = tab_get(b->data + VXFS_PIVSPC, i, true);
  if (ok) merge_msgs(m, own, b->nbuf, in, nin);
  while (ok && msgs_size(m, nm) > VXFS_BUFSPC) {
    // The bytes bound for each child, and the child with the most.
    if (nbytes < ks.n) {
      fs_release(fs, bytes, nbytes * sizeof *bytes);
      nbytes = ks.n;
      if (!(bytes = fs_alloc(fs, nbytes * sizeof *bytes))) {
        ok = false;
        break;
      }
    }
    memset(bytes, 0, ks.n * sizeof *bytes);
    for (uint32_t i = 0; i < nm; i++) bytes[kids_route(ks.v, ks.n, m[i].k, m[i].nk)] += ent_size(&m[i], true);
    uint32_t c = 0;
    for (uint32_t i = 1; i < ks.n; i++)
      if (bytes[i] > bytes[c]) c = i;
    uint32_t lo = 0;
    while (kids_route(ks.v, ks.n, m[lo].k, m[lo].nk) != c) lo++;
    uint32_t hi = lo;
    while (hi < nm && kids_route(ks.v, ks.n, m[hi].k, m[hi].nk) == c) hi++;

    kids made = {};
    vxfs_kid child = ks.v[c];
    ok = put(fs, child.bp, level - 1, child.k, child.nk, m + lo, hi - lo, &made) &&
         kids_splice(fs, &ks, c, 1, &made);
    memmove(m + lo, m + hi, (nm - hi) * sizeof *m);
    nm -= hi - lo;
    // A lone child left underfull joins a neighbor.
    if (ok && made.n == 1 && ks.n > 1 && ks.v[c].fill < VXFS_UNDERFULL)
      ok = merge_pair(fs, &ks, c + 1 < ks.n ? c : c - 1, level - 1);
    kids_free(fs, &made);
  }
  ok = ok && vxfs_free(fs, b->bp) && write_pivots(fs, &ks, m, nm, low, nlow, out);
  fs_release(fs, bytes, nbytes * sizeof *bytes);
  fs_release(fs, m, cap * sizeof *m);
  fs_release(fs, own, cap * sizeof *own);
  kids_free(fs, &ks);
  return ok;
}

// The node at bp, `level` above the leaves (1: a leaf), with messages in[]
// added, written anew as the nodes it takes (none if it is left empty), and
// those added to `out`.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree is tall, VXFS_MAXHEIGHT at most
static bool put(vxfs *fs, vxfs_bptr bp, uint32_t level, const uint8_t *low, uint16_t nlow, const vxfs_msg *in,
                uint32_t nin, kids *out) {
  vxfs_blk *b = vxfs_get(fs, bp, level == 1 ? VXFS_TLEAF : VXFS_TPIVOT);
  if (!b) return false;
  bool ok = level == 1 ? put_leaf(fs, b, low, nlow, in, nin, out)
                       : put_pivot(fs, b, level, low, nlow, in, nin, out);
  vxfs_drop(fs, b);
  return ok;
}

// An empty tree, a leaf with nothing in it, born in the context t names
// (fs->gen's if it names none).
[[maybe_unused]] static bool vxfs_tree_init(vxfs *fs, vxfs_tree *t) {
  if (!t->memgen) t->memgen = fs->gen;
  tree_enter(fs, t);
  vxfs_blk *b = vxfs_new_block(fs, VXFS_TLEAF);
  if (!b) return false;
  bool ok = vxfs_write_block(fs, b);
  t->root = b->bp, t->height = 1;
  vxfs_drop(fs, b);
  return ok;
}

// Applies messages to the tree, as one change: a new root, the old path
// freed. They are taken in key order, those for the same key in the order
// given; together they must fit a pivot's buffer. INVALID if they are not
// messages (the tree untouched), or the volume's error.
[[maybe_unused]] static vx_status vxfs_upsert(vxfs *fs, vxfs_tree *t, const vxfs_msg *msgs, uint32_t n) {
  if (fs->err != VX_OK) return fs->err;
  if (!n) return VX_OK;
  if (t->height < 1 || t->height > VXFS_MAXHEIGHT) { // put recurses on it: a damaged snapshot's
    fs_fail(fs, VX_ERR_INVALID);
    return VX_ERR_INVALID;
  }
  tree_enter(fs, t);
  uint32_t total = 0;
  for (uint32_t i = 0; i < n; i++) {
    const vxfs_msg *m = &msgs[i];
    if (m->op == VXFS_ONOP || m->op >= VXFS_NMSG || !m->nk || m->nk > VXFS_KEYMAX || m->nv > VXFS_INLMAX ||
        (m->nv && !m->v) || (m->op == VXFS_OWSTAT && !wstat_well_formed(m)))
      return VX_ERR_INVALID; // refused here, the tree untouched: a buffered message that cannot apply poisons it
    total += ent_size(m, true);
  }
  if (total > VXFS_BUFSPC) return VX_ERR_INVALID;
  // Sorted, stably: a merge sort, bottom up.
  vxfs_msg *a = fs_alloc(fs, n * sizeof *a), *s = a ? fs_alloc(fs, n * sizeof *s) : nullptr;
  if (!s) {
    fs_release(fs, a, n * sizeof *a);
    return fs->err;
  }
  memcpy(a, msgs, n * sizeof *a);
  for (uint32_t w = 1; w < n; w *= 2) {
    for (uint32_t lo = 0; lo < n; lo += 2 * w) {
      uint32_t mid = lo + w < n ? lo + w : n, hi = lo + 2 * w < n ? lo + 2 * w : n;
      merge_msgs(s + lo, a + lo, mid - lo, a + mid, hi - mid);
    }
    vxfs_msg *x = a;
    a = s, s = x;
  }

  kids out = {};
  bool ok = put(fs, t->root, t->height, nullptr, 0, a, n, &out);
  uint32_t height = t->height;
  // Grown: pivots above, until there is one root.
  while (ok && out.n > 1) {
    kids up = {};
    ok = write_pivots(fs, &out, nullptr, 0, nullptr, 0, &up);
    kids_free(fs, &out);
    out = up;
    height++;
    if (height > VXFS_MAXHEIGHT) ok = fs_fail(fs, VX_ERR_NO_MEMORY);
  }
  vxfs_tree nt = *t;
  if (ok && out.n == 0) {
    ok = vxfs_tree_init(fs, &nt); // emptied
  } else if (ok) {
    nt.root = out.v[0].bp, nt.height = height;
  }
  // Shrunk: a root pivot with one child and nothing buffered gives way to it.
  while (ok && nt.height > 1) {
    vxfs_blk *r = vxfs_get(fs, nt.root, VXFS_TPIVOT);
    if (!r) {
      ok = false;
      break;
    }
    bool lone = r->nval == 1 && r->nbuf == 0;
    vxfs_bptr child = lone ? vxfs_unpackbp(tab_get(r->data, 0, false).v) : (vxfs_bptr){};
    vxfs_drop(fs, r);
    if (!lone) break;
    ok = vxfs_free(fs, nt.root);
    nt.root = child, nt.height--;
  }
  kids_free(fs, &out);
  fs_release(fs, a, n * sizeof *a);
  fs_release(fs, s, n * sizeof *s);
  if (!ok) return fs->err != VX_OK ? fs->err : VX_ERR_INVALID;
  *t = nt;
  return VX_OK;
}

// --- Looking up ---

// The first entry of table d (n entries) whose key is at least k.
static uint32_t tab_search(const uint8_t *d, uint32_t n, bool msgs, const uint8_t *k, uint16_t nk) {
  uint32_t lo = 0, hi = n;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    vxfs_msg e = tab_get(d, mid, msgs);
    if (vxfs_keycmp(e.k, e.nk, k, nk) < 0)
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo;
}

// The path from the root to the leaf that key k belongs to, held: path[0]
// the root. Also the least key above the leaf's range, if there is one.
typedef struct vxfs_path {
  vxfs_blk *b[VXFS_MAXHEIGHT];
  uint32_t n;
  const uint8_t *hi; // into one of the blocks
  uint16_t nhi;
  bool has_hi;
} vxfs_path;

static void path_drop(vxfs *fs, vxfs_path *p) {
  for (uint32_t i = 0; i < p->n; i++) vxfs_drop(fs, p->b[i]);
  p->n = 0;
}

static bool descend(vxfs *fs, const vxfs_tree *t, const uint8_t *k, uint16_t nk, vxfs_path *p) {
  *p = (vxfs_path){};
  if (t->height < 1 || t->height > VXFS_MAXHEIGHT) return fs_fail(fs, VX_ERR_INVALID);
  vxfs_bptr bp = t->root;
  for (uint32_t level = t->height; level >= 1; level--) {
    vxfs_blk *b = vxfs_get(fs, bp, level == 1 ? VXFS_TLEAF : VXFS_TPIVOT);
    if (!b) {
      path_drop(fs, p);
      return false;
    }
    p->b[p->n++] = b;
    if (level == 1) break;
    uint32_t i = tab_search(b->data, b->nval, false, k, nk);
    // The child: the last whose key is at most k, else the first.
    if (i == b->nval || vxfs_keycmp(tab_get(b->data, i, false).k, tab_get(b->data, i, false).nk, k, nk) > 0)
      i = i ? i - 1 : 0;
    if (i + 1 < b->nval) {
      vxfs_msg next = tab_get(b->data, i + 1, false);
      p->hi = next.k, p->nhi = next.nk, p->has_hi = true; // deeper bounds are tighter
    }
    bp = vxfs_unpackbp(tab_get(b->data, i, false).v);
  }
  return true;
}

// The value of key k, copied to val (VXFS_INLMAX bytes) with its length in
// *nv: VX_OK, NOT_FOUND, or the volume's error.
[[maybe_unused]] static vx_status vxfs_lookup(vxfs *fs, const vxfs_tree *t, const uint8_t *k, uint16_t nk,
                                              uint8_t *val, uint16_t *nv) {
  if (fs->err != VX_OK) return fs->err;
  vxfs_path p;
  if (!descend(fs, t, k, nk, &p)) return fs->err;
  if (!p.n) return VX_ERR_INVALID; // descend holds the root at least
  vxfs_blk *leaf = p.b[p.n - 1];
  vxfs_msg kv = {.k = k, .nk = nk};
  uint32_t i = tab_search(leaf->data, leaf->nval, false, k, nk);
  if (i < leaf->nval) {
    vxfs_msg v = tab_get(leaf->data, i, false);
    if (vxfs_keycmp(v.k, v.nk, k, nk) == 0) kv = v;
  }
  uint8_t scratch[VXFS_DIRSZ];
  bool ok = true;
  for (uint32_t level = p.n - 1; ok && level-- > 0;) { // the deepest buffer first
    vxfs_blk *b = p.b[level];
    const uint8_t *buf = b->data + VXFS_PIVSPC;
    for (uint32_t j = tab_search(buf, b->nbuf, true, k, nk); ok && j < b->nbuf; j++) {
      vxfs_msg m = tab_get(buf, j, true);
      if (vxfs_keycmp(m.k, m.nk, k, nk) != 0) break;
      ok = apply(&kv, &m, scratch);
    }
  }
  if (ok && kv.v) memcpy(val, kv.v, kv.nv), *nv = kv.nv;
  path_drop(fs, &p);
  if (!ok) {
    fs_fail(fs, VX_ERR_INVALID);
    return fs->err;
  }
  return kv.v ? VX_OK : VX_ERR_NOT_FOUND;
}

// --- Scanning ---

// The keys with a prefix, in order: vxfs_scan_start, then vxfs_scan_next
// until it is false (fs->err says whether that was the end), then
// vxfs_scan_end. A leaf's range at a time, entered from the tree's root.
typedef struct vxfs_scan {
  const vxfs_tree *t;
  uint8_t pfx[VXFS_KEYMAX], lo[VXFS_KEYMAX];
  uint16_t npfx, nlo;
  bool done; // the batch held is the last
  uint8_t *bytes;
  size_t nbytes, capbytes;
  vxfs_kvp *ents;
  uint32_t nents, capents, at;
} vxfs_scan;

[[maybe_unused]] static void vxfs_scan_start(vxfs_scan *s, const vxfs_tree *t, const uint8_t *pfx,
                                             uint16_t npfx) {
  *s = (vxfs_scan){.t = t, .npfx = npfx, .nlo = npfx};
  if (npfx > VXFS_KEYMAX) { // no key has a longer prefix: nothing to scan (M5 step 10)
    s->npfx = s->nlo = 0, s->done = true, s->t = nullptr;
    return;
  }
  if (npfx) memcpy(s->pfx, pfx, npfx), memcpy(s->lo, pfx, npfx);
}

// As vxfs_scan_start, but from key `from` on (within the prefix): a scan
// taken up again where an earlier one stopped.
[[maybe_unused]] static void vxfs_scan_from(vxfs_scan *s, const vxfs_tree *t, const uint8_t *pfx,
                                            uint16_t npfx, const uint8_t *from, uint16_t nfrom) {
  vxfs_scan_start(s, t, pfx, npfx);
  if (s->done || nfrom > VXFS_KEYMAX) return; // past any key: from the prefix's start instead
  if (nfrom && vxfs_keycmp(from, nfrom, pfx, npfx) > 0) memcpy(s->lo, from, nfrom), s->nlo = nfrom;
}

[[maybe_unused]] static void vxfs_scan_end(vxfs *fs, vxfs_scan *s) {
  fs_release(fs, s->bytes, s->capbytes);
  fs_release(fs, s->ents, s->capents * sizeof *s->ents);
  *s = (vxfs_scan){};
}

static bool has_prefix(const vxfs_scan *s, const uint8_t *k, uint16_t nk) {
  return nk >= s->npfx && (!s->npfx || memcmp(k, s->pfx, s->npfx) == 0);
}

static void scan_emit(vxfs_scan *s, const vxfs_msg *kv) {
  vxfs_kvp *e = &s->ents[s->nents++];
  uint8_t *p = s->bytes + s->nbytes;
  memcpy(p, kv->k, kv->nk);
  if (kv->nv) memcpy(p + kv->nk, kv->v, kv->nv);
  *e = (vxfs_kvp){.k = p, .nk = kv->nk, .v = p + kv->nk, .nv = kv->nv};
  s->nbytes += (size_t)kv->nk + kv->nv;
}

// The next batch: the effective values in [lo, hi) of the leaf lo belongs to.
static bool scan_fill(vxfs *fs, vxfs_scan *s) {
  vxfs_path p;
  if (!descend(fs, s->t, s->lo, s->nlo, &p)) return false;
  if (!p.n) return fs_fail(fs, VX_ERR_INVALID); // descend holds the root at least
  // Room for every source entry.
  size_t need = (size_t)p.n * VXFS_BLKSZ;
  uint32_t nneed = (uint32_t)(need / 5);
  bool ok = true;
  if (s->capbytes < need) {
    fs_release(fs, s->bytes, s->capbytes);
    s->capbytes = 0;
    ok = (s->bytes = fs_alloc(fs, need)) != nullptr;
    if (ok) s->capbytes = need;
  }
  if (ok && s->capents < nneed) {
    fs_release(fs, s->ents, s->capents * sizeof *s->ents);
    s->capents = 0;
    ok = (s->ents = fs_alloc(fs, nneed * sizeof *s->ents)) != nullptr;
    if (ok) s->capents = nneed;
  }
  s->nbytes = s->nents = s->at = 0;
  // Cursors: the leaf's values from lo, and each pivot's messages in [lo, hi).
  vxfs_blk *leaf = p.b[p.n - 1];
  uint32_t vi = ok ? tab_search(leaf->data, leaf->nval, false, s->lo, s->nlo) : 0;
  uint32_t mi[VXFS_MAXHEIGHT] = {}, mend[VXFS_MAXHEIGHT] = {};
  for (uint32_t l = 0; ok && l + 1 < p.n; l++) {
    const uint8_t *buf = p.b[l]->data + VXFS_PIVSPC;
    mi[l] = tab_search(buf, p.b[l]->nbuf, true, s->lo, s->nlo);
    mend[l] = p.has_hi ? tab_search(buf, p.b[l]->nbuf, true, p.hi, p.nhi) : p.b[l]->nbuf;
  }
  uint8_t scratch[VXFS_DIRSZ];
  bool past = false; // beyond the prefix
  while (ok && !past) {
    // The least key among the sources.
    const uint8_t *k = nullptr;
    uint16_t nk = 0;
    if (vi < leaf->nval) {
      vxfs_msg v = tab_get(leaf->data, vi, false);
      k = v.k, nk = v.nk;
    }
    for (uint32_t l = 0; l + 1 < p.n; l++)
      if (mi[l] < mend[l]) {
        vxfs_msg m = tab_get(p.b[l]->data + VXFS_PIVSPC, mi[l], true);
        if (!k || vxfs_keycmp(m.k, m.nk, k, nk) < 0) k = m.k, nk = m.nk;
      }
    if (!k) break;
    if (!has_prefix(s, k, nk)) { // keys start at the prefix: one without it is past them
      past = true;
      break;
    }
    vxfs_msg kv = {.k = k, .nk = nk};
    if (vi < leaf->nval) {
      vxfs_msg v = tab_get(leaf->data, vi, false);
      if (vxfs_keycmp(v.k, v.nk, k, nk) == 0) kv = v, vi++;
    }
    for (uint32_t l = p.n - 1; ok && l-- > 0;) // the deepest first
      for (; ok && mi[l] < mend[l]; mi[l]++) {
        vxfs_msg m = tab_get(p.b[l]->data + VXFS_PIVSPC, mi[l], true);
        if (vxfs_keycmp(m.k, m.nk, k, nk) != 0) break;
        ok = apply(&kv, &m, scratch);
      }
    if (!ok) fs_fail(fs, VX_ERR_INVALID);
    if (ok && kv.v) scan_emit(s, &kv);
  }
  // The next batch starts at hi.
  s->done = past || !p.has_hi || !has_prefix(s, p.hi, p.nhi);
  if (!s->done) memcpy(s->lo, p.hi, p.nhi), s->nlo = p.nhi;
  path_drop(fs, &p);
  return ok;
}

// The next key and value: false at the end, or on an error (fs->err). They
// are valid until the next call.
[[maybe_unused]] static bool vxfs_scan_next(vxfs *fs, vxfs_scan *s, vxfs_kvp *kv) {
  while (s->at == s->nents) {
    if (fs->err != VX_OK || s->done || !scan_fill(fs, s)) return false;
  }
  *kv = s->ents[s->at++];
  return true;
}
