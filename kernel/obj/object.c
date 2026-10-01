// object.c: kernel objects, their pools, and handle tables (docs/01 §2, §3).
//
// Every object starts with an `object` header holding its type and reference
// count. Objects come from per-type pools carved out of whole pages; there is
// no general-purpose allocator in the kernel (04 §1.1). Charging pools to
// memory budgets comes with budgets themselves (M2).

typedef enum obj_type : uint8_t {
    OBJ_TASK = 1,
    OBJ_THREAD,
    OBJ_VMO,
    OBJ_PORT,
} obj_type;

typedef struct object {
    obj_type type;
    uint32_t refs;
} object;

typedef struct pool {
    size_t size;   // rounded up to 16 bytes
    void  *free;   // free list, through each free object's first word
} pool;

static void *pool_alloc(pool *p) {
    if (!p->free) {
        uint64_t pa = phys_alloc(0);
        if (!pa) return nullptr;
        uint8_t *page = phys_to_virt(pa);
        for (size_t off = 0; off + p->size <= 4096; off += p->size) {
            *(void **)(page + off) = p->free;
            p->free = page + off;
        }
    }
    void *o = p->free;
    p->free = *(void **)o;
    memset(o, 0, p->size);
    return o;
}

static void pool_free(pool *p, void *o) {
    *(void **)o = p->free;
    p->free = o;
}

#define POOL_FOR(type) { .size = (sizeof(type) + 15) & ~(size_t)15 }

// --- Handles ---
//
// A handle is a table index in the low 16 bits and that slot's generation in
// the high 16. The generation is bumped each time the slot is freed, so a
// stale handle fails with BAD_HANDLE instead of reaching a new object. Index 0
// is never used, so no valid handle is 0. Slots are taken lowest first, which
// makes handle values deterministic (01 §3). A table is one page for now:
// 255 handles per task.

typedef struct handle_entry {
    object  *obj;
    uint32_t rights;
    uint16_t generation;
    uint16_t reserved;
} handle_entry;

constexpr uint32_t HANDLE_SLOTS = 4096 / sizeof(handle_entry);

static vx_handle handle_value(uint32_t index, uint16_t generation) {
    return (vx_handle)generation << 16 | index;
}

// Takes a reference on obj for the new handle.
static vx_status handle_add(handle_entry *table, object *obj, uint32_t rights, vx_handle *out) {
    for (uint32_t i = 1; i < HANDLE_SLOTS; i++) {
        if (table[i].obj) continue;
        if (table[i].generation == 0) table[i].generation = 1;
        table[i].obj    = obj;
        table[i].rights = rights;
        obj->refs++;
        *out = handle_value(i, table[i].generation);
        return VX_OK;
    }
    return VX_ERR_NO_MEMORY;
}

// The object behind a handle, if it is of the given type and has every right asked for.
static object *handle_get(handle_entry *table, vx_handle h, obj_type type, uint32_t rights, vx_status *status) {
    uint32_t index = h & 0xffff;
    if (index == 0 || index >= HANDLE_SLOTS || !table[index].obj || table[index].generation != h >> 16) {
        *status = VX_ERR_BAD_HANDLE;
        return nullptr;
    }
    if (table[index].obj->type != type) {
        *status = VX_ERR_BAD_HANDLE;
        return nullptr;
    }
    if ((table[index].rights & rights) != rights) {
        *status = VX_ERR_ACCESS;
        return nullptr;
    }
    *status = VX_OK;
    return table[index].obj;
}

static void object_release(object *obj);

static vx_status handle_close(handle_entry *table, vx_handle h) {
    uint32_t index = h & 0xffff;
    if (index == 0 || index >= HANDLE_SLOTS || !table[index].obj || table[index].generation != h >> 16)
        return VX_ERR_BAD_HANDLE;
    object *obj = table[index].obj;
    table[index].obj = nullptr;
    table[index].generation++;
    if (table[index].generation == 0) table[index].generation = 1;
    object_release(obj);
    return VX_OK;
}
