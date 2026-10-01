// task.c: tasks, threads and address spaces (docs/01 §2).
//
// A task is an address space plus a handle table. Its user half is its own
// page tables; the kernel half is shared (arch_new_user_root). Tasks and
// threads are never destroyed in M1: nothing exits yet.

static constexpr uint64_t USER_TOP = 0x0000'8000'0000'0000;      // first address past the lower half
static constexpr uint64_t USER_MAP_BASE = 0x0000'1000'0000'0000; // where as_map puts mappings it places
static constexpr uint64_t USER_STACK_TOP = 0x0000'7fff'ffff'0000;
static constexpr uint64_t USER_STACK_SIZE = 64ull * 1024;
static constexpr unsigned KSTACK_ORDER = 2; // 16 KiB kernel stacks

// --- Handles ---
//
// A handle is a table index in the low 16 bits and that slot's generation in
// the high 16. The generation is bumped each time the slot is freed, so a stale
// handle fails with BAD_HANDLE instead of reaching a new object. Index 0 is
// never used, so no valid handle is 0. Slots are taken lowest first, which makes
// handle values deterministic (01 §3). A table is one page for now: 255 handles.

typedef struct handle_entry {
  object *obj;
  uint32_t rights;
  uint16_t generation;
  uint16_t reserved;
} handle_entry;

static constexpr uint32_t HANDLE_SLOTS = 4096 / sizeof(handle_entry);

// A task's lock covers its handle table and its address space.
typedef struct task {
  object obj;
  spinlock lock;
  uint64_t id;
  uint64_t root;         // physical address of the address space's top table
  uint64_t map_next;     // the next address as_map places at
  handle_entry *handles; // HANDLE_SLOTS entries
  bool may_debug_write;  // the root task's debug capability, until there is a debug-log object
  char name[24];
} task;

typedef enum thread_state : uint8_t {
  THREAD_NEW = 0, // created, never run
  THREAD_READY,
  THREAD_RUNNING,
  THREAD_BLOCKED,
  THREAD_DEAD,
} thread_state;

struct port;
struct cpu;

// Everything below `state` belongs to the scheduler and is under its lock.
struct thread {
  object obj;
  task *task;         // nullptr for an idle thread
  uint64_t kernel_sp; // saved by arch_context_switch
  uint64_t kstack;    // direct-map address of the kernel stack's base
  thread_state state;
  struct thread *next;       // in the ready queue, or in a port's waiters (under the port's lock)
  struct thread *sleep_next; // in its CPU's sleep queue, ordered by wake_at
  struct cpu *sleep_cpu;     // the CPU whose sleep queue holds it
  vx_instant wake_at;        // the deadline it sleeps until
  vx_instant wake_late;      // wake_at plus its leeway: the timer may wait until here
  struct port *port;         // the port it waits on, until it is woken or times out
  bool wake_pending;         // woken between joining a port's waiters and blocking
  int64_t wait_result;
  uint64_t user_entry, user_sp, user_arg;
};

static vx_handle handle_value(uint32_t index, uint16_t generation) {
  return (vx_handle)generation << 16 | index;
}

// Gives the task a handle to obj, taking a reference for it.
static vx_status handle_add(task *t, object *obj, uint32_t rights, vx_handle *out) {
  vx_status st = VX_ERR_NO_MEMORY;
  spin_lock(&t->lock);
  for (uint32_t i = 1; i < HANDLE_SLOTS; i++) {
    handle_entry *e = &t->handles[i];
    if (e->obj) continue;
    if (e->generation == 0) e->generation = 1;
    e->obj = obj;
    e->rights = rights;
    object_ref(obj);
    *out = handle_value(i, e->generation);
    st = VX_OK;
    break;
  }
  spin_unlock(&t->lock);
  return st;
}

// The object behind a handle, with a reference the caller releases, if it is of
// the given type and the handle has every right asked for.
static object *handle_get(task *t, vx_handle h, obj_type type, uint32_t rights, vx_status *status) {
  uint32_t index = h & 0xffff;
  object *obj = nullptr;
  spin_lock(&t->lock);
  handle_entry *e = index && index < HANDLE_SLOTS ? &t->handles[index] : nullptr;
  if (!e || !e->obj || e->generation != h >> 16 || e->obj->type != type) {
    *status = VX_ERR_BAD_HANDLE;
  } else if ((e->rights & rights) != rights) {
    *status = VX_ERR_ACCESS;
  } else {
    obj = e->obj;
    object_ref(obj);
    *status = VX_OK;
  }
  spin_unlock(&t->lock);
  return obj;
}

