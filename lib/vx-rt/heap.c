// heap.c: vx_heap, the allocator for objects with unrelated lifetimes (09
// §4.3 and §10 question 5; M6 step 6e1e2b; os-requirements R6), and the one
// process heap the native C library's malloc family sits on (ADR-0033 §1).
// First-party code keeps arenas and pools; a heap is made explicitly and
// passed explicitly, and vx_heap_process is the one a C library keeps.
//
// A heap is one reservation of address space (16 GiB at most), filled from
// the bottom with lazy VMOs of 256 MiB (ADR-0046) as it grows, each one
// mapping. It is cut into spans of 64 KiB, described by a table kept apart
// from the memory (in the heap's first spans), so a freed block's pages are
// never touched to keep track of them:
//
//   - a block of up to 32 KiB comes from a slab, one span of blocks of one
//     size class, each class with its own lock. A block is aligned to the
//     largest power of two its class's size is a multiple of, so an aligned
//     request takes the first class that is a multiple of the alignment;
//   - a larger block is a run of spans, aligned to a span;
//   - free runs of spans are coalesced with their neighbours (the table's
//     head and tail entries of each run) and kept in lists by size. Once
//     more than 4 MiB of them may still hold pages, every free run is
//     decommitted (VX_VMO_DECOMMIT), and its pages go back to the system.
//
// A block's usable size is its class's size, or its run's: what a caller may
// grow into (Swift's collections do).

#pragma once

#include "base.c"

static constexpr uint64_t VX_HEAP_SPAN = 64ull * 1024;
static constexpr uint64_t VX_HEAP_SEGMENT = 256ull << 20; // a lazy VMO's most (ADR-0046)
static constexpr uint32_t VX_HEAP_SEGMENTS = 64;          // so 16 GiB at most
static constexpr uint32_t VX_HEAP_SEGMENT_SPANS = (uint32_t)(VX_HEAP_SEGMENT / VX_HEAP_SPAN);
static constexpr uint64_t VX_HEAP_DIRTY_MAX = 64; // free spans that may hold pages before a sweep: 4 MiB
static constexpr uint32_t VX_HEAP_BUCKETS = 32;   // free runs by the floor of log2 of their length

// The size classes: multiples of 16, four to each doubling, up to 32 KiB.
static const uint32_t VX_HEAP_CLASS[] = {16,   32,   48,    64,    80,    96,    112,   128,  160,  192,
                                         224,  256,  320,   384,   448,   512,   640,   768,  896,  1024,
                                         1280, 1536, 1792,  2048,  2560,  3072,  3584,  4096, 5120, 6144,
                                         7168, 8192, 10240, 12288, 16384, 20480, 24576, 32768};
static constexpr uint32_t VX_HEAP_CLASSES = sizeof VX_HEAP_CLASS / sizeof VX_HEAP_CLASS[0];

enum : uint8_t { HEAP_NONE, HEAP_FREE, HEAP_SLAB, HEAP_LARGE, HEAP_INNER, HEAP_META };

// A span's entry. A free run's head and tail are HEAP_FREE, with `at` its
// head's index; its head has its length and whether it may hold pages. A
// large block's head is HEAP_LARGE with its length, the rest HEAP_INNER. A
// slab has its class, its blocks in use, how far it has handed out, and its
// free blocks, linked through them. next and prev (an index + 1, 0 for none)
// link a free run into its bucket, or a slab into its class's partial list.
typedef struct vx_heap_span {
  uint8_t kind, cls;
  bool dirty;
  uint32_t len, at, used, next, prev;
  void *free;
} vx_heap_span;

typedef struct vx_heap_class {
  vx_mutex lock;
  uint32_t partial; // slabs with a free block, or none in use: an index + 1
} vx_heap_class;

typedef struct vx_heap {
  uint8_t *base;
  uint64_t size;
  uint32_t spans; // in the reservation
  vx_heap_span *span;
  vx_mutex lock; // the spans': free runs, top, segments
  uint32_t top;  // spans past it have never been handed out
  uint32_t segments;
  vx_handle segment[VX_HEAP_SEGMENTS];
  uint32_t bucket[VX_HEAP_BUCKETS];
  uint64_t dirty; // spans of free runs that may hold pages
  vx_heap_class cls[VX_HEAP_CLASSES];
  bool nil; // the heap given when none could be made: it gives nothing
} vx_heap;

static vx_heap vx_heap_nil = {.nil = true};

// --- Lists of spans, through next and prev ---

