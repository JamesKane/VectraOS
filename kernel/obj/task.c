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
static constexpr uint32_t TASK_MAX_IO = 4;  // I/O port ranges per task

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

// A mapping in a task's address space: [va, va + size) shows the VMO from
// `offset`. It holds a reference on the VMO.
typedef struct mapping {
  uint64_t va, size, offset;
  struct vmo *vmo;
} mapping;

static constexpr uint32_t TASK_MAX_MAPPINGS = 4096 / sizeof(mapping);

struct thread;

// A task's lock covers its handle table, its address space, its threads and
// its life (state, exit status, bindings on its exit).
typedef struct task {
  object obj;
  spinlock lock;
  uint64_t id;
  uint64_t root;          // physical address of the address space's top table; 0 once torn down
  uint64_t map_next;      // the next address as_map places at
  handle_entry *handles;  // HANDLE_SLOTS entries
  mapping *maps;          // TASK_MAX_MAPPINGS entries; size 0 is a free slot
  uint64_t mapped;        // bytes
  struct thread *threads; // started and not yet reaped, through task_next
  uint32_t live_threads;
  vx_task_state state; // EXITED once torn down
  bool ending;         // its last thread has exited, or it was killed: torn down soon
  bool killed;
  int64_t exit_status;
  observers obs; // EXIT bindings
  // The root task's debug capability, until there is a debug-log object;
  // a task gets it from the task that creates it, so services can report
  // until the console is a user-space driver's (M2, step 5).
  bool may_debug_write;
  char name[24];
  uint32_t io_ranges; // I/O ports it may use (x86_64, device.c): [io_base, io_base + io_count)
  uint16_t io_base[TASK_MAX_IO], io_count[TASK_MAX_IO];
} task;

typedef enum thread_state : uint8_t {
  THREAD_NEW = 0, // created, never run
  THREAD_READY,
  THREAD_RUNNING,
  THREAD_BLOCKED,
  THREAD_DEAD,
} thread_state;

struct cpu;

