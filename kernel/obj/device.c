// device.c: what user-space drivers get from the kernel (docs/01 §7.1): the
// Resource, Irq and IoRange objects, and physical VMOs.
//
// The Resource is root authority over device space: physical memory that is
// not RAM, interrupt lines and I/O ports. The kernel gives it to the root task
// (root.c), which mints narrower objects from it for each driver. (Narrower
// Resources, for devmgr to hand on, come with devmgr.)
//
// An Irq owns one line. When the line fires, the kernel counts it and fires
// the IRQ binding, or remembers that it fired so the next binding fires at
// once. A level-triggered line is masked until irq_ack, since it would fire
// again at once; an edge-triggered line is never masked, because an edge that
// arrived while it was masked would be lost, and with it the device. A driver
// therefore handles everything the device has pending before it binds again.
//
// The kernel's console belongs to the kernel only until a driver is given its
// device: from then on the kernel writes to it only to report a panic.

typedef struct resource {
  object obj;
} resource;

typedef struct irq {
  object obj;
  spinlock lock;
  uint32_t line;
  bool level;   // masked when it fires, until irq_ack
  bool masked;  // by the kernel, now
  bool pending; // fired with no binding to tell
  uint64_t count;
  observers obs; // IRQ bindings
} irq;

typedef struct iorange {
  object obj;
  uint16_t base;
  uint32_t count; // up to 0x10000: every port
} iorange;

static pool resource_pool = POOL_FOR(resource);
static pool irq_pool = POOL_FOR(irq);
static pool iorange_pool = POOL_FOR(iorange);

static constexpr uint32_t MAX_IRQ_LINES = 2048;
static constexpr uint32_t MSI_LINE_BASE = 1024; // lines from here are MSIs (arch_msi_create)
static irq *irq_lines[MAX_IRQ_LINES];           // under irq_lines_lock; at most one Irq per line
static spinlock irq_lines_lock;

// A driver has the console's device. With vx.kconsole on the command line the
// kernel keeps writing to it anyway, for debugging what goes on after.
static void console_hand_off(void) {
  if (!cmdline_has(VX_STR("vx.kconsole"))) console_handed_off = true;
}

static resource *root_resource(void) {
  resource *r = pool_alloc(&resource_pool);
  if (!r) panic(VX_STR("no memory for the root resource"));
  r->obj.type = OBJ_RESOURCE;
  atomic_store_explicit(&r->obj.refs, 1, memory_order_relaxed);
  return r;
}

// --- Physical VMOs ---

// A VMO over [pa, pa + size) of device memory, which may not overlap RAM or
// firmware memory.
static vx_status vmo_create_physical(uint64_t pa, uint64_t size, vmo **out) {
  uint64_t end;
  if (!size || size > VMO_MAX_SIZE || (pa | size) & 4095 || ckd_add(&end, pa, size)) return VX_ERR_RANGE;
  if (boot.ram_incomplete) return VX_ERR_ACCESS;
  for (uint32_t i = 0; i < boot.ram_count; i++)
    if (pa < boot.ram[i].end && boot.ram[i].base < end) return VX_ERR_ACCESS;
  uint64_t count = size / 4096;
  unsigned order = 0;
  while ((4096ull << order) < count * sizeof(uint64_t)) order++;
  vmo *v = pool_alloc(&vmo_pool);
  uint64_t list = v ? phys_alloc(order) : 0;
  if (!list) {
    if (v) pool_free(&vmo_pool, v);
    return VX_ERR_NO_MEMORY;
  }
  v->obj.type = OBJ_VMO;
  atomic_store_explicit(&v->obj.refs, 1, memory_order_relaxed);
  v->size = size;
  v->pages = phys_to_virt(list);
  v->list_order = order;
  v->physical = true;
  for (uint64_t i = 0; i < count; i++) v->pages[i] = pa + i * 4096;
  if (arch_console_device(false, pa, size)) console_hand_off();
  *out = v;
  return VX_OK;
}

// --- Irq ---

