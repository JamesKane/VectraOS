// pager.c: pagers, a trusted task's supply of pages for VMOs (docs/01 §5,
// docs/11 §8). fsd backs mmap of files with one.
//
// A pager-backed VMO starts with no pages. A user fault on one of them
// (pager_fault, from exception_raise) asks the pager for it: a packet on
// the pager's port, sent once however many threads fault on the page, and
// the faulting thread waits. pager_supply copies the pages in and wakes the
// waiters, which map them as their faults are taken again. A page that does
// not come by the pager's deadline is the thread's VX_EXCEPTION_PAGER_TIMEOUT
// instead, never a hang; the next fault on it asks again.
//
// Faults are resolved one page at a time, mapping only the faulting page:
// a mapping of a pager-backed VMO maps what is supplied when it is made,
// and the rest as it is touched. The kernel's own copies to and from user
// memory (copy_from_user) take no page that is not there yet: they fail,
// as on a page that is not mapped, since some are made under locks.

typedef struct pager {
  object obj;
  struct port *port; // where page requests go, held
  uint64_t key;
  vx_duration deadline;
} pager;

typedef struct page_waiter {
  struct page_waiter *next;
  thread *thread;
} page_waiter;

static pool pager_pool = POOL_FOR(pager);

static vx_status pager_create(port *p, uint64_t key, vx_duration deadline, pager **out) {
  if (!deadline) return VX_ERR_INVALID;
  pager *g = pool_alloc(&pager_pool);
  if (!g) return VX_ERR_NO_MEMORY;
  g->obj.type = OBJ_PAGER;
  atomic_store_explicit(&g->obj.refs, 1, memory_order_relaxed);
  object_ref(&p->obj);
  g->port = p, g->key = key, g->deadline = deadline;
  *out = g;
  return VX_OK;
}

static void pager_destroy(pager *g) {
  object_drop(&g->port->obj);
  pool_free(&pager_pool, g);
}

static void pager_drop_vmo(vmo *v) { object_drop(&v->pager->obj); }

// A VMO of `size` bytes whose pages g supplies, none yet.
static vx_status vmo_create_pager(uint64_t size, pager *g, uint32_t key, vmo **out) {
  vx_status st = vmo_create_pages(size, true, out);
  if (st != VX_OK) return st;
  object_ref(&g->obj);
  (*out)->pager = g, (*out)->pager_key = key;
  return VX_OK;
}

typedef enum pager_result : uint8_t {
  PAGER_NOT_MINE, // not a pager-backed page, or not an access its mapping allows: an ordinary fault
  PAGER_MAPPED,   // the page is mapped: the access may be made again
  PAGER_TIMEOUT,  // the pager did not supply it in time
  PAGER_KILLED,   // the thread was killed while it waited
} pager_result;

static uint32_t mapping_flags(const mapping *m) {
  return MAP_USER | (m->flags & VX_MAP_WRITE ? MAP_WRITE : 0) | (m->flags & VX_MAP_EXEC ? MAP_EXEC : 0);
}