// Everything below `state` belongs to the scheduler and is under its lock.
struct thread {
  object obj;
  task *task;               // nullptr for an idle thread
  struct thread *task_next; // in its task's list, under the task's lock
  uint64_t kernel_sp;       // saved by arch_context_switch
  uint64_t kstack;          // direct-map address of the kernel stack's base
  uint64_t user_entry, user_sp, user_arg, user_arg2;
  uint32_t intent;       // enum vx_intent
  bool last_of_task;     // its exit ended its task (reaped in sched.c)
  uint8_t console_len;   // bytes of a debug_write line not yet ended
  char console_buf[160]; // which go out whole, at its newline
  thread_state state;
  struct thread *next;       // in the ready queue, or in a list of waiters (under that list's lock)
  struct thread *sleep_next; // in its CPU's sleep queue, ordered by wake_at
  struct cpu *sleep_cpu;     // the CPU whose sleep queue holds it
  struct cpu *cpu;           // the CPU it runs or last ran on
  vx_instant wake_at;        // the deadline it sleeps until
  vx_instant wake_late;      // wake_at plus its leeway: the timer may wait until here
  const void *wait_token;    // what it waits on, until it is woken or times out (sched.c)
  bool wake_pending;         // woken between joining a list of waiters and blocking
  int64_t wait_result;
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

// A handle in flight: the reference the sender's handle held, and its rights.
typedef struct moved_handle {
  object *obj;
  uint32_t rights;
} moved_handle;

// Takes n handles out of the task's table, all or none: each must exist, carry
// TRANSFER, appear once, and not be `forbidden` (a channel end cannot travel
// through itself). Their references move into out.
static vx_status handles_take(task *t, const vx_handle *values, uint32_t n, const object *forbidden,
                              moved_handle *out) {
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  for (uint32_t i = 0; i < n && st == VX_OK; i++) {
    uint32_t index = values[i] & 0xffff;
    handle_entry *e = index && index < HANDLE_SLOTS ? &t->handles[index] : nullptr;
    if (!e || !e->obj || e->generation != values[i] >> 16)
      st = VX_ERR_BAD_HANDLE;
    else if (!(e->rights & VX_RIGHT_TRANSFER))
      st = VX_ERR_ACCESS;
    else if (e->obj == forbidden)
      st = VX_ERR_INVALID;
    for (uint32_t k = 0; k < i && st == VX_OK; k++)
      if (values[k] == values[i]) st = VX_ERR_INVALID;
  }
  for (uint32_t i = 0; i < n && st == VX_OK; i++) {
    handle_entry *e = &t->handles[values[i] & 0xffff];
    out[i] = (moved_handle){e->obj, e->rights};
    e->obj = nullptr;
    e->generation++;
    if (e->generation == 0) e->generation = 1;
  }
  spin_unlock(&t->lock);
  return st;
}

// Installs moved handles in the task's table, writing their values to out. On
// failure none is installed. Either way the moved references are the caller's
// to release.
static vx_status handles_put(task *t, const moved_handle *in, uint32_t n, vx_handle *out) {
  for (uint32_t i = 0; i < n; i++) {
    vx_status st = handle_add(t, in[i].obj, in[i].rights, &out[i]);
    if (st != VX_OK) {
      while (i--) handle_close(t, out[i]);
      return st;
    }
  }
  return VX_OK;
}

static pool task_pool = POOL_FOR(task);
static pool thread_pool = POOL_FOR(thread);
static _Atomic uint64_t next_task_id = 1;

static vx_status task_create(const char *name, task **out) {
  task *t = pool_alloc(&task_pool);
  if (!t) return VX_ERR_NO_MEMORY;
  uint64_t handles = phys_alloc_zeroed(0);
  uint64_t maps = handles ? phys_alloc_zeroed(0) : 0;
  uint64_t root = maps ? arch_new_user_root() : 0;
  if (!root) {
    if (maps) phys_free(maps, 0);
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
  t->maps = phys_to_virt(maps);
  for (size_t i = 0; name[i] && i < sizeof t->name - 1; i++) t->name[i] = name[i];
  *out = t;
  return VX_OK;
}

// Maps [offset, offset + size) of a VMO into a task's address space. With
// *va == 0 the kernel picks the address; otherwise *va is used and must be
// page-aligned and free. The mapping holds a reference on the VMO. W^X: never
// writable and executable.
static vx_status task_map(task *t, vmo *v, uint64_t offset, uint64_t size, uint32_t flags, uint64_t *va) {
  uint64_t vmo_end;
  if ((flags & VX_MAP_WRITE) && (flags & VX_MAP_EXEC)) return VX_ERR_ACCESS;
  if (!size || (offset | size) & 4095 || ckd_add(&vmo_end, offset, size) || vmo_end > v->size)
    return VX_ERR_RANGE;
  uint32_t mf = MAP_USER | (flags & VX_MAP_WRITE ? MAP_WRITE : 0) | (flags & VX_MAP_EXEC ? MAP_EXEC : 0) |
                (v->physical ? MAP_DEVICE : 0);
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  uint64_t at = *va ? *va : t->map_next;
  uint64_t end;
  mapping *slot = nullptr;
  for (uint32_t i = 0; i < TASK_MAX_MAPPINGS && !slot; i++)
    if (!t->maps[i].size) slot = &t->maps[i];
  if (!t->root || t->ending)
    st = VX_ERR_BAD_STATE;
  else if ((at & 4095) || ckd_add(&end, at, size) || end > USER_TOP)
    st = VX_ERR_RANGE;
  else if (!slot)
    st = VX_ERR_NO_MEMORY;
  uint64_t done = 0;
  for (; st == VX_OK && done < size; done += 4096)
    if (!map_range(t->root, at + done, v->pages[(offset + done) / 4096], 4096, mf)) st = VX_ERR_NO_MEMORY;
  if (st == VX_OK) {
    object_ref(&v->obj);
    *slot = (mapping){.va = at, .size = size, .offset = offset, .vmo = v};
    t->mapped += size;
    if (!*va) t->map_next = end + 4096; // leave a guard page between placed mappings
    *va = at;
  } else {
    for (uint64_t off = 0; off + 4096 <= done; off += 4096) unmap_page(t->root, at + off);
  }
  spin_unlock(&t->lock);
  return st;
}

// A thread of task t that has not started (thread_start, obj/process.c).
static vx_status thread_create(task *t, thread **out) {
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
  th->intent = VX_INTENT_INTERACTIVE;
  object_ref(&t->obj);
  th->kernel_sp = arch_thread_initial_sp(th);
  *out = th;
  return VX_OK;
}

static uint64_t thread_kstack_top(const thread *th) { return th->kstack + (4096ull << KSTACK_ORDER); }