static vx_status irq_create(uint32_t line, irq **out) {
  if (line >= MAX_IRQ_LINES) return VX_ERR_RANGE;
  irq *q = pool_alloc(&irq_pool);
  if (!q) return VX_ERR_NO_MEMORY;
  q->obj.type = OBJ_IRQ;
  atomic_store_explicit(&q->obj.refs, 1, memory_order_relaxed);
  q->line = line;
  spin_lock(&irq_lines_lock);
  vx_status st = irq_lines[line] ? VX_ERR_EXISTS : arch_irq_route(line, &q->level);
  if (st == VX_OK) irq_lines[line] = q;
  spin_unlock(&irq_lines_lock);
  if (st != VX_OK) {
    pool_free(&irq_pool, q);
    return st;
  }
  *out = q;
  return VX_OK;
}

// An MSI for the PCI function `source`: the architecture picks a free line
// (it reads irq_lines, under irq_lines_lock) and says what to write where.
static vx_status irq_create_msi(uint32_t source, irq **out, vx_msi *msi) {
  irq *q = pool_alloc(&irq_pool);
  if (!q) return VX_ERR_NO_MEMORY;
  q->obj.type = OBJ_IRQ;
  atomic_store_explicit(&q->obj.refs, 1, memory_order_relaxed);
  spin_lock(&irq_lines_lock);
  vx_status st = arch_msi_create(source, &q->line, msi);
  if (st == VX_OK) irq_lines[q->line] = q;
  spin_unlock(&irq_lines_lock);
  if (st != VX_OK) {
    pool_free(&irq_pool, q);
    return st;
  }
  *out = q; // edge-triggered: never masked
  return VX_OK;
}

// The line fired: called by the architecture's interrupt handler.
static void irq_fire(uint32_t line) {
  spin_lock(&irq_lines_lock);
  irq *q = line < MAX_IRQ_LINES ? irq_lines[line] : nullptr;
  if (!q) {
    arch_irq_mask(line, true); // no one owns it: keep it quiet
    spin_unlock(&irq_lines_lock);
    return;
  }
  spin_lock(&q->lock);
  q->count++;
  if (q->level && !q->masked) {
    arch_irq_mask(line, true);
    q->masked = true;
  }
  if (q->obs.head)
    observers_fire(&q->obs, VX_TRIGGER_IRQ, q->count);
  else
    q->pending = true;
  spin_unlock(&q->lock);
  spin_unlock(&irq_lines_lock);
}

static vx_status irq_bind(irq *q, binding *b) {
  if (b->trigger != VX_TRIGGER_IRQ) return VX_ERR_INVALID;
  spin_lock(&q->lock);
  if (q->pending) {
    q->pending = false;
    binding_fire(b, q->count);
  } else {
    observers_add(&q->obs, b);
  }
  spin_unlock(&q->lock);
  return VX_OK;
}

static void irq_ack(irq *q) {
  spin_lock(&q->lock);
  if (q->masked) {
    q->masked = false;
    arch_irq_mask(q->line, false);
  }
  spin_unlock(&q->lock);
}

static void irq_destroy(irq *q) {
  spin_lock(&irq_lines_lock);
  arch_irq_mask(q->line, true);
  if (q->line >= MSI_LINE_BASE) arch_msi_destroy(q->line);
  irq_lines[q->line] = nullptr;
  spin_unlock(&irq_lines_lock);
  observers_free(q->obs.head);
  pool_free(&irq_pool, q);
}

// --- IoRange ---

