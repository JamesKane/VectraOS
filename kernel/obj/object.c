// object.c: kernel objects and their pools (docs/01 §2).
//
// Every object starts with an `object` header holding its type and an atomic
// reference count. Objects come from per-type pools carved out of whole pages;
// there is no general-purpose allocator in the kernel (04 §1.1). Charging pools
// to memory budgets comes with budgets themselves (M2).

typedef enum obj_type : uint8_t {
  OBJ_NONE = 0,
  OBJ_TASK,
  OBJ_THREAD,
  OBJ_VMO,
  OBJ_PORT,
  OBJ_CHANNEL,
  OBJ_COUNTER,
  OBJ_RING,
  OBJ_RESOURCE,
  OBJ_IRQ,
  OBJ_IORANGE,
  OBJ_DMA_DOMAIN,
  OBJ_DMA_MAPPING,
  OBJ_PAGER,
  OBJ_SCHED_CTX, // ADR-0038
} obj_type;

typedef struct object {
  obj_type type;
  _Atomic uint32_t refs;
  struct object *dying_next; // on its CPU's list of objects to destroy (object_release)
} object;

static void object_ref(object *obj) { atomic_fetch_add_explicit(&obj->refs, 1, memory_order_relaxed); }

// A reference to an object found through a list rather than a handle, unless
// its last reference is already gone (it is about to be destroyed).
static bool object_tryref(object *obj) {
  uint32_t refs = atomic_load_explicit(&obj->refs, memory_order_relaxed);
  while (refs)
    if (atomic_compare_exchange_weak_explicit(&obj->refs, &refs, refs + 1, memory_order_relaxed,
                                              memory_order_relaxed))
      return true;
  return false;
}

static void object_destroy(object *obj); // syscall/syscall.c, which knows every type

// Dropping references, without recursion.
//
// Destroying one object can release others: a channel end frees its queued
// messages and the handles in them, which may be channel ends with messages of
// their own, as deep as a program cares to nest them. So destruction never
// recurses (04 §1.1). object_drop takes a reference away and, if it was the
// last, queues the object on its CPU's dying list; object_drain destroys that
// list one object at a time, including whatever those destructions drop in
// turn. Destructors, and everything they call, only ever drop.
//
// object_release is drop then drain, for everywhere else. Drops made outside a
// destructor are drained by the next release on that CPU, and on every return
// to user mode. Destructors do not block, so a drain stays on one CPU.
static struct {
  object *head;
  bool draining;
} dying[MAX_CPUS];

static void object_drop(object *obj) {
  if (atomic_fetch_sub_explicit(&obj->refs, 1, memory_order_acq_rel) != 1) return;
  typeof(dying[0]) *d = &dying[arch_cpu_index()];
  obj->dying_next = d->head;
  d->head = obj;
}

static void object_drain(void) {
  typeof(dying[0]) *d = &dying[arch_cpu_index()];
  if (d->draining) return; // an outer drain on this CPU will get to it
  d->draining = true;
  while (d->head) {
    object *o = d->head;
    d->head = o->dying_next;
    object_destroy(o);
  }
  d->draining = false;
}

static void object_release(object *obj) {
  object_drop(obj);
  object_drain();
}

typedef struct pool {
  spinlock lock;
  size_t size; // rounded up to 16 bytes
  void *free;  // free list, through each free object's first word
} pool;

static void *pool_alloc(pool *p) {
  spin_lock(&p->lock);
  if (!p->free) {
    uint64_t pa = phys_alloc(0);
    if (!pa) {
      spin_unlock(&p->lock);
      return nullptr;
    }
    uint8_t *page = phys_to_virt(pa);
    for (size_t off = 0; off + p->size <= 4096; off += p->size) {
      *(void **)(page + off) = p->free;
      p->free = page + off;
    }
  }
  void *o = p->free;
  p->free = *(void **)o;
  spin_unlock(&p->lock);
  memset(o, 0, p->size);
  return o;
}

static void pool_free(pool *p, void *o) {
  spin_lock(&p->lock);
  *(void **)o = p->free;
  p->free = o;
  spin_unlock(&p->lock);
}

#define POOL_FOR(type) {.size = (sizeof(type) + 15) & ~(size_t)15}

// A source's port bindings that have not fired (obj/port.c), under the
// source's own lock.
struct binding;
typedef struct observers {
  struct binding *head;
} observers;
