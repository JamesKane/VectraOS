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
// and the rest as it is touched. A page is mapped read-only, even in a
// writable mapping, until it is written: that write faults, marks it dirty
// (PAGE_DIRTY) and maps it writable, which is how the pager learns what to
// write back (pager_op DIRTY). Cleaning takes the pages out of every
// mapping, so the next write marks them again. The kernel's own copies to and from user
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

// A user fault at address (access: read 0, write 1, execute 2) in the
// current task: resolved here if it is on a pager-backed mapping, or on a
// lazy one (ADR-0046), whose page is made zero at the touch; with no memory
// for it the fault stands.
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
    if (!m || !(m->vmo->pager || m->vmo->lazy) || (m->flags & VX_MAP_NOACCESS) ||
        (access == 1 && !(m->flags & VX_MAP_WRITE)) || (access == 2 && !(m->flags & VX_MAP_EXEC))) {
      spin_unlock(&t->lock);
      return PAGER_NOT_MINE;
    }
    vmo *v = m->vmo;
    uint64_t index = (m->offset + (page_va - m->va)) / 4096;
    spin_lock(&v->lock);
    if (index >= v->size / 4096) { // past its end, since it shrank: an ordinary fault
      spin_unlock(&v->lock);
      spin_unlock(&t->lock);
      return PAGER_NOT_MINE;
    }
    uint64_t pa = vmo_page_make(v, index); // a lazy one's made now
    if (!pa && v->lazy) {                  // no memory: the fault stands
      spin_unlock(&v->lock);
      spin_unlock(&t->lock);
      return PAGER_NOT_MINE;
    }
    if (pa) { // supplied: mapped here now (another thread may have done it first), dirty if written
      if (access == 1 && v->pager) v->pages[index] |= PAGE_DIRTY;
      int level;
      uint64_t *e = leaf_entry(t->root, page_va, &level);
      bool upgrade = e && access == 1 && !arch_pte_user_ok(*e, true); // read-only until now
      if (upgrade) unmap_page(t->root, page_va);
      bool ok = (e && !upgrade) || map_range(t->root, page_va, pa, 4096, page_flags(m, v->pages[index]));
      uint64_t root = t->root;
      spin_unlock(&v->lock);
      spin_unlock(&t->lock);
      if (upgrade) arch_tlb_shootdown(root, page_va, 4096); // no CPU keeps the read-only translation
      return ok ? PAGER_MAPPED : PAGER_NOT_MINE;            // no memory for a table: the fault stands
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
    vx_status asked = !ask ? VX_OK
                           : port_post(g->port, &(vx_packet){.key = g->key,
                                                             .value = index * 4096,
                                                             .timestamp = clock_now(),
                                                             .source = v->pager_key,
                                                             .trigger = VX_TRIGGER_PAGER});
    if (!deadline) deadline = clock_now() + g->deadline;
    // A request the port had no room for is not lost: the page is left
    // unasked, and this thread asks again shortly, until its deadline.
    if (asked != VX_OK) {
      spin_lock(&v->lock);
      if (v->pages[index] == PAGE_ASKED) v->pages[index] = 0;
      spin_unlock(&v->lock);
    }
    vx_instant until = deadline;
    if (asked != VX_OK && clock_now() + 1'000'000 < deadline) until = clock_now() + 1'000'000;
    int64_t woke = thread_block(until, 0);
    if (woke == VX_ERR_TIMED_OUT && until != deadline) woke = VX_OK; // only the retry's wait
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
    arch_page_copy(phys_to_virt(pa), phys_to_virt(src->pages[src_offset / 4096 + i]), 4096);
    spin_lock(&v->lock);
    // Past the end now (a shrink since the check above): not kept.
    bool taken = offset / 4096 + i >= v->size / 4096 || vmo_page(v, offset / 4096 + i) != 0;
    if (!taken) v->pages[offset / 4096 + i] = pa;
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

// --- Taking pages out of mappings ---

// Pages [first, first + count) of v, out of every task's mappings of it,
// and out of every CPU's TLB: the next touch faults (pager_fault).
static void vmo_unmap_everywhere(vmo *v, uint64_t first, uint64_t count) {
  uint64_t last_id = 0;
  for (;;) {
    task *t = nullptr; // the task with the next id
    spin_lock(&all_tasks_lock);
    for (task *c = all_tasks; c; c = c->all_next)
      if (c->id > last_id && (!t || c->id < t->id)) t = c;
    bool held = t && object_tryref(&t->obj); // one going away is skipped: its mappings go with it
    if (t) last_id = t->id;
    spin_unlock(&all_tasks_lock);
    if (!t) return;
    if (!held) continue;
    uint64_t lo[TASK_MAX_MAPPINGS / 8], len[TASK_MAX_MAPPINGS / 8];
    uint32_t n = 0;
    spin_lock(&t->lock);
    for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS; i++) {
      mapping *m = &t->maps[i];
      if (!m->size || m->vmo != v) continue;
      uint64_t mfirst = m->offset / 4096, mend = mfirst + m->size / 4096;
      uint64_t a = first > mfirst ? first : mfirst, b = first + count < mend ? first + count : mend;
      if (a >= b) continue;
      uint64_t va = m->va + (a - mfirst) * 4096;
      for (uint64_t p = 0; p < b - a; p++) unmap_page(t->root, va + p * 4096);
      if (n < TASK_MAX_MAPPINGS / 8)
        lo[n] = va, len[n++] = (b - a) * 4096;
      else
        lo[0] = 0, len[0] = USER_TOP, n = 1; // many: all of it
    }
    uint64_t root = t->root;
    spin_unlock(&t->lock);
    for (uint32_t i = 0; root && i < n; i++) arch_tlb_shootdown(root, lo[i], len[i]);
    object_release(&t->obj);
  }
}

