// vmo.c: virtual memory objects (docs/01 §5).
//
// An anonymous VMO's pages are all allocated and zeroed when it is created:
// commit, not overcommit, so a task learns it is out of memory from a failed
// call, never from a fault later. The page list is one block of physical
// addresses. Physical VMOs (device memory) are made in device.c. A
// pager-backed VMO (pager.c) starts with none: a page's entry is 0 until its
// pager is asked for it, PAGE_ASKED until it is supplied, and its address
// from then on, with PAGE_DIRTY in its low bits once it has been written;
// its lock covers the list and the threads waiting on it.

typedef struct vmo {
  object obj;
  uint64_t size;       // bytes, a multiple of 4096
  uint64_t *pages;     // physical address of each page, through the direct map
  unsigned list_order; // the page list's allocation order
  bool physical;       // device memory (device.c): its pages are not RAM, and are never freed
  bool ring;           // a ring's memory (ring.c), never copied into a forked task
  struct pager *pager; // its pages' supplier (pager.c), which it holds; or nullptr
  uint32_t pager_key;  // what its page requests call it
  spinlock lock;       // a pager-backed one's: its page list, and waiters
  struct page_waiter *waiters;
  bool resizing; // a resize under way (pager.c), which drops the lock between its steps
} vmo;

static constexpr uint64_t PAGE_ASKED = 1; // a pager-backed page asked for, not yet supplied
static constexpr uint64_t PAGE_DIRTY = 2; // a pager-backed page written since it was supplied or cleaned

// The address of page i, or 0 if a pager has not supplied it.
static uint64_t vmo_page(const vmo *v, uint64_t i) {
  return v->pages[i] > PAGE_ASKED ? v->pages[i] & ~4095ull : 0;
}

static pool vmo_pool = POOL_FOR(vmo);

static constexpr uint64_t VMO_MAX_SIZE = 256ull << 20; // the list fits one order-7 block

// A VMO of `size` bytes, its pages allocated and zeroed, or with `lazy`
// none (a pager's to supply).
static vx_status vmo_create_pages(uint64_t size, bool lazy, vmo **out) {
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
  v->obj.type = OBJ_VMO;
  atomic_store_explicit(&v->obj.refs, 1, memory_order_relaxed);
  v->size = size;
  v->pages = phys_to_virt(list);
  v->list_order = order;
  if (lazy) memset(v->pages, 0, 4096ull << order);
  for (uint64_t i = 0; !lazy && i < count; i++) {
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

static vx_status vmo_create(uint64_t size, vmo **out) { return vmo_create_pages(size, false, out); }

static void pager_drop_vmo(vmo *v); // pager.c: a pager-backed VMO's last reference

static void vmo_destroy(vmo *v) {
  for (uint64_t i = 0; !v->physical && i < v->size / 4096; i++)
    if (vmo_page(v, i)) phys_free(vmo_page(v, i), 0);
  if (v->pager) pager_drop_vmo(v);
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
