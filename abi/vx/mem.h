// vx/mem.h: heaps (arenas and pools come in M6 step 6e4c) (09 §5.2, ADR-0004 libvx v0).
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