static void heap_push(vx_heap *h, uint32_t *head, uint32_t s) {
  vx_heap_span *e = &h->span[s];
  e->prev = 0, e->next = *head;
  if (*head) h->span[*head - 1].prev = s + 1;
  *head = s + 1;
}

static void heap_unlink(vx_heap *h, uint32_t *head, uint32_t s) {
  vx_heap_span *e = &h->span[s];
  if (e->prev)
    h->span[e->prev - 1].next = e->next;
  else
    *head = e->next;
  if (e->next) h->span[e->next - 1].prev = e->prev;
  e->next = e->prev = 0;
}

static uint32_t heap_bucket(uint32_t len) { return (uint32_t)(31 - __builtin_clz(len)); }

// --- Spans, under h->lock ---

// The segments through span `end` mapped: a lazy VMO each, at its place.
static bool heap_map_through(vx_heap *h, uint32_t end) {
  while ((uint64_t)h->segments * VX_HEAP_SEGMENT_SPANS < end) {
    vx_handle v = VX_HANDLE_NONE;
    uint64_t at = (uint64_t)(h->base + h->segments * VX_HEAP_SEGMENT);
    if (vx_vmo_create(VX_HEAP_SEGMENT, VX_VMO_LAZY, &v) != VX_OK) return false;
    if (vx_as_map(vx_self, v, 0, VX_HEAP_SEGMENT, VX_MAP_WRITE, &at) != VX_OK) {
      vx_handle_close(v);
      return false;
    }
    h->segment[h->segments++] = v;
  }
  return true;
}

// A free run's pages back to the system, a segment's part at a time.
static void heap_decommit(vx_heap *h, uint32_t s, uint32_t len) {
  while (len) {
    uint32_t seg = s / VX_HEAP_SEGMENT_SPANS, in = s % VX_HEAP_SEGMENT_SPANS;
    uint32_t n = VX_HEAP_SEGMENT_SPANS - in < len ? VX_HEAP_SEGMENT_SPANS - in : len;
    vx_vmo_decommit(h->segment[seg], in * VX_HEAP_SPAN, n * VX_HEAP_SPAN);
    s += n, len -= n;
  }
}

// [s, s + len) a free run: its head and tail marked, into its bucket.
static void heap_mark_free(vx_heap *h, uint32_t s, uint32_t len, bool dirty) {
  vx_heap_span *head = &h->span[s], *tail = &h->span[s + len - 1];
  tail->kind = HEAP_FREE, tail->at = s;
  *head = (vx_heap_span){.kind = HEAP_FREE, .len = len, .at = s, .dirty = dirty};
  heap_push(h, &h->bucket[heap_bucket(len)], s);
  if (dirty) h->dirty += len;
}

// The free run headed at s out of its bucket.
static void heap_unfree(vx_heap *h, uint32_t s) {
  heap_unlink(h, &h->bucket[heap_bucket(h->span[s].len)], s);
  if (h->span[s].dirty) h->dirty -= h->span[s].len;
}

// Every free run's pages back to the system.
static void heap_sweep(vx_heap *h) {
  for (uint32_t b = 0; b < VX_HEAP_BUCKETS; b++)
    for (uint32_t i = h->bucket[b]; i; i = h->span[i - 1].next) {
      vx_heap_span *e = &h->span[i - 1];
      if (e->dirty) heap_decommit(h, i - 1, e->len), e->dirty = false;
    }
  h->dirty = 0;
}

// [s, s + len), its pages in use until now, freed and joined to the free
// runs on either side; the run may hold pages (dirty) until a sweep.
static void heap_release(vx_heap *h, uint32_t s, uint32_t len) {
  if (s && h->span[s - 1].kind == HEAP_FREE) { // the run before, by its tail
    uint32_t head = h->span[s - 1].at;
    heap_unfree(h, head);
    len += s - head, s = head;
  }
  uint32_t next = s + len;
  if (next < h->top && h->span[next].kind == HEAP_FREE) { // the run after, by its head
    heap_unfree(h, next);
    len += h->span[next].len;
  }
  heap_mark_free(h, s, len, true);
  if (h->dirty > VX_HEAP_DIRTY_MAX) heap_sweep(h);
}