// Whether any task maps v, or a lease of it, writable (vmo_seal, ADR-0043):
// task by task in id order, as vmo_unmap_everywhere goes, each held while
// its mappings are looked at.
static bool vmo_mapped_writable(vmo *v) {
  uint64_t last_id = 0;
  bool found = false;
  while (!found) {
    task *t = nullptr; // the task with the next id
    spin_lock(&all_tasks_lock);
    for (task *c = all_tasks; c; c = c->all_next)
      if (c->id > last_id && (!t || c->id < t->id)) t = c;
    bool held = t && object_tryref(&t->obj);
    if (t) last_id = t->id;
    spin_unlock(&all_tasks_lock);
    if (!t) break;
    if (!held) continue;
    spin_lock(&t->lock);
    for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS && !found; i++) {
      const mapping *m = &t->maps[i];
      found = m->size && (m->flags & VX_MAP_WRITE) && vmo_root(m->vmo) == v;
    }
    spin_unlock(&t->lock);
    object_release(&t->obj);
  }
  return found;
}

// --- pager_op ---

// DIRTY: the dirty pages of [offset, offset + size) as ranges, into out
// (VX_PAGER_RANGES of them at most): how many.
static int64_t pager_dirty(vmo *v, uint64_t offset, uint64_t size, vx_pager_range *out) {
  uint32_t n = 0;
  spin_lock(&v->lock);
  uint64_t end = (offset + size) / 4096 < v->size / 4096 ? (offset + size) / 4096 : v->size / 4096;
  for (uint64_t i = offset / 4096; i < end && n < VX_PAGER_RANGES; i++) {
    if (!vmo_page(v, i) || !(v->pages[i] & PAGE_DIRTY)) continue;
    if (n && out[n - 1].offset + out[n - 1].size == i * 4096)
      out[n - 1].size += 4096;
    else
      out[n++] = (vx_pager_range){.offset = i * 4096, .size = 4096};
  }
  spin_unlock(&v->lock);
  return n;
}

// CLEAN: [offset, offset + size) clean, and write-protected everywhere, so
// that a write from now on marks it dirty again. The pager cleans before it
// reads a range to write it back: a write that lands before the clean is in
// what it reads, one after it is dirty for the next time.
static void pager_clean(vmo *v, uint64_t first, uint64_t count) {
  spin_lock(&v->lock);
  for (uint64_t i = first; i < first + count && i < v->size / 4096; i++)
    if (vmo_page(v, i)) v->pages[i] &= ~PAGE_DIRTY;
  spin_unlock(&v->lock);
  vmo_unmap_everywhere(v, first, count);
}

// EVICT: the clean pages of [offset, offset + size) freed, absent again (a
// later touch asks the pager for them). A page is made absent before it
// leaves the mappings, and freed only after, so nothing maps a freed page.
static void pager_evict(vmo *v, uint64_t first, uint64_t count) {
  for (uint64_t at = first; at < first + count;) {
    uint64_t freed[64];
    uint32_t n = 0;
    uint64_t from = at;
    spin_lock(&v->lock);
    for (; at < first + count && at < v->size / 4096 && n < 64; at++) {
      uint64_t pa = vmo_page(v, at);
      if (!pa || (v->pages[at] & PAGE_DIRTY)) continue;
      freed[n++] = pa;
      v->pages[at] = 0;
    }
    bool past = at >= v->size / 4096;
    spin_unlock(&v->lock);
    vmo_unmap_everywhere(v, from, at - from);
    for (uint32_t i = 0; i < n; i++) phys_free(freed[i], 0);
    if (past) break;
  }
}

// --- vmo_op decommit ---

