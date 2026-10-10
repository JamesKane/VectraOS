// vx-text: the piece tree, anchors and the undo tree (text.h says what each
// is); regex.c and sam.c, included at the end, are the command language.
//
// Nodes live in one array and name each other by index, 0 being none, so the
// array can grow. Each node is in two treaps: the text's order (l, r, up),
// summed for visible bytes, newlines and runes, and the index (il, ir),
// ordered by insertion and offset. Priorities come from the text's own
// generator, so a run is reproducible. Nodes are never freed: a fragment
// deleted is a tombstone, which an undo shows again.
//
// Hosted (tests, host tools) it uses the C library's allocator, otherwise the
// process heap.

#pragma once

#include "text.h"

#if __STDC_HOSTED__
#include <stdlib.h>
#endif

// --- Memory ---

static void *vt_alloc(size_t n) {
#if __STDC_HOSTED__
  return malloc(n ? n : 1);
#else
  return vx_heap_alloc(vx_heap_process(), n ? n : 1);
#endif
}

static void vt_free(void *p) {
#if __STDC_HOSTED__
  free(p);
#else
  if (p) vx_heap_free(vx_heap_process(), p);
#endif
}

// Grows *p, an array of *cap elements of size bytes, to hold at least need.
static bool vt_grow(void **p, size_t *cap, size_t need, size_t size) {
  if (need <= *cap) return true;
  size_t n = *cap ? *cap : 16;
  while (n < need) {
    if (n > SIZE_MAX / 2 / size) return false;
    n *= 2;
  }
  void *q = vt_alloc(n * size);
  if (!q) return false;
  if (*p) __builtin_memcpy(q, *p, *cap * size);
  vt_free(*p);
  *p = q, *cap = n;
  return true;
}

// --- The structures ---

typedef struct vt_node {
  uint32_t l, r, up; // the text's treap
  uint32_t il, ir;   // the index's treap
  uint32_t prio;
  uint32_t ins;  // the insertion it is a range of
  uint32_t dels; // applied groups that delete it
  uint64_t start;
  uint32_t len, nl, runes; // its own bytes, newlines and runes
  bool vis;
  uint64_t sbytes, snl, sruns; // its subtree's visible ones
} vt_node;

typedef struct vt_insertion {
  const char *p;
  uint64_t len;
  uint32_t group;
} vt_insertion;

enum : uint32_t { VT_OP_INSERT, VT_OP_DELETE };

typedef struct vt_op {
  uint32_t kind, ins;
  uint64_t s, e; // a deletion's range of the insertion
} vt_op;

typedef struct vt_group {
  uint32_t parent, last_child, reverts;
  uint32_t op0, nops;
  bool applied;
  const char *src;
  size_t srclen;
} vt_group;

// A block of the add buffer; blocks never move.
typedef struct vt_block {
  struct vt_block *next;
  size_t used, cap;
  char bytes[];
} vt_block;

struct vx_text {
  vt_node *nodes;
  size_t nnodes, capnodes;
  vt_insertion *ins;
  size_t nins, capins;
  vt_group *groups;
  size_t ngroups, capgroups;
  vt_op *ops;
  size_t nops, capops;
  vt_block *blocks;
  uint32_t root, iroot;
  uint32_t head, open, depth;
  uint64_t rng, version;
  bool failed;
  char *lastpat; // sam's last regular expression
  size_t lastpatlen;
};

#define VT(t, x) (&(t)->nodes[(x)])

static uint32_t vt_random(vx_text *t) {
  uint64_t x = t->rng;
  x ^= x << 13, x ^= x >> 7, x ^= x << 17;
  t->rng = x;
  return (uint32_t)(x >> 32);
}

static uint64_t vt_own(const vt_node *n) { return n->vis ? n->len : 0; }

static const char *vt_bytes(const vx_text *t, const vt_node *n) { return t->ins[n->ins].p + n->start; }

static void vt_count(const char *p, uint64_t n, uint32_t *nl, uint32_t *runes) {
  uint32_t a = 0, b = 0;
  for (uint64_t i = 0; i < n; i++) {
    a += p[i] == '\n';
    b += ((unsigned char)p[i] & 0xc0) != 0x80;
  }
  *nl = a, *runes = b;
}

