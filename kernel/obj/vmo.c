// vmo.c: anonymous virtual memory objects (docs/01 §5).
//
// An anonymous VMO's pages are all allocated and zeroed when it is created:
// commit, not overcommit, so a task learns it is out of memory from a failed
// call, never from a fault later. The page list is one block of physical
// addresses. Clones, pagers, physical VMOs and resizing come in later milestones.

typedef struct vmo {
  object obj;
  uint64_t size;       // bytes, a multiple of 4096
  uint64_t *pages;     // physical address of each page, through the direct map
  unsigned list_order; // the page list's allocation order
} vmo;

static pool vmo_pool = POOL_FOR(vmo);

static constexpr uint64_t VMO_MAX_SIZE = 256ull << 20; // the list fits one order-7 block

static vx_status vmo_create(uint64_t size, vmo **out) {
  if (size == 0 || size > VMO_MAX_SIZE) return VX_ERR_RANGE;
  size = (size + 4095) & ~4095ull;
  uint64_t count = size / 4096;
  unsigned order = 0;
  while ((4096ull << order) < count * sizeof(uint64_t)) order++;

  vmo *v = pool_alloc(&vmo_pool);
  if (!v) return VX_ERR_NO_MEMORY;
  uint64_t list = phys_alloc(order);
  if (!list) {
    pool_free(&vmo_pool, v);
    return VX_ERR_NO_MEMORY;
  }
  *v = (vmo){
      .obj = {.type = OBJ_VMO, .refs = 1}, .size = size, .pages = phys_to_virt(list), .list_order = order};
  for (uint64_t i = 0; i < count; i++) {
    v->pages[i] = phys_alloc_zeroed(0);
    if (!v->pages[i]) {
      while (i--) phys_free(v->pages[i], 0);
      phys_free(list, order);
      pool_free(&vmo_pool, v);
      return VX_ERR_NO_MEMORY;
    }
  }
  *out = v;
  return VX_OK;
}

static void vmo_destroy(vmo *v) {
  for (uint64_t i = 0; i < v->size / 4096; i++) phys_free(v->pages[i], 0);
  phys_free((uint64_t)v->pages - boot.hhdm, v->list_order);
  pool_free(&vmo_pool, v);
}

// Copies kernel bytes into the VMO.
static void vmo_write(vmo *v, uint64_t offset, const void *src, uint64_t len) {
  const uint8_t *s = src;
  while (len) {
    uint64_t in_page = offset & 4095, n = 4096 - in_page;
    if (n > len) n = len;
    memcpy((uint8_t *)phys_to_virt(v->pages[offset / 4096]) + in_page, s, n);
    offset += n;
    s += n;
    len -= n;
  }
}
