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
} obj_type;

typedef struct object {
  obj_type type;
  _Atomic uint32_t refs;
} object;

static void object_ref(object *obj) { atomic_fetch_add_explicit(&obj->refs, 1, memory_order_relaxed); }

static void object_destroy(object *obj); // syscall/syscall.c, which knows every type

// Drops a reference; the last one destroys the object.
static void object_release(object *obj) {
  if (atomic_fetch_sub_explicit(&obj->refs, 1, memory_order_acq_rel) == 1) object_destroy(obj);
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
