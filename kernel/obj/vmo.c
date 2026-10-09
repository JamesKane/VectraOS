// vmo.c: virtual memory objects (docs/01 §5).
//
// An anonymous VMO's pages are all allocated and zeroed when it is created:
// commit, not overcommit, so a task learns it is out of memory from a failed
// call, never from a fault later. A lazy one (VX_VMO_LAZY, ADR-0046) has
// none until a touch makes one, and gives them back with DECOMMIT. The page list is one block of physical
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
  bool resizing;     // a resize under way (pager.c), which drops the lock between its steps
  bool resizable;    // anonymous, made VX_VMO_RESIZABLE (ADR-0042): its page list under its lock too
  bool lazy;         // anonymous, made VX_VMO_LAZY (ADR-0046): pages made at a touch; its list under its lock
  uint32_t trace_id; // what the trace calls it (COMMIT, 7a4b): kernel addresses never appear in records
  uint8_t cache;     // a physical one's vx_cache_policy (ADR-0051), set before its first mapping
  bool ever_mapped;  // it has been mapped: its cache policy is fixed
  // ADR-0043: a sealed VMO is written by no one again; a lease is a VMO on
  // its parent's pages (pages and list are the parent's), which it holds,
  // until it is revoked.
  _Atomic bool sealed;
  struct vmo *lease_of;
  _Atomic bool revoked;
} vmo;

// The VMO whose pages v shows: its parent, for a lease.
static vmo *vmo_root(vmo *v) { return v->lease_of ? v->lease_of : v; }
static bool vmo_sealed(vmo *v) { return atomic_load(&vmo_root(v)->sealed); }
static bool vmo_revoked(vmo *v) { return v->lease_of && atomic_load(&v->revoked); }

// Whether v's page list may change under a reader (a pager's VMO, a
// resizable or lazy one): read it under v's lock.
static bool vmo_locked(const vmo *v) { return v->pager || v->resizable || v->lazy; }

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
  static _Atomic uint32_t trace_ids;
  uint32_t trace_id = atomic_fetch_add_explicit(&trace_ids, 1, memory_order_relaxed) + 1;
  uint64_t list = phys_alloc(order);
  if (!list) {
    pool_free(&vmo_pool, v);
    return VX_ERR_NO_MEMORY;
  }
  v->trace_id = trace_id;
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

// A lazy anonymous VMO (ADR-0046): no pages until a touch.
static vx_status vmo_create_lazy(uint64_t size, vmo **out) {
  vx_status st = vmo_create_pages(size, true, out);
  if (st == VX_OK) (*out)->lazy = true;
  return st;
}

// A private copy's VMO for a mapping of v (a fork's, a debugger's): lazy if v
// is, so only the pages v has are paid for.
static vx_status vmo_create_like(const vmo *v, uint64_t size, vmo **out) {
  return v->lazy ? vmo_create_lazy(size, out) : vmo_create(size, out);
}

// Page i of v, made zero if v is lazy and has none; 0 if it has none and is
// not lazy, or memory ran out. Under v's lock if it is locked (vmo_locked).
static uint64_t vmo_page_make(vmo *v, uint64_t i) {
  uint64_t pa = vmo_page(v, i);
  if (pa || !v->lazy) return pa;
  pa = phys_alloc_zeroed(0);
  if (pa) v->pages[i] = pa;
  return pa;
}

// vmo_lease (ADR-0043): a VMO on parent's pages, holding it. Only a plain
// anonymous VMO, whose page list never changes, is leased (not a lazy one,
// ADR-0046).
static vx_status vmo_lease_create(vmo *parent, vmo **out) {
  if (parent->lease_of) return VX_ERR_INVALID; // one level
  if (parent->physical || parent->pager || parent->resizable || parent->lazy || parent->ring)
    return VX_ERR_UNSUPPORTED;
  vmo *v = pool_alloc(&vmo_pool);
  if (!v) return VX_ERR_NO_MEMORY;
  v->obj.type = OBJ_VMO;
  atomic_store_explicit(&v->obj.refs, 1, memory_order_relaxed);
  object_ref(&parent->obj);
  v->lease_of = parent, v->size = parent->size, v->pages = parent->pages, v->list_order = parent->list_order;
  *out = v;
  return VX_OK;
}

static void pager_drop_vmo(vmo *v); // pager.c: a pager-backed VMO's last reference

static void vmo_destroy(vmo *v) {
  if (v->lease_of) { // its pages are its parent's
    vmo *parent = v->lease_of;
    pool_free(&vmo_pool, v);
    object_drop(&parent->obj); // the drain that destroys this destroys it too, if it was the last
    return;
  }
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
