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
  uint16_t base, count;
} iorange;

static pool resource_pool = POOL_FOR(resource);
static pool irq_pool = POOL_FOR(irq);
static pool iorange_pool = POOL_FOR(iorange);

static constexpr uint32_t MAX_IRQ_LINES = 1024;
static irq *irq_lines[MAX_IRQ_LINES]; // under irq_lines_lock; at most one Irq per line
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
  r->count = (uint16_t)count;
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