// A user fault at address (access: read 0, write 1, execute 2) in the
// current task: resolved here if it is on a pager-backed mapping.
static pager_result pager_fault(uint64_t address, uint32_t access) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  uint64_t page_va = address & ~4095ull;
  vx_instant deadline = 0; // set at the first wait, and kept: a supply of other pages does not extend it
  for (;;) {
    spin_lock(&t->lock);
    mapping *m = nullptr;
    for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS && !m; i++)
      if (t->maps[i].size && address >= t->maps[i].va && address < t->maps[i].va + t->maps[i].size)
        m = &t->maps[i];
    if (!m || !m->vmo->pager || (access == 1 && !(m->flags & VX_MAP_WRITE)) ||
        (access == 2 && !(m->flags & VX_MAP_EXEC))) {
      spin_unlock(&t->lock);
      return PAGER_NOT_MINE;
    }
    vmo *v = m->vmo;
    uint64_t index = (m->offset + (page_va - m->va)) / 4096;
    spin_lock(&v->lock);
    uint64_t pa = vmo_page(v, index);
    if (pa) { // supplied: mapped here now (another thread may have done it first)
      int level;
      bool there = leaf_entry(t->root, page_va, &level) != nullptr;
      bool ok = there || map_range(t->root, page_va, pa, 4096, mapping_flags(m));
      spin_unlock(&v->lock);
      spin_unlock(&t->lock);
      return ok ? PAGER_MAPPED : PAGER_NOT_MINE; // no memory for a table: the fault stands
    }
    // Not there: ask for it, if no one has, and wait.
    bool ask = !v->pages[index];
    if (ask) v->pages[index] = PAGE_ASKED;
    page_waiter w = {.next = v->waiters, .thread = th};
    v->waiters = &w;
    th->wait_token = &w;
    object_ref(&v->obj);
    pager *g = v->pager;
    spin_unlock(&v->lock);
    spin_unlock(&t->lock);
    if (ask)
      port_post(g->port, &(vx_packet){.key = g->key,
                                      .value = index * 4096,
                                      .timestamp = clock_now(),
                                      .source = v->pager_key,
                                      .trigger = VX_TRIGGER_PAGER});
    if (!deadline) deadline = clock_now() + g->deadline;
    int64_t woke = thread_block(deadline, 0);
    spin_lock(&v->lock);
    for (page_waiter **link = &v->waiters; *link; link = &(*link)->next)
      if (*link == &w) {
        *link = w.next;
        break;
      }
    bool supplied = vmo_page(v, index) != 0;
    if (!supplied && woke == VX_ERR_TIMED_OUT && v->pages[index] == PAGE_ASKED)
      v->pages[index] = 0; // the next fault asks again
    spin_unlock(&v->lock);
    object_release(&v->obj);
    if (supplied) continue; // mapped on the next pass
    if (woke == VX_ERR_TIMED_OUT) return PAGER_TIMEOUT;
    if (woke != VX_OK) return PAGER_KILLED;
  }
}

// pager_supply: v's pages [offset, offset + size) from src's, where v has none.
static vx_status pager_supply(pager *g, vmo *v, uint64_t offset, uint64_t size, vmo *src,
                              uint64_t src_offset) {
  uint64_t end, src_end;
  if (v->pager != g) return VX_ERR_INVALID;
  if (src->pager || src->physical) return VX_ERR_UNSUPPORTED; // from anonymous memory only
  if (!size || (offset | size | src_offset) & 4095 || ckd_add(&end, offset, size) || end > v->size ||
      ckd_add(&src_end, src_offset, size) || src_end > src->size)
    return VX_ERR_RANGE;
  // The new pages first, outside the lock: allocation may take a while.
  uint64_t count = size / 4096;
  vx_status st = VX_OK;
  for (uint64_t i = 0; i < count && st == VX_OK; i++) {
    uint64_t pa = phys_alloc(0);
    if (!pa) {
      st = VX_ERR_NO_MEMORY;
      break;
    }
    memcpy(phys_to_virt(pa), phys_to_virt(src->pages[src_offset / 4096 + i]), 4096);
    spin_lock(&v->lock);
    uint64_t *slot = &v->pages[offset / 4096 + i];
    bool taken = vmo_page(v, offset / 4096 + i) != 0;
    if (!taken) *slot = pa;
    spin_unlock(&v->lock);
    if (taken) phys_free(pa, 0); // supplied already: it stays as it was
  }
  // Every waiter tries again: those whose pages came map them, the rest wait on.
  spin_lock(&v->lock);
  page_waiter *w = v->waiters;
  v->waiters = nullptr;
  for (; w; w = w->next) thread_wake_token(w->thread, w, VX_OK);
  spin_unlock(&v->lock);
  return st;
}