static vx_status iorange_create(uint64_t base, uint64_t count, iorange **out) {
  uint64_t end;
  if (!arch_has_io_ports()) return VX_ERR_UNSUPPORTED;
  if (!count || ckd_add(&end, base, count) || end > 0x1'0000) return VX_ERR_RANGE;
  iorange *r = pool_alloc(&iorange_pool);
  if (!r) return VX_ERR_NO_MEMORY;
  r->obj.type = OBJ_IORANGE;
  atomic_store_explicit(&r->obj.refs, 1, memory_order_relaxed);
  r->base = (uint16_t)base;
  r->count = (uint32_t)count;
  if (arch_console_device(true, base, count)) console_hand_off();
  *out = r;
  return VX_OK;
}

// Lets task t use the range's ports. Its threads see them from their next
// switch onto a CPU; the calling thread, at once.
static vx_status task_enable_io(task *t, const iorange *r) {
  spin_lock(&t->lock);
  vx_status st = t->io_ranges < TASK_MAX_IO ? VX_OK : VX_ERR_NO_MEMORY;
  if (st == VX_OK) {
    t->io_base[t->io_ranges] = r->base;
    t->io_count[t->io_ranges] = r->count;
    t->io_ranges++;
  }
  spin_unlock(&t->lock);
  if (st == VX_OK && t == this_cpu()->current->task) arch_io_switch(t);
  return st;
}

// --- DmaDomain and DmaMapping ---
//
// What a device may reach by DMA (01 §6): a domain for one PCI function
// (its requester ID, `source`), which devmgr creates and keeps, giving the
// driver a duplicate that can only map. Each dma_map is a DmaMapping of its
// own: a range of a VMO, with whether the device may read it, write it or
// both, checked against the VMO handle's rights. There is no IOMMU behind it
// yet: a pass-through domain gives devices physical addresses, so it is only
// safe with devices QEMU emulates (04 §5).
//
// Letting go. dma_unmap says the device is done with a mapping: its pages
// are let go at once. A mapping whose last handle goes without that (its
// driver died) cannot be trusted done: in a pass-through domain nothing
// stops the device, so its pages are kept (held) until devmgr has reset the
// device and says so (dma_domain_op QUIESCED). REVOKE makes every mapping
// held at once, for a driver that will not be asked. (Fuchsia's BTIs leak
// such pages for good and make every driver release them; here the domain's
// owner does, once.) With an IOMMU, unmapping stops the device first.
//
// Faults (the IOMMU's, M5 steps 6c and 6d) are counted, and fire
// VX_TRIGGER_DMA_FAULT on the domain.

typedef struct dma_mapping {
  object obj;
  struct dma_domain *domain; // referenced, until the mapping is freed
  vmo *v;                    // held while the device may reach it; nullptr once let go
  uint64_t offset, size;
  uint32_t options; // VX_DMA_READ, VX_DMA_WRITE
  bool revoked;     // its handles of no more use (REVOKE): let go only at QUIESCED
  bool kept;        // its handles gone, its pages not let go: on the domain's kept list
  struct dma_mapping *next;
} dma_mapping;

typedef struct dma_domain {
  object obj;
  spinlock lock;
  uint32_t source;   // the requester ID it is for
  dma_mapping *live; // mappings with handles
  dma_mapping *kept; // without: freed at QUIESCED
  uint64_t faults;
  observers obs;
} dma_domain;

static pool dma_pool = POOL_FOR(dma_domain);
static pool dma_mapping_pool = POOL_FOR(dma_mapping);

static vx_status dma_domain_create(uint32_t source, dma_domain **out) {
  dma_domain *d = pool_alloc(&dma_pool);
  if (!d) return VX_ERR_NO_MEMORY;
  d->obj.type = OBJ_DMA_DOMAIN;
  d->source = source;
  atomic_store_explicit(&d->obj.refs, 1, memory_order_relaxed);
  *out = d;
  return VX_OK;
}

static void dma_unlink(dma_mapping **list, dma_mapping *m) {
  for (dma_mapping **at = list; *at; at = &(*at)->next)
    if (*at == m) {
      *at = m->next;
      return;
    }
}

// Maps [offset, offset + size) of v for the device, as options allow, and
// gives the address of each page.
static vx_status dma_map(dma_domain *d, vmo *v, uint64_t offset, uint64_t size, uint32_t options,
                         uint64_t *addresses, dma_mapping **out) {
  uint64_t end;
  if (!size || (offset | size) & 4095 || ckd_add(&end, offset, size) || end > v->size) return VX_ERR_RANGE;
  if (v->physical) return VX_ERR_UNSUPPORTED; // device memory: peer-to-peer comes later
  dma_mapping *m = pool_alloc(&dma_mapping_pool);
  if (!m) return VX_ERR_NO_MEMORY;
  m->obj.type = OBJ_DMA_MAPPING;
  atomic_store_explicit(&m->obj.refs, 1, memory_order_relaxed);
  object_ref(&d->obj), object_ref(&v->obj);
  m->domain = d, m->v = v, m->offset = offset, m->size = size, m->options = options;
  spin_lock(&d->lock);
  m->next = d->live, d->live = m;
  spin_unlock(&d->lock);
  for (uint64_t i = 0; i < size / 4096; i++) addresses[i] = v->pages[offset / 4096 + i];
  *out = m;
  return VX_OK;
}

// The device is done with it: its pages let go now. Not a revoked one's:
// the device may still be using it until QUIESCED.
static vx_status dma_unmap(dma_mapping *m) {
  dma_domain *d = m->domain;
  spin_lock(&d->lock);
  vmo *v = m->revoked ? nullptr : m->v;
  bool refused = m->revoked || !m->v;
  if (v) m->v = nullptr;
  spin_unlock(&d->lock);
  if (v) object_release(&v->obj);
  return refused ? VX_ERR_BAD_STATE : VX_OK;
}

static void dma_mapping_free(dma_mapping *m) {
  dma_domain *d = m->domain;
  vmo *v = m->v;
  pool_free(&dma_mapping_pool, m);
  if (v) object_drop(&v->obj);
  object_drop(&d->obj);
}

// Its last handle gone: freed if its pages were let go, else kept for QUIESCED.
static void dma_mapping_destroy(dma_mapping *m) {
  dma_domain *d = m->domain;
  spin_lock(&d->lock);
  dma_unlink(&d->live, m);
  bool keep = m->v != nullptr;
  if (keep) m->kept = true, m->next = d->kept, d->kept = m;
  spin_unlock(&d->lock);
  if (!keep) dma_mapping_free(m);
}

// REVOKE: every live mapping's pages kept until QUIESCED, whatever its
// driver does; QUIESCED: the device has been reset, so what was kept is let go.
static void dma_revoke(dma_domain *d) {
  spin_lock(&d->lock);
  for (dma_mapping *m = d->live; m; m = m->next) m->revoked = true;
  spin_unlock(&d->lock);
}

static void dma_quiesced(dma_domain *d) {
  for (;;) {
    spin_lock(&d->lock);
    dma_mapping *m = d->kept;
    if (m) d->kept = m->next;
    vmo *v = nullptr;
    for (dma_mapping *l = d->live; !m && !v && l; l = l->next) // revoked, its handles not yet gone
      if (l->revoked && l->v) v = l->v, l->v = nullptr;
    spin_unlock(&d->lock);
    if (v) {
      object_release(&v->obj);
      continue;
    }
    if (!m) return;
    dma_mapping_free(m);
  }
}

// A fault the IOMMU reported for this domain's device (M5 steps 6c, 6d).
[[maybe_unused]] static void dma_fault(dma_domain *d) {
  spin_lock(&d->lock);
  d->faults++;
  observers_fire(&d->obs, VX_TRIGGER_DMA_FAULT, d->faults);
  spin_unlock(&d->lock);
}

static vx_status dma_bind(dma_domain *d, binding *b) {
  if (b->trigger != VX_TRIGGER_DMA_FAULT) return VX_ERR_INVALID;
  spin_lock(&d->lock);
  if (d->faults > b->threshold) // faults since the count the binder saw: at once
    binding_fire(b, d->faults);
  else
    observers_add(&d->obs, b);
  spin_unlock(&d->lock);
  return VX_OK;
}

static void dma_domain_destroy(dma_domain *d) { // no mapping refers to it any more
  observers_free(d->obs.head);
  pool_free(&dma_pool, d);
}