// A free run of at least n spans out of the buckets, cut to n: its first
// span, or UINT32_MAX if there is none.
static uint32_t heap_take_free(vx_heap *h, uint32_t n) {
  for (uint32_t b = heap_bucket(n); b < VX_HEAP_BUCKETS; b++)
    for (uint32_t i = h->bucket[b]; i; i = h->span[i - 1].next) {
      uint32_t s = i - 1, len = h->span[s].len;
      if (len < n) continue;
      bool dirty = h->span[s].dirty;
      heap_unfree(h, s);
      if (len > n) heap_mark_free(h, s + n, len - n, dirty);
      return s;
    }
  return UINT32_MAX;
}

// n spans of the given kind (a slab's, a large block's): from a free run, or
// from the top, mapping what it needs. UINT32_MAX if there is no room.
static uint32_t heap_spans(vx_heap *h, uint32_t n, uint8_t kind) {
  vx_mutex_lock(&h->lock);
  uint32_t s = heap_take_free(h, n);
  if (s == UINT32_MAX && n <= h->spans - h->top && heap_map_through(h, h->top + n)) s = h->top, h->top += n;
  if (s != UINT32_MAX) {
    h->span[s] = (vx_heap_span){.kind = kind, .len = n};
    for (uint32_t i = 1; i < n; i++) h->span[s + i].kind = HEAP_INNER;
  }
  vx_mutex_unlock(&h->lock);
  return s;
}

static void heap_spans_free(vx_heap *h, uint32_t s) {
  vx_mutex_lock(&h->lock);
  heap_release(h, s, h->span[s].len);
  vx_mutex_unlock(&h->lock);
}

// --- Slabs, under their class's lock ---

static uint8_t *heap_span_addr(const vx_heap *h, uint32_t s) { return h->base + s * VX_HEAP_SPAN; }

static void *heap_small(vx_heap *h, uint32_t c) {
  vx_heap_class *k = &h->cls[c];
  uint32_t size = VX_HEAP_CLASS[c], room = (uint32_t)(VX_HEAP_SPAN / size);
  vx_mutex_lock(&k->lock);
  uint32_t s = k->partial ? k->partial - 1 : heap_spans(h, 1, HEAP_SLAB);
  if (s == UINT32_MAX) {
    vx_mutex_unlock(&k->lock);
    return nullptr;
  }
  vx_heap_span *e = &h->span[s];
  if (!k->partial) e->cls = (uint8_t)c, heap_push(h, &k->partial, s); // a new slab
  void *b = e->free;
  if (b)
    e->free = *(void **)b;
  else
    b = heap_span_addr(h, s) + e->at, e->at += size;     // `at`: how far it has handed out
  if (++e->used == room) heap_unlink(h, &k->partial, s); // full
  vx_mutex_unlock(&k->lock);
  return b;
}

// A slab's block back. A slab left empty goes back to the spans, unless it
// is its class's only one with room.
static void heap_small_free(vx_heap *h, uint32_t s, void *p) {
  vx_heap_span *e = &h->span[s];
  vx_heap_class *k = &h->cls[e->cls];
  uint32_t room = (uint32_t)(VX_HEAP_SPAN / VX_HEAP_CLASS[e->cls]);
  vx_mutex_lock(&k->lock);
  *(void **)p = e->free;
  e->free = p;
  if (e->used-- == room) heap_push(h, &k->partial, s); // it has room again
  bool spare = !e->used && (k->partial != s + 1 || e->next);
  if (spare) heap_unlink(h, &k->partial, s);
  vx_mutex_unlock(&k->lock);
  if (spare) heap_spans_free(h, s);
}

// --- The heap ---

// A heap of up to reserve bytes of address space (16 GiB at most), none of it
// memory until used; or, if none can be made, the nil heap, which gives
// nothing (09 §4.2: an object, never nullptr).
[[maybe_unused]] static vx_heap *vx_heap_new(size_t reserve) {
  uint64_t size = (reserve + VX_HEAP_SEGMENT - 1) / VX_HEAP_SEGMENT * VX_HEAP_SEGMENT;
  if (size < VX_HEAP_SEGMENT) size = VX_HEAP_SEGMENT;
  if (size > VX_HEAP_SEGMENTS * VX_HEAP_SEGMENT) size = VX_HEAP_SEGMENTS * VX_HEAP_SEGMENT;
  uint64_t base = 0;
  if (vx_as_reserve(vx_self, size, VX_HEAP_SPAN, 0, &base) != VX_OK) return &vx_heap_nil;
  vx_heap boot = {.base = (uint8_t *)base, .size = size, .spans = (uint32_t)(size / VX_HEAP_SPAN)};
  if (!heap_map_through(&boot, 1)) {
    vx_as_reserve(vx_self, size, 0, VX_AS_FIXED | VX_AS_RELEASE, &base);
    return &vx_heap_nil;
  }
  // The heap and its table in its first spans, which it never hands out.
  vx_heap *h = (vx_heap *)base;
  *h = boot;
  uint64_t table = (sizeof(vx_heap) + 63) & ~63ull;
  h->span = (vx_heap_span *)(base + table);
  uint64_t meta = (table + h->spans * sizeof(vx_heap_span) + VX_HEAP_SPAN - 1) / VX_HEAP_SPAN;
  heap_map_through(h, (uint32_t)meta); // within the first segment: 16 GiB's table is 8 MiB
  for (uint32_t i = 0; i < meta; i++) h->span[i].kind = HEAP_META;
  h->top = (uint32_t)meta;
  return h;
}

