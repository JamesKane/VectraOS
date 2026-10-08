// vx-rt arenas, scratch, pools and the error text (09 §4.2, §4.3, §5.2;
// ADR-0004 libvx v0, M6 step 6e4c1). Included by rt.c, after heap.c.
//
// An arena is one lazy VMO (ADR-0046) mapped whole: its address space is
// reserved at once and a page costs nothing until it is touched, so pushing
// is pure. Its header is its first bytes. Memory is zeroed when pushed: a
// lazy page reads as zeros, and what was pushed and popped before is
// cleared again. A failed push returns nullptr and leaves the error in the
// arena (vx_arena_error) and in vx_errstr; a failed vx_arena_new returns
// the nil arena, on which every call does nothing.
//
// Each thread has two scratch arenas, made when first asked for and let go
// when the thread ends; vx_scratch gives one that is not among the
// caller's, so a callee's scratch never overlaps its caller's (Ryan
// Fleury's arenas, the RAD Debugger).
//
// A pool is fixed-size slots in an arena, named by an index and a
// generation (09 §4.4), so a stale id finds nothing.

#pragma once

#include <stdckdint.h>

#include "base.c"

// --- The error text (09 §4.2) ---

static thread_local struct {
  size_t len;
  char text[VX_ERRMAX];
} vx_err;

// The calling thread's last error message.
VX_API vx_str vx_errstr(void) { return (vx_str){vx_err.text, vx_err.len}; }

// Sets it: msg cut to VX_ERRMAX bytes, at a rune's boundary.
[[maybe_unused]] static void vx_err_set(vx_str msg) {
  size_t n = vx_utf_cut(msg.ptr, msg.len, VX_ERRMAX);
  memcpy(vx_err.text, msg.ptr, n);
  vx_err.len = n;
}

// --- Arenas ---

struct vx_arena {
  uint8_t *base;              // what is pushed: past this header
  size_t reserve, used, high; // high: the most ever pushed; below it, memory may be dirty
  size_t map_size;            // the mapping, header included
  vx_status error;            // sticky
  bool nil;
};

static vx_arena vx_arena_nil = {.nil = true, .error = VX_ERR_NIL};

static size_t vx_up(size_t v, size_t a) { return (v + a - 1) & ~(a - 1); }

VX_API vx_arena *vx_arena_new(size_t reserve) {
  size_t header = vx_up(sizeof(vx_arena), 64);
  size_t size = vx_up(reserve + header, 4096);
  vx_handle v = VX_HANDLE_NONE;
  uint64_t at = 0;
  vx_status st = reserve && size > reserve ? vx_vmo_create(size, VX_VMO_LAZY, &v) : VX_ERR_RANGE;
  if (st == VX_OK) st = vx_as_map(vx_self, v, 0, size, VX_MAP_WRITE, &at);
  if (v) vx_handle_close(v);
  if (st != VX_OK) {
    vx_err_set(VX_STR("arena: cannot reserve its memory"));
    return &vx_arena_nil;
  }
  vx_arena *a = (vx_arena *)at;
  *a = (vx_arena){.base = (uint8_t *)at + header, .reserve = size - header, .map_size = size};
  return a;
}

VX_API void vx_arena_free(vx_arena *a) {
  if (a->nil) return;
  vx_as_unmap(vx_self, (uint64_t)a, a->map_size);
}

// size bytes, zeroed, at align (a power of two, at most a page); nullptr if
// the arena is full or nil.
VX_API void *vx_push(vx_arena *a, size_t size, size_t align) {
  if (a->nil) return nullptr;
  if (!align || (align & (align - 1)) || align > 4096) align = 16;
  size_t off = vx_up(a->used, align);
  if (off > a->reserve || size > a->reserve - off) {
    a->error = VX_ERR_NO_MEMORY;
    vx_err_set(VX_STR("arena: full"));
    return nullptr;
  }
  uint8_t *p = a->base + off;
  if (off < a->high) memset(p, 0, size < a->high - off ? size : a->high - off);
  a->used = off + size;
  if (a->used > a->high) a->high = a->used;
  return p;
}

VX_API vx_mark vx_arena_mark(const vx_arena *a) { return (vx_mark){a->nil ? 0 : a->used}; }

VX_API void vx_arena_pop(vx_arena *a, vx_mark m) {
  if (!a->nil && m.used <= a->used) a->used = m.used;
}

VX_API vx_status vx_arena_error(const vx_arena *a) { return a->error; }

// --- Scratch ---

static constexpr size_t VX_SCRATCH_RESERVE = 64ull << 20;
static thread_local vx_arena *vx_scratch_arenas[2];

VX_API vx_arena *vx_scratch(vx_arena *const *conflicts, size_t n) {
  for (size_t i = 0; i < 2; i++) {
    vx_arena **s = &vx_scratch_arenas[i];
    bool taken = false;
    for (size_t k = 0; k < n && !taken; k++) taken = *s && conflicts[k] == *s;
    if (taken) continue;
    if (!*s) *s = vx_arena_new(VX_SCRATCH_RESERVE);
    return *s;
  }
  return &vx_arena_nil; // both conflict: two are enough for a caller and its callees
}

// The ending thread's scratch arenas let go (thread.c).
static void vx_scratch_release(void) {
  for (size_t i = 0; i < 2; i++)
    if (vx_scratch_arenas[i]) vx_arena_free(vx_scratch_arenas[i]), vx_scratch_arenas[i] = nullptr;
}