static void vt_pull(vx_text *t, uint32_t x) {
  vt_node *n = VT(t, x), *l = VT(t, n->l), *r = VT(t, n->r);
  n->sbytes = l->sbytes + r->sbytes + vt_own(n);
  n->snl = l->snl + r->snl + (n->vis ? n->nl : 0);
  n->sruns = l->sruns + r->sruns + (n->vis ? n->runes : 0);
  if (n->l) l->up = x;
  if (n->r) r->up = x;
}

static void vt_pull_up(vx_text *t, uint32_t x) {
  for (; x; x = VT(t, x)->up) vt_pull(t, x);
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the treap, O(log n) expected
static uint32_t vt_merge(vx_text *t, uint32_t a, uint32_t b) {
  if (!a) return b;
  if (!b) return a;
  if (VT(t, a)->prio > VT(t, b)->prio) {
    VT(t, a)->r = vt_merge(t, VT(t, a)->r, b);
    vt_pull(t, a);
    return a;
  }
  VT(t, b)->l = vt_merge(t, a, VT(t, b)->l);
  vt_pull(t, b);
  return b;
}

// Splits x at visible offset p, which must fall between fragments, as far
// left as it can: tombstones at p go right.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the treap, O(log n) expected
static void vt_split(vx_text *t, uint32_t x, uint64_t p, uint32_t *a, uint32_t *b) {
  if (!x) {
    *a = *b = 0;
    return;
  }
  vt_node *n = VT(t, x);
  uint64_t ls = VT(t, n->l)->sbytes;
  if (p <= ls) {
    uint32_t l = 0;
    vt_split(t, n->l, p, a, &l);
    VT(t, x)->l = l;
    vt_pull(t, x);
    *b = x;
  } else {
    uint32_t r = 0;
    vt_split(t, n->r, p - ls - vt_own(n), &r, b);
    VT(t, x)->r = r;
    vt_pull(t, x);
    *a = x;
  }
}

static void vt_set_root(vx_text *t, uint32_t x) {
  t->root = x;
  if (x) VT(t, x)->up = 0;
}

// --- The index: nodes by insertion and offset ---

static bool vt_key_less(const vt_node *a, const vt_node *b) {
  return a->ins < b->ins || (a->ins == b->ins && a->start < b->start);
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the treap, O(log n) expected
static uint32_t vt_index_add(vx_text *t, uint32_t x, uint32_t y) {
  if (!x) return y;
  vt_node *n = VT(t, x);
  if (vt_key_less(VT(t, y), n)) {
    uint32_t c = vt_index_add(t, n->il, y);
    n = VT(t, x), n->il = c;
    if (VT(t, c)->prio > n->prio) { // rotate right
      n->il = VT(t, c)->ir, VT(t, c)->ir = x;
      return c;
    }
  } else {
    uint32_t c = vt_index_add(t, n->ir, y);
    n = VT(t, x), n->ir = c;
    if (VT(t, c)->prio > n->prio) { // rotate left
      n->ir = VT(t, c)->il, VT(t, c)->il = x;
      return c;
    }
  }
  return x;
}

// The fragment of insertion ins holding offset off, or 0.
static uint32_t vt_index_find(const vx_text *t, uint32_t ins, uint64_t off) {
  uint32_t best = 0;
  for (uint32_t x = t->iroot; x;) {
    const vt_node *n = &t->nodes[x];
    if (n->ins < ins || (n->ins == ins && n->start <= off))
      best = x, x = n->ir;
    else
      x = n->il;
  }
  if (!best) return 0;
  const vt_node *n = &t->nodes[best];
  return n->ins == ins && off < n->start + n->len ? best : 0;
}

// --- Nodes ---

static uint32_t vt_node_new(vx_text *t, uint32_t ins, uint64_t start, uint32_t len) {
  if (!vt_grow((void **)&t->nodes, &t->capnodes, t->nnodes + 1, sizeof *t->nodes)) {
    t->failed = true;
    return 0;
  }
  uint32_t x = (uint32_t)t->nnodes++;
  vt_node *n = VT(t, x);
  *n = (vt_node){.prio = vt_random(t), .ins = ins, .start = start, .len = len, .vis = true};
  vt_count(vt_bytes(t, n), len, &n->nl, &n->runes);
  vt_pull(t, x);
  t->iroot = vt_index_add(t, t->iroot, x);
  return x;
}

// A treap of insertion ins's bytes from start, in fragments of at most
// VX_TEXT_CHUNK, or 0 out of memory.
static uint32_t vt_fragments(vx_text *t, uint32_t ins, uint64_t start, uint64_t len) {
  uint32_t tree = 0;
  for (uint64_t at = 0; at < len; at += VX_TEXT_CHUNK) {
    uint64_t n = len - at < VX_TEXT_CHUNK ? len - at : VX_TEXT_CHUNK;
    uint32_t x = vt_node_new(t, ins, start + at, (uint32_t)n);
    if (!x) return 0;
    tree = vt_merge(t, tree, x);
  }
  return tree;
}

// The visible node holding byte off, and the offset into it, or 0.
static uint32_t vt_find(const vx_text *t, uint64_t off, uint64_t *in) {
  uint32_t x = t->root;
  while (x) {
    const vt_node *n = &t->nodes[x];
    uint64_t ls = t->nodes[n->l].sbytes, own = vt_own(n);
    if (off < ls) {
      x = n->l;
    } else if (off < ls + own) {
      *in = off - ls;
      return x;
    } else {
      off -= ls + own, x = n->r;
    }
  }
  return 0;
}

// Where node x's bytes start in the visible text (where it would, deleted).
static uint64_t vt_pos(const vx_text *t, uint32_t x) {
  uint64_t pos = t->nodes[t->nodes[x].l].sbytes;
  for (uint32_t c = x, u = t->nodes[x].up; u; c = u, u = t->nodes[u].up)
    if (t->nodes[u].r == c) pos += t->nodes[t->nodes[u].l].sbytes + vt_own(&t->nodes[u]);
  return pos;
}

// The next node in order after x with visible bytes, or 0; and the one before.
static uint32_t vt_next(const vx_text *t, uint32_t x) {
  const vt_node *N = t->nodes;
  for (;;) {
    if (N[x].r && N[N[x].r].sbytes) {
      x = N[x].r;
      for (;;) {
        if (N[x].l && N[N[x].l].sbytes)
          x = N[x].l;
        else if (vt_own(&N[x]))
          return x;
        else
          x = N[x].r;
      }
    }
    uint32_t u = N[x].up;
    while (u && N[u].r == x) x = u, u = N[u].up;
    if (!u) return 0;
    x = u;
    if (vt_own(&N[x])) return x;
  }
}

static uint32_t vt_prev(const vx_text *t, uint32_t x) {
  const vt_node *N = t->nodes;
  for (;;) {
    if (N[x].l && N[N[x].l].sbytes) {
      x = N[x].l;
      for (;;) {
        if (N[x].r && N[N[x].r].sbytes)
          x = N[x].r;
        else if (vt_own(&N[x]))
          return x;
        else
          x = N[x].l;
      }
    }
    uint32_t u = N[x].up;
    while (u && N[u].l == x) x = u, u = N[u].up;
    if (!u) return 0;
    x = u;
    if (vt_own(&N[x])) return x;
  }
}

// Makes off fall between fragments, splitting the one it is inside.
static bool vt_boundary(vx_text *t, uint64_t off) {
  uint64_t in = 0;
  uint32_t x = vt_find(t, off, &in);
  if (!x || in == 0) return true;
  vt_node old = *VT(t, x);
  uint32_t y = vt_node_new(t, old.ins, old.start + in, old.len - (uint32_t)in);
  if (!y) return false;
  vt_node *n = VT(t, x), *m = VT(t, y);
  m->dels = n->dels, m->vis = n->vis;
  n->len = (uint32_t)in, n->nl -= m->nl, n->runes -= m->runes;
  vt_pull(t, y);
  vt_pull_up(t, x);
  uint32_t a = 0, b = 0;
  vt_split(t, t->root, off, &a, &b);
  vt_set_root(t, vt_merge(t, vt_merge(t, a, y), b));
  return true;
}

// --- The buffer ---

vx_text *vx_text_new(const char *original, uint64_t len) {
  vx_text *t = vt_alloc(sizeof *t);
  if (!t) return nullptr;
  *t = (vx_text){.rng = 0x9e37'79b9'7f4a'7c15};
  bool ok = vt_grow((void **)&t->nodes, &t->capnodes, 1, sizeof *t->nodes) &&
            vt_grow((void **)&t->ins, &t->capins, 1, sizeof *t->ins) &&
            vt_grow((void **)&t->groups, &t->capgroups, 1, sizeof *t->groups);
  if (!ok) {
    vx_text_free(t);
    return nullptr;
  }
  t->nodes[0] = (vt_node){};
  t->nnodes = 1;
  t->ins[0] = (vt_insertion){.p = original, .len = len};
  t->nins = 1;
  t->groups[0] = (vt_group){.applied = true};
  t->ngroups = 1;
  vt_set_root(t, vt_fragments(t, 0, 0, len));
  if (t->failed) {
    vx_text_free(t);
    return nullptr;
  }
  return t;
}

void vx_text_free(vx_text *t) {
  if (!t) return;
  for (vt_block *b = t->blocks, *next; b; b = next) next = b->next, vt_free(b);
  vt_free(t->nodes), vt_free(t->ins), vt_free(t->groups), vt_free(t->ops), vt_free(t->lastpat);
  vt_free(t);
}

bool vx_text_failed(const vx_text *t) { return t->failed; }
uint64_t vx_text_len(const vx_text *t) { return t->nodes[t->root].sbytes; }
uint64_t vx_text_lines(const vx_text *t) { return t->nodes[t->root].snl; }
uint64_t vx_text_runes(const vx_text *t) { return t->nodes[t->root].sruns; }
uint64_t vx_text_version(const vx_text *t) { return t->version; }

uint64_t vx_text_read(const vx_text *t, uint64_t off, char *buf, uint64_t n) {
  uint64_t in = 0, got = 0;
  for (uint32_t x = vt_find(t, off, &in); x && got < n; x = vt_next(t, x), in = 0) {
    const vt_node *nd = &t->nodes[x];
    uint64_t k = nd->len - in < n - got ? nd->len - in : n - got;
    __builtin_memcpy(buf + got, vt_bytes(t, nd) + in, k);
    got += k;
  }
  return got;
}

// The offset just after the k-th (from 1) newline, or the length.
uint64_t vx_text_line_start(const vx_text *t, uint64_t line) {
  if (line == 0) return 0;
  if (line > vx_text_lines(t)) return vx_text_len(t);
  uint64_t base = 0, k = line;
  for (uint32_t x = t->root; x;) {
    const vt_node *n = &t->nodes[x];
    const vt_node *l = &t->nodes[n->l];
    uint32_t own = n->vis ? n->nl : 0;
    if (k <= l->snl) {
      x = n->l;
      continue;
    }
    k -= l->snl, base += l->sbytes;
    if (k <= own) {
      const char *p = vt_bytes(t, n);
      for (uint32_t i = 0; i < n->len; i++)
        if (p[i] == '\n' && --k == 0) return base + i + 1;
    }
    k -= own, base += vt_own(n), x = n->r;
  }
  return vx_text_len(t);
}

uint64_t vx_text_line_of(const vx_text *t, uint64_t off) {
  if (off >= vx_text_len(t)) return vx_text_lines(t);
  uint64_t lines = 0;
  for (uint32_t x = t->root; x;) {
    const vt_node *n = &t->nodes[x];
    const vt_node *l = &t->nodes[n->l];
    if (off < l->sbytes) {
      x = n->l;
      continue;
    }
    off -= l->sbytes, lines += l->snl;
    if (off < vt_own(n)) {
      const char *p = vt_bytes(t, n);
      for (uint64_t i = 0; i < off; i++) lines += p[i] == '\n';
      return lines;
    }
    off -= vt_own(n), lines += n->vis ? n->nl : 0, x = n->r;
  }
  return lines;
}

uint64_t vx_text_rune_start(const vx_text *t, uint64_t rune) {
  if (rune >= vx_text_runes(t)) return vx_text_len(t);
  uint64_t base = 0, k = rune + 1; // the k-th rune's first byte
  for (uint32_t x = t->root; x;) {
    const vt_node *n = &t->nodes[x];
    const vt_node *l = &t->nodes[n->l];
    uint32_t own = n->vis ? n->runes : 0;
    if (k <= l->sruns) {
      x = n->l;
      continue;
    }
    k -= l->sruns, base += l->sbytes;
    if (k <= own) {
      const char *p = vt_bytes(t, n);
      for (uint32_t i = 0; i < n->len; i++)
        if (((unsigned char)p[i] & 0xc0) != 0x80 && --k == 0) return base + i;
    }
    k -= own, base += vt_own(n), x = n->r;
  }
  return vx_text_len(t);
}

uint64_t vx_text_rune_of(const vx_text *t, uint64_t off) {
  if (off >= vx_text_len(t)) return vx_text_runes(t);
  uint64_t runes = 0;
  for (uint32_t x = t->root; x;) {
    const vt_node *n = &t->nodes[x];
    const vt_node *l = &t->nodes[n->l];
    if (off < l->sbytes) {
      x = n->l;
      continue;
    }
    off -= l->sbytes, runes += l->sruns;
    if (off < vt_own(n)) {
      const char *p = vt_bytes(t, n);
      for (uint64_t i = 0; i < off; i++) runes += ((unsigned char)p[i] & 0xc0) != 0x80;
      return runes;
    }
    off -= vt_own(n), runes += n->vis ? n->runes : 0, x = n->r;
  }
  return runes;
}

// --- Groups ---

static bool vt_op_add(vx_text *t, vt_op op) {
  vt_group *g = &t->groups[t->open];
  if (op.kind == VT_OP_DELETE && g->nops) { // the deletion before it, continued
    vt_op *last = &t->ops[t->nops - 1];
    if (last->kind == VT_OP_DELETE && last->ins == op.ins && last->e == op.s) {
      last->e = op.e;
      return true;
    }
  }
  if (!vt_grow((void **)&t->ops, &t->capops, t->nops + 1, sizeof *t->ops)) return t->failed = true, false;
  t->ops[t->nops++] = op;
  g->nops++;
  return true;
}

// Copies n bytes into the add buffer; nullptr out of memory.
static char *vt_keep(vx_text *t, const char *bytes, uint64_t n) {
  vt_block *b = t->blocks;
  if (!b || b->cap - b->used < n) {
    size_t cap = n > 65536 ? n : 65536;
    b = vt_alloc(sizeof *b + cap);
    if (!b) return t->failed = true, nullptr;
    *b = (vt_block){.next = t->blocks, .cap = cap};
    t->blocks = b;
  }
  char *p = b->bytes + b->used;
  if (n) __builtin_memcpy(p, bytes, n);
  b->used += n;
  return p;
}

bool vx_text_begin(vx_text *t, vx_str source) {
  if (t->failed) return false;
  if (t->depth++) return true;
  if (!vt_grow((void **)&t->groups, &t->capgroups, t->ngroups + 1, sizeof *t->groups)) {
    t->depth--;
    return t->failed = true, false;
  }
  const char *src = vt_keep(t, source.ptr, source.len);
  if (!src) return t->depth--, false;
  uint32_t g = (uint32_t)t->ngroups++;
  t->groups[g] = (vt_group){
      .parent = t->head, .op0 = (uint32_t)t->nops, .applied = true, .src = src, .srclen = source.len};
  t->open = g;
  return true;
}

void vx_text_end(vx_text *t) {
  if (!t->depth) return;
  t->depth--;
  if (t->depth) return;
  uint32_t g = t->open;
  t->open = 0;
  if (!t->groups[g].nops) { // nothing changed: no group
    t->ngroups--;
    return;
  }
  t->groups[t->head].last_child = g;
  t->head = g;
}

static bool vt_edit_begin(vx_text *t) { return vx_text_begin(t, VX_STR("")); }

// Insertion k's byte count grows by n where its last fragment ends at off,
// as typing does, when that is where k's bytes are kept.
static bool vt_extend(vx_text *t, uint64_t off, const char *bytes, uint64_t n) {
  if (!t->nops || t->groups[t->open].nops == 0) return false;
  const vt_op *last = &t->ops[t->nops - 1];
  uint32_t k = (uint32_t)t->nins - 1;
  if (last->kind != VT_OP_INSERT || last->ins != k) return false;
  vt_insertion *in = &t->ins[k];
  vt_block *b = t->blocks;
  if (!b || in->p + in->len != b->bytes + b->used || b->cap - b->used < n) return false;
  uint32_t x = vt_index_find(t, k, in->len - 1);
  if (!x || !VT(t, x)->vis || VT(t, x)->len + n > VX_TEXT_CHUNK) return false;
  if (vt_pos(t, x) + VT(t, x)->len != off) return false;
  vt_keep(t, bytes, n);
  in->len += n;
  uint32_t nl = 0, runes = 0;
  vt_count(bytes, n, &nl, &runes);
  vt_node *nd = VT(t, x);
  nd->len += (uint32_t)n, nd->nl += nl, nd->runes += runes;
  vt_pull_up(t, x);
  return true;
}

static bool vt_insert(vx_text *t, uint64_t off, const char *bytes, uint64_t n) {
  if (vt_extend(t, off, bytes, n)) return true;
  if (!vt_grow((void **)&t->ins, &t->capins, t->nins + 1, sizeof *t->ins)) return t->failed = true, false;
  const char *p = vt_keep(t, bytes, n);
  if (!p || !vt_boundary(t, off)) return false;
  uint32_t k = (uint32_t)t->nins++;
  t->ins[k] = (vt_insertion){.p = p, .len = n, .group = t->open};
  uint32_t m = vt_fragments(t, k, 0, n);
  if (t->failed) return false;
  uint32_t a = 0, b = 0;
  vt_split(t, t->root, off, &a, &b);
  vt_set_root(t, vt_merge(t, vt_merge(t, a, m), b));
  return vt_op_add(t, (vt_op){.kind = VT_OP_INSERT, .ins = k});
}

// Deletes every visible fragment of subtree x, recording each, and resums it.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the treap, O(log n) expected
static bool vt_delete_all(vx_text *t, uint32_t x) {
  if (!x) return true;
  bool ok = vt_delete_all(t, VT(t, x)->l);
  vt_node *n = VT(t, x);
  if (n->vis) {
    n->dels++, n->vis = false;
    ok = vt_op_add(t, (vt_op){.kind = VT_OP_DELETE, .ins = n->ins, .s = n->start, .e = n->start + n->len}) &&
         ok;
  }
  ok = vt_delete_all(t, VT(t, x)->r) && ok;
  vt_pull(t, x);
  return ok;
}

static bool vt_delete(vx_text *t, uint64_t p0, uint64_t p1) {
  if (!vt_boundary(t, p0) || !vt_boundary(t, p1)) return false;
  uint32_t a = 0, m = 0, b = 0;
  vt_split(t, t->root, p0, &a, &b);
  vt_split(t, b, p1 - p0, &m, &b);
  bool ok = vt_delete_all(t, m);
  vt_set_root(t, vt_merge(t, vt_merge(t, a, m), b));
  return ok;
}

bool vx_text_replace(vx_text *t, uint64_t p0, uint64_t p1, const char *bytes, uint64_t n) {
  uint64_t len = vx_text_len(t);
  if (p1 > len) p1 = len;
  if (p0 > p1) p0 = p1;
  if (p0 == p1 && n == 0) return !t->failed;
  if (!vt_edit_begin(t)) return false;
  bool ok = (p0 == p1 || vt_delete(t, p0, p1)) && (n == 0 || vt_insert(t, p0, bytes, n));
  t->version++;
  vx_text_end(t);
  return ok;
}

bool vx_text_insert(vx_text *t, uint64_t off, const char *bytes, uint64_t n) {
  return vx_text_replace(t, off, off, bytes, n);
}

bool vx_text_delete(vx_text *t, uint64_t p0, uint64_t p1) { return vx_text_replace(t, p0, p1, nullptr, 0); }

// --- Anchors ---

vx_text_anchor vx_text_anchor_at(vx_text *t, uint64_t off, uint32_t bias) {
  uint64_t len = vx_text_len(t), in = 0;
  if (off > len) off = len;
  if (bias == VX_TEXT_LEFT) {
    if (off == 0) return (vx_text_anchor){.insertion = VX_TEXT_START};
    uint32_t x = vt_find(t, off - 1, &in);
    return (vx_text_anchor){.insertion = VT(t, x)->ins, .bias = bias, .offset = VT(t, x)->start + in + 1};
  }
  if (off == len) return (vx_text_anchor){.insertion = VX_TEXT_END, .bias = VX_TEXT_RIGHT};
  uint32_t x = vt_find(t, off, &in);
  return (vx_text_anchor){.insertion = VT(t, x)->ins, .bias = VX_TEXT_RIGHT, .offset = VT(t, x)->start + in};
}

uint64_t vx_text_resolve(vx_text *t, vx_text_anchor a) {
  if (a.insertion == VX_TEXT_START) return 0;
  if (a.insertion == VX_TEXT_END || a.insertion >= t->nins) return vx_text_len(t);
  bool left = a.bias == VX_TEXT_LEFT;
  if (left && a.offset == 0) return 0; // never made, but cannot be resolved
  uint64_t at = left ? a.offset - 1 : a.offset;
  uint32_t x = vt_index_find(t, a.insertion, at);
  if (!x) return vx_text_len(t);
  const vt_node *n = VT(t, x);
  return vt_pos(t, x) + (n->vis ? at - n->start + left : 0);
}

// --- The undo tree ---

static void vt_show(vx_text *t, uint32_t x) {
  vt_node *n = VT(t, x);
  bool vis = t->groups[t->ins[n->ins].group].applied && n->dels == 0;
  if (vis == n->vis) return;
  n->vis = vis;
  vt_pull_up(t, x);
}

// Calls each fragment of insertion ins over [s, e) with step.
static void vt_each(vx_text *t, uint32_t ins, uint64_t s, uint64_t e, int step) {
  for (uint32_t x = vt_index_find(t, ins, s); x && VT(t, x)->start < e;) {
    vt_node *n = VT(t, x);
    if (step) n->dels += (uint32_t)step;
    uint64_t next = n->start + n->len;
    vt_show(t, x);
    x = vt_index_find(t, ins, next);
  }
}

// Shows or hides group g's changes.
// NOLINTNEXTLINE(misc-no-recursion): once: a revert names an edit group
static void vt_flip(vx_text *t, uint32_t g) {
  vt_group *grp = &t->groups[g];
  if (grp->reverts) {
    vt_flip(t, grp->reverts); // reverts name edit groups alone
    grp->applied = !grp->applied;
    return;
  }
  grp->applied = !grp->applied;
  int step = grp->applied ? 1 : -1;
  for (uint32_t i = grp->op0; i < grp->op0 + grp->nops; i++) {
    vt_op op = t->ops[i];
    if (op.kind == VT_OP_INSERT)
      vt_each(t, op.ins, 0, t->ins[op.ins].len, 0);
    else
      vt_each(t, op.ins, op.s, op.e, step);
  }
  t->version++;
}

bool vx_text_undo(vx_text *t) {
  if (t->depth || !t->head) return false;
  uint32_t g = t->head;
  vt_flip(t, g);
  t->head = t->groups[g].parent;
  t->groups[t->head].last_child = g;
  return true;
}

bool vx_text_redo(vx_text *t) {
  if (t->depth) return false;
  uint32_t g = t->groups[t->head].last_child;
  if (!g) return false;
  vt_flip(t, g);
  t->head = g;
  return true;
}

bool vx_text_revert(vx_text *t, uint32_t group, vx_str source) {
  if (t->depth || group == 0 || group >= t->ngroups) return false;
  vt_group *g = &t->groups[group];
  if (g->reverts || !g->applied) return false;
  bool on_path = false;
  for (uint32_t h = t->head; h && !on_path; h = t->groups[h].parent) on_path = h == group;
  if (!on_path || !vx_text_begin(t, source)) return false;
  uint32_t r = t->open;
  t->groups[r].reverts = group;
  t->groups[r].applied = false;
  vt_flip(t, r);
  t->groups[r].nops = 0;
  t->depth = 0, t->open = 0;
  t->groups[t->head].last_child = r;
  t->head = r;
  return true;
}

uint32_t vx_text_head(const vx_text *t) { return t->head; }
uint32_t vx_text_groups(const vx_text *t) { return (uint32_t)t->ngroups; }

bool vx_text_group(const vx_text *t, uint32_t id, vx_text_group_info *out) {
  if (id >= t->ngroups || (t->depth && id == t->open)) return false;
  const vt_group *g = &t->groups[id];
  *out = (vx_text_group_info){.id = id,
                              .parent = g->parent,
                              .reverts = g->reverts,
                              .applied = g->applied,
                              .source = {g->src, g->srclen}};
  return true;
}

// --- Dot ---

bool vx_text_dot_set(vx_text_dot *d, uint64_t p0, uint64_t p1) {
  if (!vt_grow((void **)&d->r, &d->cap, 1, sizeof *d->r)) return false;
  d->r[0] = (vx_text_range){p0 < p1 ? p0 : p1, p0 < p1 ? p1 : p0};
  d->n = 1;
  return true;
}

void vx_text_dot_free(vx_text_dot *d) {
  vt_free(d->r);
  *d = (vx_text_dot){};
}

#include "regex.c"
#include "sam.c"