static vx_status handle_close(task *t, vx_handle h) {
  uint32_t index = h & 0xffff;
  object *obj = nullptr;
  spin_lock(&t->lock);
  handle_entry *e = index && index < HANDLE_SLOTS ? &t->handles[index] : nullptr;
  if (e && e->obj && e->generation == h >> 16) {
    obj = e->obj;
    e->obj = nullptr;
    e->generation++;
    if (e->generation == 0) e->generation = 1;
  }
  spin_unlock(&t->lock);
  if (!obj) return VX_ERR_BAD_HANDLE;
  object_release(obj);
  return VX_OK;
}

static pool task_pool = POOL_FOR(task);
static pool thread_pool = POOL_FOR(thread);
static _Atomic uint64_t next_task_id = 1;

static vx_status task_create(const char *name, task **out) {
  task *t = pool_alloc(&task_pool);
  if (!t) return VX_ERR_NO_MEMORY;
  uint64_t handles = phys_alloc_zeroed(0);
  uint64_t root = handles ? arch_new_user_root() : 0;
  if (!root) {
    if (handles) phys_free(handles, 0);
    pool_free(&task_pool, t);
    return VX_ERR_NO_MEMORY;
  }
  t->obj.type = OBJ_TASK; // pool_alloc zeroed the rest
  atomic_store_explicit(&t->obj.refs, 1, memory_order_relaxed);
  t->id = atomic_fetch_add_explicit(&next_task_id, 1, memory_order_relaxed);
  t->root = root;
  t->map_next = USER_MAP_BASE;
  t->handles = phys_to_virt(handles);
  for (size_t i = 0; name[i] && i < sizeof t->name - 1; i++) t->name[i] = name[i];
  *out = t;
  return VX_OK;
}

// Maps the whole of a VMO into a task's address space. With *va == 0 the kernel
// picks the address; otherwise *va is used and must be page-aligned and free.
// The mapping holds a reference on the VMO. W^X: never writable and executable.
static vx_status task_map(task *t, vmo *v, uint32_t flags, uint64_t *va) {
  if ((flags & VX_MAP_WRITE) && (flags & VX_MAP_EXEC)) return VX_ERR_ACCESS;
  uint32_t mf = MAP_USER | (flags & VX_MAP_WRITE ? MAP_WRITE : 0) | (flags & VX_MAP_EXEC ? MAP_EXEC : 0);
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  uint64_t at = *va ? *va : t->map_next;
  uint64_t end;
  if ((at & 4095) || ckd_add(&end, at, v->size) || end > USER_TOP) st = VX_ERR_RANGE;
  for (uint64_t off = 0; st == VX_OK && off < v->size; off += 4096)
    if (!map_range(t->root, at + off, v->pages[off / 4096], 4096, mf)) st = VX_ERR_NO_MEMORY;
  if (st == VX_OK) {
    object_ref(&v->obj);
    if (!*va) t->map_next = end + 4096; // leave a guard page between placed mappings
    *va = at;
  }
  spin_unlock(&t->lock);
  return st;
}

// A thread that will enter user mode at entry, with sp and one argument.
static vx_status thread_create(task *t, uint64_t entry, uint64_t sp, uint64_t arg, thread **out) {
  thread *th = pool_alloc(&thread_pool);
  if (!th) return VX_ERR_NO_MEMORY;
  uint64_t stack = phys_alloc_zeroed(KSTACK_ORDER);
  if (!stack) {
    pool_free(&thread_pool, th);
    return VX_ERR_NO_MEMORY;
  }
  th->obj.type = OBJ_THREAD; // pool_alloc zeroed the rest
  atomic_store_explicit(&th->obj.refs, 1, memory_order_relaxed);
  th->task = t;
  th->kstack = (uint64_t)phys_to_virt(stack);
  th->user_entry = entry;
  th->user_sp = sp;
  th->user_arg = arg;
  object_ref(&t->obj);
  th->kernel_sp = arch_thread_initial_sp(th);
  *out = th;
  return VX_OK;
}

static uint64_t thread_kstack_top(const thread *th) { return th->kstack + (4096ull << KSTACK_ORDER); }
