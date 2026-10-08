// vx/mem.h: arenas, scratch, pools and heaps (09 §4.3, §5.2, ADR-0004 libvx v0).
// libvx's public declarations: a native program's, and the system's own
// programs' through lib/vx-rt (VX_API, api.h).

#pragma once

#include "api.h"
typedef struct vx_heap vx_heap; // a general allocator object (09 §4.3)

VX_API vx_heap *vx_heap_new(size_t reserve);
VX_API bool vx_heap_failed(const vx_heap *h);
VX_API void *vx_heap_alloc_aligned(vx_heap *h, size_t n, size_t align);
VX_API void *vx_heap_alloc(vx_heap *h, size_t n);
VX_API void vx_heap_free(vx_heap *h, void *p);
VX_API size_t vx_heap_usable(const vx_heap *h, const void *p);
VX_API vx_heap *vx_heap_process(void);

// An arena: a reserved range whose pages are made as they are touched;
// pushing is pure (09 §4.3). A failed vx_arena_new gives the nil arena, on
// which every call does nothing; a failed push gives nullptr. Either way
// vx_arena_error says why, and vx_errstr in words.
typedef struct vx_arena vx_arena;
typedef struct vx_mark {
  size_t used;
} vx_mark;

VX_API vx_arena *vx_arena_new(size_t reserve);
VX_API void vx_arena_free(vx_arena *a);
VX_API void *vx_push(vx_arena *a, size_t size, size_t align); // zeroed
VX_API vx_mark vx_arena_mark(const vx_arena *a);
VX_API void vx_arena_pop(vx_arena *a, vx_mark m);
VX_API vx_status vx_arena_error(const vx_arena *a);
// One of the calling thread's two scratch arenas that is none of conflicts:
// a callee's scratch never overlaps its caller's. Mark it, and pop it after.
VX_API vx_arena *vx_scratch(vx_arena *const *conflicts, size_t n);

// A pool: fixed-size slots in an arena, each named by an id, an index and a
// generation (09 §4.4), so a stale id finds nothing. 0 is no id.
typedef struct vx_pool vx_pool;
typedef uint64_t vx_id;

VX_API vx_pool *vx_pool_new(vx_arena *a, size_t slot_size, size_t max);
VX_API vx_id vx_pool_take(vx_pool *p); // a zeroed slot, or 0 when full
VX_API void *vx_pool_get(const vx_pool *p, vx_id id);
VX_API void vx_pool_put(vx_pool *p, vx_id id);
VX_API vx_status vx_pool_error(const vx_pool *p);