// --- Pools ---

struct vx_pool {
  uint8_t *slots;
  uint32_t *gen, *next; // a slot's generation (odd: taken); the free list's links
  size_t slot, max, count;
  uint32_t free_head; // a slot index plus 1; 0: none
  vx_status error;
  bool nil;
};

static vx_pool vx_pool_nil = {.nil = true, .error = VX_ERR_NIL};

VX_API vx_pool *vx_pool_new(vx_arena *a, size_t slot_size, size_t max) {
  if (!slot_size || !max || max >= UINT32_MAX) return &vx_pool_nil;
  size_t slot = vx_up(slot_size, 16);
  vx_pool *p = vx_push(a, sizeof *p, alignof(vx_pool));
  uint32_t *gen = vx_push(a, max * sizeof *gen, alignof(uint32_t));
  uint32_t *next = vx_push(a, max * sizeof *next, alignof(uint32_t));
  uint8_t *slots = max <= SIZE_MAX / slot ? vx_push(a, max * slot, 16) : nullptr;
  if (!p || !gen || !next || !slots) return &vx_pool_nil;
  *p = (vx_pool){.slots = slots, .gen = gen, .next = next, .slot = slot, .max = max};
  return p;
}

// A free slot, zeroed; its id, or 0 if the pool is full.
VX_API vx_id vx_pool_take(vx_pool *p) {
  if (p->nil) return 0;
  uint32_t i;
  if (p->free_head) {
    i = p->free_head - 1;
    p->free_head = p->next[i];
  } else if (p->count < p->max) {
    i = (uint32_t)p->count++;
  } else {
    p->error = VX_ERR_NO_MEMORY;
    vx_err_set(VX_STR("pool: full"));
    return 0;
  }
  p->gen[i]++; // odd now: taken
  memset(p->slots + (size_t)i * p->slot, 0, p->slot);
  return (vx_id)p->gen[i] << 32 | i;
}

static bool vx_pool_live(const vx_pool *p, vx_id id, uint32_t *i) {
  *i = (uint32_t)id;
  uint32_t g = (uint32_t)(id >> 32);
  return !p->nil && *i < p->count && (g & 1) && p->gen[*i] == g;
}

// The slot id names, or nullptr if it is stale or none.
VX_API void *vx_pool_get(const vx_pool *p, vx_id id) {
  uint32_t i;
  return vx_pool_live(p, id, &i) ? p->slots + (size_t)i * p->slot : nullptr;
}

VX_API void vx_pool_put(vx_pool *p, vx_id id) {
  uint32_t i;
  if (!vx_pool_live(p, id, &i)) return;
  p->gen[i]++; // even: free, and id stale (it wraps through 0, never odd while free)
  p->next[i] = p->free_head;
  p->free_head = i + 1;
}

VX_API vx_status vx_pool_error(const vx_pool *p) { return p->error; }

// --- Text into arenas, and printed (09 §5.3; the engine is vx-text's) ---

VX_API vx_str vx_vfmt(vx_arena *a, const char *fmt, va_list ap) {
  va_list again;
  va_copy(again, ap);
  size_t n = vx_vfmt_len(fmt, ap);
  char *p = vx_push(a, n + 1, 1);
  if (p) vx_vbfmt((vx_bytes){(uint8_t *)p, n}, fmt, again);
  va_end(again);
  return p ? (vx_str){p, n} : (vx_str){};
}

VX_API vx_str vx_fmt(vx_arena *a, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vx_str s = vx_vfmt(a, fmt, ap);
  va_end(ap);
  return s;
}

VX_API vx_str vx_str_cat(vx_arena *a, const vx_str *parts, size_t n) {
  size_t len = 0;
  for (size_t i = 0; i < n; i++)
    if (ckd_add(&len, len, parts[i].len)) return (vx_str){};
  char *p = vx_push(a, len + 1, 1);
  if (!p) return (vx_str){};
  for (size_t i = 0, at = 0; i < n; at += parts[i++].len)
    if (parts[i].len) memcpy(p + at, parts[i].ptr, parts[i].len);
  return (vx_str){p, len};
}

// Formats into a buffer on the stack, or scratch when it is longer, and
// gives it to out in one call.
static int64_t vx_vprint_to(void (*out)(vx_str), const char *fmt, va_list ap) {
  char buf[512];
  va_list again;
  va_copy(again, ap);
  size_t n = vx_vbfmt((vx_bytes){(uint8_t *)buf, sizeof buf}, fmt, ap);
  int64_t ret = (int64_t)n;
  if (n < sizeof buf - VX_UTFMAX) { // whole: a cut leaves fewer than VX_UTFMAX bytes unused
    out((vx_str){buf, n});
  } else {
    vx_arena *s = vx_scratch(nullptr, 0);
    vx_mark m = vx_arena_mark(s);
    vx_str all = vx_vfmt(s, fmt, again);
    if (all.ptr)
      out(all), ret = (int64_t)all.len;
    else
      out((vx_str){buf, n}), ret = VX_ERR_NO_MEMORY;
    vx_arena_pop(s, m);
  }
  va_end(again);
  return ret;
}

VX_API int64_t vx_printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int64_t n = vx_vprint_to(vx_print, fmt, ap);
  va_end(ap);
  return n;
}

VX_API int64_t vx_eprintf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int64_t n = vx_vprint_to(vx_eprint, fmt, ap);
  va_end(ap);
  return n;
}