// Whether h is the nil heap, which vx_heap_new gives when it cannot make one.
[[maybe_unused]] static bool vx_heap_failed(const vx_heap *h) { return h->nil; }

// At least n bytes aligned to align (a power of two, up to 64 KiB), or nullptr.
[[maybe_unused]] static void *vx_heap_alloc_aligned(vx_heap *h, size_t n, size_t align) {
  if (h->nil || !align || (align & (align - 1)) || align > VX_HEAP_SPAN || n > h->size) return nullptr;
  if (!n) n = 1;
  for (uint32_t c = 0; c < VX_HEAP_CLASSES; c++)
    if (VX_HEAP_CLASS[c] >= n && VX_HEAP_CLASS[c] % align == 0) return heap_small(h, c);
  uint32_t s = heap_spans(h, (uint32_t)((n + VX_HEAP_SPAN - 1) / VX_HEAP_SPAN), HEAP_LARGE);
  return s == UINT32_MAX ? nullptr : heap_span_addr(h, s);
}

// At least n bytes, aligned to 16, or nullptr.
[[maybe_unused]] static void *vx_heap_alloc(vx_heap *h, size_t n) { return vx_heap_alloc_aligned(h, n, 16); }

// The span p is in, if it is a block's start: a slab's block or a large
// block's first byte. UINT32_MAX for anything else.
static uint32_t heap_block_span(const vx_heap *h, const void *p) {
  const uint8_t *b = p;
  if (h->nil || b < h->base || b >= h->base + (uint64_t)h->top * VX_HEAP_SPAN) return UINT32_MAX;
  uint32_t s = (uint32_t)((uint64_t)(b - h->base) / VX_HEAP_SPAN);
  uint64_t in = (uint64_t)(b - h->base) % VX_HEAP_SPAN;
  const vx_heap_span *e = &h->span[s];
  if (e->kind == HEAP_SLAB && in % VX_HEAP_CLASS[e->cls] == 0) return s;
  return e->kind == HEAP_LARGE && !in ? s : UINT32_MAX;
}

// p's block back to h; nullptr is nothing. Anything that is not a block of
// h's ends the program, as a fault would.
[[maybe_unused]] static void vx_heap_free(vx_heap *h, void *p) {
  if (!p) return;
  uint32_t s = heap_block_span(h, p);
  if (s == UINT32_MAX) __builtin_trap();
  if (h->span[s].kind == HEAP_SLAB)
    heap_small_free(h, s, p);
  else
    heap_spans_free(h, s);
}

// The bytes p's block holds, at least what was asked for: what its owner may
// use and grow into. 0 for what is not a block of h's.
[[maybe_unused]] static size_t vx_heap_usable(const vx_heap *h, const void *p) {
  uint32_t s = heap_block_span(h, p);
  if (s == UINT32_MAX) return 0;
  const vx_heap_span *e = &h->span[s];
  return e->kind == HEAP_SLAB ? VX_HEAP_CLASS[e->cls] : e->len * VX_HEAP_SPAN;
}

// The process heap: one per process, made at first use, for a C library's
// malloc family and anything else that wants one global heap.
[[maybe_unused]] static vx_heap *vx_heap_process(void) {
  static vx_heap *_Atomic the;
  static vx_mutex making;
  vx_heap *h = atomic_load_explicit(&the, memory_order_acquire);
  if (h) return h;
  vx_mutex_lock(&making);
  h = atomic_load_explicit(&the, memory_order_relaxed);
  if (!h) h = vx_heap_new(VX_HEAP_SEGMENTS * VX_HEAP_SEGMENT);
  atomic_store_explicit(&the, h, memory_order_release);
  vx_mutex_unlock(&making);
  return h;
}