// DECOMMIT (ADR-0046): a lazy VMO's pages in [offset, offset + size) freed,
// absent again (a touch makes them zero). Each made absent under the lock,
// out of every mapping, and only then freed, as EVICT does.
static vx_status vmo_decommit(vmo *v, uint64_t offset, uint64_t size) {
  uint64_t end;
  if (!v->lazy) return VX_ERR_UNSUPPORTED;
  if ((offset | size) & 4095) return VX_ERR_INVALID;
  if (ckd_add(&end, offset, size)) return VX_ERR_RANGE;
  spin_lock(&v->lock);
  bool past = end > v->size;
  spin_unlock(&v->lock);
  if (past) return VX_ERR_RANGE;
  for (uint64_t at = offset / 4096; at < end / 4096;) {
    uint64_t freed[64], from = at;
    uint32_t n = 0;
    spin_lock(&v->lock);
    for (; at < end / 4096 && at < v->size / 4096 && n < 64; at++) {
      uint64_t pa = vmo_page(v, at);
      if (pa) freed[n++] = pa;
      v->pages[at] = 0;
    }
    bool shrunk = at < end / 4096 && at >= v->size / 4096; // a resize took the rest meanwhile
    spin_unlock(&v->lock);
    if (n) vmo_unmap_everywhere(v, from, at - from);
    for (uint32_t i = 0; i < n; i++) phys_free(freed[i], 0);
    if (shrunk) break;
  }
  return VX_OK;
}

// --- vmo_op resize ---

// A pager-backed or resizable VMO's new size: pages past it out of the
// mappings and freed; pages added absent (a pager's) or zero (a resizable
// one's, ADR-0042). Its page list is made again if it outgrows it.
static vx_status vmo_resize(vmo *v, uint64_t size) {
  if (!vmo_locked(v)) return VX_ERR_UNSUPPORTED; // read without its lock: made VX_VMO_RESIZABLE to resize
  if (!size || size > VMO_MAX_SIZE) return VX_ERR_RANGE;
  size = (size + 4095) & ~4095ull;
  uint64_t count = size / 4096;
  unsigned order = 0;
  while ((4096ull << order) < count * sizeof(uint64_t)) order++;
  uint64_t list = order > v->list_order ? phys_alloc(order) : 0;
  if (order > v->list_order && !list) return VX_ERR_NO_MEMORY;
  if (list) memset(phys_to_virt(list), 0, 4096ull << order);
  spin_lock(&v->lock);
  if (v->resizing) { // one at a time: a shrink drops the lock between its steps
    spin_unlock(&v->lock);
    if (list) phys_free(list, order);
    return VX_ERR_BAD_STATE;
  }
  v->resizing = true;
  uint64_t old = v->size / 4096;
  if (count < old) {
    // Faults and new mappings past the end are refused from now on
    // (pager_fault, task_map). Then the pages past it, a batch at a time:
    // each made absent under the lock, out of every mapping, and only then
    // freed, so no mapping is ever left on a freed page (as EVICT does).
    v->size = size;
    for (uint64_t at = count; at < old;) {
      uint64_t freed[64], from = at;
      uint32_t n = 0;
      for (; at < old && n < 64; at++) {
        uint64_t pa = vmo_page(v, at);
        if (pa) freed[n++] = pa;
        v->pages[at] = 0;
      }
      spin_unlock(&v->lock);
      vmo_unmap_everywhere(v, from, at - from);
      for (uint32_t i = 0; i < n; i++) phys_free(freed[i], 0);
      spin_lock(&v->lock);
    }
  }
  uint64_t old_list = 0;
  unsigned old_order = v->list_order;
  if (list) { // a bigger list: what there is, moved over (past the old end, every entry is 0)
    uint64_t *pages = phys_to_virt(list);
    for (uint64_t i = 0; i < old && i < count; i++) pages[i] = v->pages[i];
    old_list = (uint64_t)v->pages - boot.hhdm;
    v->pages = pages, v->list_order = order;
  }
  // A resizable VMO's new pages, zero; if memory runs out, it keeps the size
  // it reached.
  vx_status st = VX_OK;
  for (uint64_t i = old; v->resizable && !v->lazy && i < count && st == VX_OK; i++) { // a lazy one's: absent
    v->pages[i] = phys_alloc_zeroed(0);
    if (!v->pages[i]) size = i * 4096, st = VX_ERR_NO_MEMORY;
  }
  if (size > v->size || !v->resizable) v->size = size;
  v->resizing = false;
  // Waiters look again: one whose page is now past the end faults as usual.
  page_waiter *w = v->waiters;
  v->waiters = nullptr;
  for (; w; w = w->next) thread_wake_token(w->thread, w, VX_OK);
  spin_unlock(&v->lock);
  if (old_list) phys_free(old_list, old_order);
  return st;
}
