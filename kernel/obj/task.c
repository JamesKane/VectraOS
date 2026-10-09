// task.c: tasks, threads and address spaces (docs/01 §2).
//
// A task is an address space plus a handle table. Its user half is its own
// page tables; the kernel half is shared (arch_new_user_root). Tasks and
// threads are never destroyed in M1: nothing exits yet.

static constexpr uint64_t USER_TOP = 0x0000'8000'0000'0000;      // first address past the lower half
static constexpr uint64_t USER_MAP_BASE = 0x0000'1000'0000'0000; // where as_map puts mappings it places
static constexpr uint64_t USER_STACK_TOP = 0x0000'7fff'ffff'0000;
static constexpr uint64_t USER_STACK_SIZE = 256ull * 1024; // debug builds are -O0: frames do not overlap
static constexpr uint32_t TASK_MAX_IO =
    32; // I/O port ranges per task (bus-acpi: one for each its AML touches)

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
  uint32_t flags;   // VX_MAP_WRITE, VX_MAP_EXEC, its key (VX_MAP_KEY)
  uint32_t allowed; // the rights its VMO handle gave (VX_MAP_WRITE, VX_MAP_EXEC): as_protect's limit
  bool privatized;  // its VMO is a copy of its own, made for a debugger's write (exception.c)
} mapping;

// The table is four pages (an order-2 block): a dynamic program maps each
// library's segments, and a Swift program loads a dozen libraries (6f3a).
static constexpr uint32_t TASK_MAP_ORDER = 2;
static constexpr uint32_t TASK_MAX_MAPPINGS = (4096u << TASK_MAP_ORDER) / sizeof(mapping);

// A reservation (as_reserve, ADR-0042): address space no placed mapping
// lands in, kept for the task's own as_map at addresses inside it.
typedef struct reservation {
  uint64_t va, size; // size 0: the slot is free
} reservation;
static constexpr uint32_t TASK_MAX_RESERVATIONS = 128; // one per shared library, with its guard pages

struct thread;
struct sched_ctx; // sched.c

// A task's lock covers its handle table, its address space, its threads and
// its life (state, exit status, bindings on its exit).
typedef struct task {
  object obj;
  spinlock lock;
  uint64_t id;
  uint64_t root;     // physical address of the address space's top table; 0 once torn down
  uint64_t map_next; // the next address as_map places at
  reservation resv[TASK_MAX_RESERVATIONS]; // under the lock; they go with the address space (task_exec)
  uint16_t keys;                           // its protection keys, bit k for key k (ADR-0035): as_key_alloc's
  handle_entry *handles;                   // HANDLE_SLOTS entries
  mapping *maps;                           // TASK_MAX_MAPPINGS entries; size 0 is a free slot
  uint64_t mapped;                         // bytes
  struct thread *threads;                  // started and not yet reaped, through task_next
  uint32_t live_threads;
  uint64_t gone_ticks[2]; // user and system ticks of its threads reaped (ADR-0041)
  vx_task_state state;    // EXITED once torn down
  bool ending;            // its last thread has exited, or it was killed: torn down soon
  bool killed;
  bool
      execing; // in or the scratch of a task_exec: no thread starts until its address spaces have changed places
  uint8_t exit_len; // its exit string (ADR-0010): empty while it runs, and for success
  char exit[VX_ERRMAX];
  observers obs; // EXIT bindings
  // The root task's debug capability, until there is a debug-log object;
  // a task gets it from the task that creates it, so services can report
  // until the console is a user-space driver's (M2, step 5).
  bool may_debug_write;
  char name[24];
  uint64_t parent_id;    // the task that created it, or its nearest live creator; 0 for the root task
  struct task *all_next; // in all_tasks
  uint32_t thread_ids;   // the last thread's id: ids count from 1, in creation order
  // Where its faults go (obj/exception.c): an in-task handler, then a port.
  uint64_t exc_handler;
  struct port *exc_port; // a reference, or null
  uint64_t exc_key;
  struct port *dbg_port; // a debugger's, which sees faults first (FIRST_CHANCE); a reference, or null
  vx_watchpoint watches[VX_WATCH_MAX]; // its watchpoints (thread_state SET_WATCH), loaded as its threads run
  bool watching;                       // any of them on
  uint64_t dbg_key;
  uint32_t io_ranges; // I/O ports it may use (x86_64, device.c): [io_base, io_base + io_count)
  uint16_t io_base[TASK_MAX_IO];
  uint32_t io_count[TASK_MAX_IO]; // up to 0x10000
  // Its threads' hardware counters (pmu.c, ADR-0050), under pmu_lock: gen
  // counts its configurations, so a thread sees a new one at its next start.
  struct {
    uint32_t gen, count, flags;
    uint32_t events[VX_PMU_MAX];
    uint64_t period[VX_PMU_MAX]; // a sampled counter's (0: counting only)
  } pmu;
  _Atomic uint64_t pmu_total[VX_PMU_MAX]; // its threads' counts, to their last switch
  // Its own samples (pmu.c, 7a3c1): a reference to the ring's VMO, or null;
  // its period; the lock its CPUs write under.
  struct vmo *samples;
  _Atomic uint64_t sample_ns;
  spinlock sample_lock;
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
static constexpr uint32_t THREAD_MAX_INTERRUPTS = 8;

struct thread {
  object obj;
  task *task;               // nullptr for an idle thread
  struct thread *task_next; // in its task's list, under the task's lock
  uint64_t kernel_sp;       // saved by arch_context_switch
  uint64_t kstack;          // the kernel stack's lowest address (mm/kstack.c)
  uint64_t tls;             // its user thread pointer while it is not running (arch_user_switch)
  uint8_t *fp;     // its FP/SIMD registers while it is not running (arch_user_switch): a page, ARCH_FP_MAX
  bool fp_in_area; // simd_begin saved them there and used the registers: fp is theirs until loaded
  uint64_t note_stack, note_stack_size; // where its in-task handler runs, if set (SET_NOTE_STACK, ADR-0036)
  uint64_t robust_head;                 // its robust list (thread_set_robust, ADR-0037); 0: none
  uint32_t robust_owner;                // the owner value its robust lock words hold
  bool user_held; // stopped at an exception: fp and tls are its own, saved, for a debugger (exception_stop)
  bool
      stepping; // a debugger asked for one instruction (arch_frame_step): aarch64's MDSCR_EL1.SS, x86_64's TF
  uint64_t user_entry, user_sp, user_arg, user_arg2;
  bool started;          // thread_start has taken it (under its task's lock)
  uint32_t intent;       // enum vx_intent: its own (sched_ctx_configure with no context)
  bool last_of_task;     // its exit ended its task (reaped in sched.c)
  bool exited;           // it has exited, and waits to be reaped: no note reaches it (under its task's lock)
  uint8_t console_len;   // bytes of a debug_write line not yet ended
  char console_buf[160]; // which go out whole, at its newline
  thread_state state;
  struct sched_ctx *ctx;     // the scheduling context it is bound to, holding a reference; or none (ADR-0038)
  int32_t core;              // the reserved CPU it is bound to within ctx's reservation, or -1
  struct thread *donor;      // the channel_call caller lending it its scheduling, or none (sched.c, 6d6c2)
  struct thread *donee;      // the thread this one, in channel_call, lends its scheduling to, or none
  bool lend_tail;            // its call answered: it keeps the loan only until it blocks, or its slice ends
  _Atomic uint64_t ticks[2]; // user and system ticks charged to it (sched_timer, ADR-0041)
  // Its hardware counters (pmu.c): which of its task's configurations, its
  // counts, what the counters were started at, and how many are running.
  uint32_t pmu_gen, pmu_loaded;
  uint64_t pmu_value[VX_PMU_MAX], pmu_start[VX_PMU_MAX];
  uint64_t pmu_period[VX_PMU_MAX], pmu_left[VX_PMU_MAX]; // a sampled counter's, and what is left of it
  struct thread *next;                                   // in the ready queue (under the scheduler's lock)
  struct thread *wait_next;  // in a port's waiters (under the port's lock); never the same link as next
  struct thread *sleep_next; // in its CPU's sleep queue, ordered by wake_at
  struct cpu *sleep_cpu;     // the CPU whose sleep queue holds it
  struct cpu *cpu;           // the CPU it runs or last ran on
  vx_instant wake_at;        // the deadline it sleeps until
  vx_instant wake_late;      // wake_at plus its leeway: the timer may wait until here
  const void *wait_token;    // what it waits on, until it is woken or times out (sched.c)
  bool wake_pending;         // woken between joining a list of waiters and blocking
  int64_t pending_result;    // and the result that block returns at once
  int64_t wait_result;
  // Exceptions and interrupts (obj/exception.c), under its task's lock.
  uint32_t id;            // in its task
  bool exc_stopped;       // stopped at its task's exception port, until exception_resume
  bool exc_first;         // and that port is a debugger's
  uint32_t suspend_count; // thread_suspend, less thread_resume
  bool parked;            // stopped on its way to user mode while suspended
  uint32_t exc_action;    // what exception_resume said: enum vx_resume_action, or 0
  // thread_interrupt's notes not yet delivered, oldest first: each is its
  // own exception (Plan 9 queued notes the same way).
  bool interrupt_pending; // interrupt_count > 0, read without the lock
  uint8_t interrupt_count;
  struct {
    uint8_t len;
    char text[VX_ERRMAX];
  } notes[THREAD_MAX_INTERRUPTS];
  vx_exception exc; // the exception it stopped at
};

static vx_handle handle_value(uint32_t index, uint16_t generation) {
  return (vx_handle)generation << 16 | index;
}

// Gives the task a handle to obj, taking a reference for it.
// BAD_STATE if the task has been torn down.
static vx_status handle_add(task *t, object *obj, uint32_t rights, vx_handle *out) {
  vx_status st = VX_ERR_NO_MEMORY;
  spin_lock(&t->lock);
  if (!t->handles) st = VX_ERR_BAD_STATE;
  for (uint32_t i = 1; t->handles && i < HANDLE_SLOTS; i++) {
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

// handle_get, and the rights the handle has, into *have.
static object *handle_get_rights(task *t, vx_handle h, obj_type type, uint32_t rights, uint32_t *have,
                                 vx_status *status);

// The object behind a handle, with a reference the caller releases, if it is of
// the given type and the handle has every right asked for.
static object *handle_get(task *t, vx_handle h, obj_type type, uint32_t rights, vx_status *status) {
  uint32_t have;
  return handle_get_rights(t, h, type, rights, &have, status);
}

static object *handle_get_rights(task *t, vx_handle h, obj_type type, uint32_t rights, uint32_t *have,
                                 vx_status *status) {
  uint32_t index = h & 0xffff;
  object *obj = nullptr;
  spin_lock(&t->lock);
  handle_entry *e = index && index < HANDLE_SLOTS && t->handles ? &t->handles[index] : nullptr;
  if (!e || !e->obj || e->generation != h >> 16 || e->obj->type != type) {
    *status = VX_ERR_BAD_HANDLE;
  } else if ((e->rights & rights) != rights) {
    *status = VX_ERR_ACCESS;
  } else {
    obj = e->obj;
    object_ref(obj);
    *have = e->rights;
    *status = VX_OK;
  }
  spin_unlock(&t->lock);
  return obj;
}

static vx_status handle_close(task *t, vx_handle h) {
  uint32_t index = h & 0xffff;
  object *obj = nullptr;
  spin_lock(&t->lock);
  handle_entry *e = index && index < HANDLE_SLOTS && t->handles ? &t->handles[index] : nullptr;
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
// TRANSFER, appear once, and be neither of the two `forbidden` objects: a
// channel's or ring's own ends cannot travel through it, since the end that
// receives would then hold a reference to itself (or its pair), and never be
// freed. Their references move into out.
static vx_status handles_take(task *t, const vx_handle *values, uint32_t n, const object *forbidden,
                              const object *forbidden2, moved_handle *out) {
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  for (uint32_t i = 0; i < n && st == VX_OK; i++) {
    uint32_t index = values[i] & 0xffff;
    handle_entry *e = index && index < HANDLE_SLOTS && t->handles ? &t->handles[index] : nullptr;
    if (!e || !e->obj || e->generation != values[i] >> 16)
      st = VX_ERR_BAD_HANDLE;
    else if (!(e->rights & VX_RIGHT_TRANSFER))
      st = VX_ERR_ACCESS;
    else if (e->obj == forbidden || (forbidden2 && e->obj == forbidden2))
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
static_assert(sizeof(task) <= 4096, "a pool object fits in a page");
static pool thread_pool = POOL_FOR(thread);
static_assert(alignof(thread) <= 16 && sizeof(thread) <= 4096); // pool objects: 16-aligned, within a page
static _Atomic uint64_t next_task_id = 1;

// Every live task, so a task's descendants can be found (task_find). When a
// task goes, its children pass to its parent, so the chain of creators from
// any task back to the root never breaks.
static task *all_tasks;
static spinlock all_tasks_lock;

static task *task_by_id(uint64_t id) { // under all_tasks_lock
  for (task *t = all_tasks; t; t = t->all_next)
    if (t->id == id) return t;
  return nullptr;
}

static bool task_in_tree(const task *t, uint64_t root) { // under all_tasks_lock
  for (uint32_t hops = 0; t && hops < 4096; hops++) {
    if (t->id == root) return true;
    t = t->parent_id ? task_by_id(t->parent_id) : nullptr;
  }
  return false;
}

// The task `id` (or, with next, the one with the next id after it) in the
// tree under `root`, with a reference; nullptr if there is none.
static task *task_find(uint64_t root, uint64_t id, bool next) {
  spin_lock(&all_tasks_lock);
  task *best = nullptr;
  for (task *t = all_tasks; t; t = t->all_next) {
    if ((next ? t->id <= id : t->id != id) || (best && t->id >= best->id)) continue;
    if (task_in_tree(t, root)) best = t;
  }
  // A task on its way to being destroyed is still listed, and still in memory
  // while the lock is held; it is simply not found.
  if (best && !object_tryref(&best->obj)) best = nullptr;
  spin_unlock(&all_tasks_lock);
  return best;
}

// The task is being destroyed: off the list, and its children to its parent.
static void task_unlist(task *t) {
  spin_lock(&all_tasks_lock);
  for (task **link = &all_tasks; *link; link = &(*link)->all_next) {
    if (*link != t) continue;
    *link = t->all_next;
    break;
  }
  for (task *c = all_tasks; c; c = c->all_next)
    if (c->parent_id == t->id) c->parent_id = t->parent_id;
  spin_unlock(&all_tasks_lock);
}

static vx_status task_create(const char *name, uint64_t parent_id, task **out) {
  task *t = pool_alloc(&task_pool);
  if (!t) return VX_ERR_NO_MEMORY;
  uint64_t handles = phys_alloc_zeroed(0);
  uint64_t maps = handles ? phys_alloc_zeroed(TASK_MAP_ORDER) : 0;
  uint64_t root = maps ? arch_new_user_root() : 0;
  if (!root) {
    if (maps) phys_free(maps, TASK_MAP_ORDER);
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
  size_t len = 0;
  while (name[len] && len < sizeof t->name) len++;
  memcpy(t->name, name, vx_utf_cut(name, len, sizeof t->name - 1)); // whole runes (ADR-0013)
  t->parent_id = parent_id;
  spin_lock(&all_tasks_lock);
  t->all_next = all_tasks;
  all_tasks = t;
  spin_unlock(&all_tasks_lock);
  *out = t;
  return VX_OK;
}

// Maps [offset, offset + size) of a VMO into a task's address space. With
// *va == 0 the kernel picks the address; otherwise *va is used and must be
// page-aligned and free. The mapping holds a reference on the VMO. W^X: never
// writable and executable.
// The first of t's mappings that ends after addr (as_query).
static vx_status task_query(task *t, uint64_t addr, vx_map_info *out) {
  const mapping *best = nullptr;
  spin_lock(&t->lock);
  if (!t->maps) { // an ended task's table is gone (task_teardown): nothing to find, as task_map refuses
    spin_unlock(&t->lock);
    return VX_ERR_BAD_STATE;
  }
  for (uint32_t i = 0; i < TASK_MAX_MAPPINGS; i++) {
    const mapping *m = &t->maps[i];
    if (m->size && m->va + m->size > addr && (!best || m->va < best->va)) best = m;
  }
  if (best)
    *out = (vx_map_info){.base = best->va, .size = best->size, .offset = best->offset, .flags = best->flags};
  spin_unlock(&t->lock);
  return best ? VX_OK : VX_ERR_NOT_FOUND;
}

// How a page of a mapping is mapped: writable only if the mapping is and,
// for a pager's page, only once it is dirty (pager.c).
// How a VMO's pages are mapped as to caching: RAM normally, a physical
// VMO's device memory uncached or, by its policy, write-combining (ADR-0051).
static uint32_t vmo_cache_flags(const vmo *v) {
  if (!v->physical) return 0;
  return v->cache == VX_CACHE_WC ? MAP_WC : MAP_DEVICE;
}

static uint32_t page_flags(const mapping *m, uint64_t entry) {
  bool write = (m->flags & VX_MAP_WRITE) && (!m->vmo->pager || (entry & PAGE_DIRTY));
  return MAP_USER | (write ? MAP_WRITE : 0) | (m->flags & VX_MAP_EXEC ? MAP_EXEC : 0) |
         (m->flags & VX_MAP_KEY_MASK) | vmo_cache_flags(m->vmo);
}

// A key the task may put on a mapping: 0, or one it allocated.
static bool key_ok(const task *t, uint32_t flags) {
  uint32_t k = (flags & VX_MAP_KEY_MASK) >> 8;
  return k == 0 || (t->keys & 1u << k);
}

// The start of the first mapping or reservation that [va, end) overlaps, or
// 0 if none does. Under the task's lock.
static uint64_t task_in_way(const task *t, uint64_t va, uint64_t end) {
  uint64_t first = 0;
  for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS; i++) {
    const mapping *m = &t->maps[i];
    if (m->size && m->va < end && va < m->va + m->size && (!first || m->va < first)) first = m->va;
  }
  for (uint32_t i = 0; i < TASK_MAX_RESERVATIONS; i++) {
    const reservation *r = &t->resv[i];
    if (r->size && r->va < end && va < r->va + r->size && (!first || r->va < first)) first = r->va;
  }
  return first;
}

// Whether any mapping overlaps [va, end). Under the task's lock.
static bool task_maps_in(const task *t, uint64_t va, uint64_t end) {
  for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS; i++)
    if (t->maps[i].size && t->maps[i].va < end && va < t->maps[i].va + t->maps[i].size) return true;
  return false;
}

// Whether [va, end) lies wholly inside one reservation or outside every one.
static bool task_resv_fits(const task *t, uint64_t va, uint64_t end) {
  for (uint32_t i = 0; i < TASK_MAX_RESERVATIONS; i++) {
    const reservation *r = &t->resv[i];
    bool overlaps = r->size && r->va < end && va < r->va + r->size;
    if (overlaps) return va >= r->va && end <= r->va + r->size;
  }
  return true;
}

// Where as_map places a mapping of size bytes: from map_next on, past any
// reservation or mapping in the way (a mapping placed at an address, as
// mremap's growth in place, may lie there), a guard page after it.
static uint64_t task_place(const task *t, uint64_t size) {
  uint64_t at = t->map_next;
  for (uint32_t pass = 0; pass <= TASK_MAX_RESERVATIONS + TASK_MAX_MAPPINGS; pass++) {
    bool moved = false;
    for (uint32_t i = 0; i < TASK_MAX_RESERVATIONS; i++) {
      const reservation *r = &t->resv[i];
      if (r->size && r->va < at + size && at < r->va + r->size) at = r->va + r->size + 4096, moved = true;
    }
    for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS; i++) {
      const mapping *m = &t->maps[i];
      if (m->size && m->va < at + size && at < m->va + m->size) at = m->va + m->size + 4096, moved = true;
    }
    if (!moved) break;
  }
  return at;
}

// allowed: the rights the VMO's handle gave (VX_MAP_WRITE, VX_MAP_EXEC), which
// as_protect may later give the mapping and no more. NOACCESS maps no page: a
// touch faults (ADR-0042).
static vx_status task_map(task *t, vmo *v, uint64_t offset, uint64_t size, uint32_t flags, uint32_t allowed,
                          uint64_t *va) {
  uint64_t vmo_end;
  if ((flags & VX_MAP_WRITE) && (flags & VX_MAP_EXEC)) return VX_ERR_ACCESS;
  if (!size || (offset | size) & 4095 || ckd_add(&vmo_end, offset, size) || vmo_end > v->size)
    return VX_ERR_RANGE;
  uint32_t mf = MAP_USER | (flags & VX_MAP_WRITE ? MAP_WRITE : 0) | (flags & VX_MAP_EXEC ? MAP_EXEC : 0) |
                vmo_cache_flags(v) | (flags & VX_MAP_KEY_MASK);
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  uint64_t at = *va ? *va : task_place(t, size);
  uint64_t end;
  mapping *slot = nullptr;
  for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS && !slot; i++) // no tables once torn down
    if (!t->maps[i].size) slot = &t->maps[i];
  if (!t->root || !t->maps || t->ending)
    st = VX_ERR_BAD_STATE;
  else if (!key_ok(t, flags))
    st = VX_ERR_INVALID; // a key it has not allocated
  else if ((at & 4095) || ckd_add(&end, at, size) || end > USER_TOP || !task_resv_fits(t, at, end))
    st = VX_ERR_RANGE;
  else if (task_maps_in(t, at, end))
    st = VX_ERR_EXISTS; // checked against the mappings, not the page tables: a no-access one has no pages
  else if (vmo_revoked(v) && !(flags & VX_MAP_NOACCESS))
    st = VX_ERR_REVOKED; // checked under the lock: a revoke after it finds this mapping (ADR-0043)
  else if ((flags & VX_MAP_WRITE) && vmo_sealed(v))
    st = VX_ERR_ACCESS; // under the lock too: vmo_seal looks for writable mappings after it seals
  else if (!slot)
    st = VX_ERR_NO_MEMORY;
  // Page by page; a page that is already mapped (by another mapping) fails
  // it, and only the pages this call mapped are taken back out. A pager's
  // pages are mapped as far as it has supplied them, the rest as they are
  // touched (pager.c).
  uint64_t done = 0;
  bool locked = vmo_locked(v);
  if (locked) spin_lock(&v->lock);
  if (locked && st == VX_OK && vmo_end > v->size) st = VX_ERR_RANGE; // shrunk since the check above
  mapping shape = {.vmo = v, .flags = flags};
  bool none = flags & VX_MAP_NOACCESS;
  while (st == VX_OK && done < size) {
    uint64_t pa = none ? 0 : vmo_page(v, (offset + done) / 4096);
    uint32_t pf = v->pager ? page_flags(&shape, v->pages[(offset + done) / 4096]) : mf;
    if (pa && !map_range(t->root, at + done, pa, 4096, pf))
      st = VX_ERR_NO_MEMORY;
    else
      done += 4096;
  }
  if (locked) spin_unlock(&v->lock);
  if (st == VX_OK) {
    object_ref(&v->obj);
    v->ever_mapped = true; // its cache policy fixed from here (ADR-0051)
    *slot = (mapping){.va = at, .size = size, .offset = offset, .vmo = v, .flags = flags, .allowed = allowed};
    t->mapped += size;
    if (!*va) t->map_next = end + 4096; // leave a guard page between placed mappings, past any reservation
    *va = at;
  } else {
    for (uint64_t off = 0; off < done; off += 4096) unmap_page(t->root, at + off);
  }
  uint64_t root = t->root;
  spin_unlock(&t->lock);
  if (st != VX_OK && done) arch_tlb_shootdown(root, at, done); // another thread may have touched them
  return st;
}

// task_create's FORK (01 §9): the new task gets a copy of the parent's memory
// and its handle table, and nothing else; the caller starts a thread in it.
//   - Each mapping is a copy, made now, of what the parent sees there, at the
//     same address with the same permissions. A ring's memory is not copied
//     (a copied ring is broken, a shared one would have two producers), nor
//     is device memory: the child finds those addresses unmapped, and its
//     library connects again.
//   - Each handle keeps its value and rights, so what the parent's memory
//     says about its handles (its file descriptors) holds in the child. A
//     handle to the parent itself becomes one to the child.
//   - A pager's VMO is shared, not copied: the child maps the same one, as
//     a file mapped MAP_SHARED is in both.
//   - The in-task fault handler is the parent's (signal handlers are
//     inherited); exception ports, a debugger and I/O ports are not.
static vx_status task_fork_copy(task *parent, task *child) {
  vx_status st = VX_OK;
  spin_lock(&parent->lock);
  if (!parent->root || parent->ending) st = VX_ERR_BAD_STATE;
  child->keys = parent->keys;                            // first: the mappings below carry their keys
  memcpy(child->resv, parent->resv, sizeof child->resv); // and its reservations, which they may lie in
  for (uint32_t i = 0; st == VX_OK && i < TASK_MAX_MAPPINGS; i++) {
    const mapping *m = &parent->maps[i];
    if (!m->size || m->vmo->physical || m->vmo->ring) continue;
    if (m->vmo->pager || (m->flags & VX_MAP_SHARED) || m->vmo->lease_of) { // the same VMO: a file's pages,
                                                                           // MAP_SHARED memory, a lease
                                                                           // (a revoke reaches the child)
      uint64_t va = m->va;
      uint32_t flags =
          vmo_revoked(m->vmo) ? VX_MAP_NOACCESS : m->flags; // a revoked lease's: its place, no pages
      st = task_map(child, m->vmo, m->offset, m->size, flags, m->allowed, &va);
      continue;
    }
    vmo *copy;
    vmo *v = m->vmo;
    st = vmo_create_like(v, m->size, &copy); // lazy if v is: only its pages copied (ADR-0046)
    if (st != VX_OK) break;
    bool locked = vmo_locked(v);
    if (locked) spin_lock(&v->lock); // an absent page (past a shrink's end, a lazy one's) stays zero
    for (uint64_t off = 0; off < m->size && st == VX_OK; off += 4096) {
      uint64_t pa = (m->offset + off) / 4096 < v->size / 4096 ? vmo_page(v, (m->offset + off) / 4096) : 0;
      uint64_t to = pa ? vmo_page_make(copy, off / 4096) : 0;
      if (pa && !to) st = VX_ERR_NO_MEMORY;
      if (to) arch_page_copy(phys_to_virt(to), phys_to_virt(pa), 4096);
    }
    if (locked) spin_unlock(&v->lock);
    if (st != VX_OK) {
      object_release(&copy->obj);
      break;
    }
    uint64_t va = m->va;
    st = task_map(child, copy, 0, m->size, m->flags, m->allowed, &va);
    object_release(&copy->obj); // the child's mapping holds it, if it was made
  }
  for (uint32_t i = 0; st == VX_OK && i < HANDLE_SLOTS; i++) {
    handle_entry e = parent->handles[i];
    if (e.obj == &parent->obj) e.obj = &child->obj;
    if (e.obj) object_ref(e.obj);
    child->handles[i] = e; // free slots too: their generations go on from the parent's
  }
  child->map_next = parent->map_next;
  child->exc_handler = parent->exc_handler;
  spin_unlock(&parent->lock);
  return st;
}

// Unmaps [va, va + size): whole mappings, or the parts of them in the range; a
// mapping cut in the middle becomes two, so that needs a free slot. The page
// entries are cleared under the lock, the translations shot down after it
// (another CPU spinning on it could not answer), and only then are the VMOs
// let go, which may free their pages.
static vx_status task_unmap(task *t, uint64_t va, uint64_t size) {
  uint64_t end;
  if (!size || (va | size) & 4095 || ckd_add(&end, va, size) || end > USER_TOP) return VX_ERR_RANGE;
  vmo *drop[TASK_MAX_MAPPINGS];
  uint32_t dropped = 0;
  spin_lock(&t->lock);
  if (!t->root || !t->maps || t->ending) {
    spin_unlock(&t->lock);
    return VX_ERR_BAD_STATE;
  }
  uint32_t splits = 0, free_slots = 0;
  for (uint32_t i = 0; i < TASK_MAX_MAPPINGS; i++) {
    mapping *m = &t->maps[i];
    free_slots += !m->size;
    splits += m->size && m->va < va && m->va + m->size > end;
  }
  if (splits > free_slots) {
    spin_unlock(&t->lock);
    return VX_ERR_NO_MEMORY;
  }
  for (uint32_t i = 0; i < TASK_MAX_MAPPINGS; i++) {
    mapping *m = &t->maps[i];
    uint64_t m_end = m->va + m->size;
    if (!m->size || m_end <= va || m->va >= end) continue;
    uint64_t lo = m->va > va ? m->va : va, hi = m_end < end ? m_end : end;
    for (uint64_t p = lo; p < hi; p += 4096) unmap_page(t->root, p);
    t->mapped -= hi - lo;
    if (lo == m->va && hi == m_end) { // all of it
      drop[dropped++] = m->vmo;
      *m = (mapping){};
    } else if (lo == m->va) { // its start
      m->offset += hi - m->va;
      m->size = m_end - hi;
      m->va = hi;
    } else if (hi == m_end) { // its end
      m->size = lo - m->va;
    } else { // its middle: the end becomes a mapping of its own
      mapping *rest = nullptr;
      for (uint32_t k = 0; k < TASK_MAX_MAPPINGS && !rest; k++)
        if (!t->maps[k].size) rest = &t->maps[k];
      object_ref(&m->vmo->obj);
      *rest = (mapping){.va = hi,
                        .size = m_end - hi,
                        .offset = m->offset + (hi - m->va),
                        .vmo = m->vmo,
                        .flags = m->flags,
                        .allowed = m->allowed,
                        .privatized = m->privatized};
      m->size = lo - m->va;
    }
  }
  uint64_t root = t->root;
  spin_unlock(&t->lock);
  arch_tlb_shootdown(root, va, size);
  for (uint32_t i = 0; i < dropped; i++) object_release(&drop[i]->obj);
  return VX_OK;
}

// Changes the rights and key of [va, va + size), every page of which must be
// mapped (NOT_FOUND otherwise), within the rights each mapping's handle gave
// (ACCESS past them) and W^X; a mapping the range cuts becomes two or three,
// so that needs free slots. The pages' entries are made again with the new
// flags (a pager's as far as it has supplied them), then shot down.
static vx_status task_protect(task *t, uint64_t va, uint64_t size, uint32_t flags) {
  uint64_t end;
  if (!size || (va | size) & 4095 || ckd_add(&end, va, size) || end > USER_TOP) return VX_ERR_RANGE;
  if ((flags & VX_MAP_WRITE) && (flags & VX_MAP_EXEC)) return VX_ERR_ACCESS;
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  uint64_t covered = 0;
  uint32_t cuts = 0, free_slots = 0;
  if (!t->root || !t->maps || t->ending) st = VX_ERR_BAD_STATE;
  if (st == VX_OK && !key_ok(t, flags)) st = VX_ERR_INVALID;
  for (uint32_t i = 0; st == VX_OK && i < TASK_MAX_MAPPINGS; i++) {
    const mapping *m = &t->maps[i];
    free_slots += !m->size;
    uint64_t m_end = m->va + m->size;
    if (!m->size || m_end <= va || m->va >= end) continue;
    if (flags & (VX_MAP_WRITE | VX_MAP_EXEC) & ~m->allowed) st = VX_ERR_ACCESS;
    if ((flags & VX_MAP_WRITE) && vmo_sealed(m->vmo)) st = VX_ERR_ACCESS; // ADR-0043
    covered += (m_end < end ? m_end : end) - (m->va > va ? m->va : va);
    cuts += (m->va < va) + (m_end > end);
  }
  if (st == VX_OK && covered != size) st = VX_ERR_NOT_FOUND; // a hole
  if (st == VX_OK && cuts > free_slots) st = VX_ERR_NO_MEMORY;
  for (uint32_t i = 0; st == VX_OK && i < TASK_MAX_MAPPINGS; i++) {
    mapping *m = &t->maps[i];
    if (!m->size || m->va + m->size <= va || m->va >= end) continue;
    for (int side = 0; side < 2; side++) { // what lies before the range, then after it, to slots of their own
      uint64_t m_end = m->va + m->size;
      uint64_t cut = side ? end : va;
      if (side ? m_end <= cut : m->va >= cut) continue;
      mapping *rest = nullptr;
      for (uint32_t k = 0; k < TASK_MAX_MAPPINGS && !rest; k++)
        if (!t->maps[k].size) rest = &t->maps[k];
      object_ref(&m->vmo->obj);
      *rest = *m;
      if (side) { // the rest is [end, m_end)
        rest->offset += cut - m->va, rest->size = m_end - cut, rest->va = cut;
        m->size = cut - m->va;
      } else { // the rest is [m->va, va)
        rest->size = cut - m->va;
        m->offset += cut - m->va, m->size = m_end - cut, m->va = cut;
      }
    }
    uint32_t changed = VX_MAP_WRITE | VX_MAP_EXEC | VX_MAP_KEY_MASK | VX_MAP_NOACCESS; // SHARED stays
    m->flags = (m->flags & ~changed) | (flags & changed);
    vmo *v = m->vmo;
    bool locked = vmo_locked(v);
    if (locked) spin_lock(&v->lock);
    for (uint64_t off = 0; off < m->size && st == VX_OK; off += 4096) {
      uint64_t idx = (m->offset + off) / 4096;
      bool none = (flags & VX_MAP_NOACCESS) || idx >= v->size / 4096 || vmo_revoked(v);
      uint64_t pa = none ? 0 : vmo_page(v, idx);
      unmap_page(t->root, m->va + off);
      if (pa && !map_range(t->root, m->va + off, pa, 4096, page_flags(m, v->pages[idx])))
        st = VX_ERR_NO_MEMORY;
    }
    if (locked) spin_unlock(&v->lock);
  }
  uint64_t root = t->root;
  spin_unlock(&t->lock);
  if (root) arch_tlb_shootdown(root, va, size);
  return st;
}

// as_reserve (ADR-0042): a reservation of size bytes aligned to align, at a
// random base or (VX_AS_FIXED) at *va; or (VX_AS_RELEASE) the one at *va
// given back, after what is mapped in it is unmapped.
static vx_drbg resv_random; // the kernel's, seeded from the bootloader's entropy
static spinlock resv_random_lock;

static uint64_t resv_random_u64(void) {
  uint64_t x;
  spin_lock(&resv_random_lock);
  if (!resv_random.seeded) {
    static const char tag[] = "as_reserve";
    vx_drbg_mix(&resv_random, boot.seed, sizeof boot.seed, true);
    vx_drbg_mix(&resv_random, tag, sizeof tag, false);
    uint64_t now = clock_now(); // without the bootloader's entropy, at least not the same each boot
    vx_drbg_mix(&resv_random, &now, sizeof now, false);
  }
  vx_drbg_read(&resv_random, &x, sizeof x);
  spin_unlock(&resv_random_lock);
  return x;
}

// The reservation of [va, va + size) exactly, or none. Under the task's lock.
static reservation *task_resv_at(task *t, uint64_t va, uint64_t size) {
  for (uint32_t i = 0; i < TASK_MAX_RESERVATIONS; i++)
    if (t->resv[i].size && t->resv[i].va == va && t->resv[i].size == size) return &t->resv[i];
  return nullptr;
}

// Unmaps what is in it first, while it is still reserved, so nothing as_map
// places can land there in between and be unmapped with it; then lets it go.
static vx_status task_release(task *t, uint64_t va, uint64_t size) {
  spin_lock(&t->lock);
  bool there = task_resv_at(t, va, size);
  spin_unlock(&t->lock);
  if (!there) return VX_ERR_NOT_FOUND;
  vx_status st = task_unmap(t, va, size);
  spin_lock(&t->lock);
  reservation *r = task_resv_at(t, va, size);
  if (r) *r = (reservation){};
  spin_unlock(&t->lock);
  if (!r) return VX_ERR_NOT_FOUND;            // another thread's release took it
  return st == VX_ERR_BAD_STATE ? VX_OK : st; // a task torn down has none left to unmap
}

static vx_status task_reserve(task *t, uint64_t size, uint64_t align, uint32_t flags, uint64_t *va) {
  if (flags & VX_AS_RELEASE) return task_release(t, *va, size);
  if (!align) align = 4096;
  if (!size || size & 4095 || size > USER_TOP - USER_MAP_BASE || align & (align - 1) || align < 4096 ||
      align > 1ull << 39)
    return VX_ERR_RANGE;
  uint64_t fixed = *va, end;
  if ((flags & VX_AS_FIXED) &&
      ((fixed & (align - 1)) || !fixed || ckd_add(&end, fixed, size) || end > USER_TOP))
    return VX_ERR_RANGE;
  uint64_t r[16]; // the random bases to try, drawn before the lock
  uint64_t slots = (USER_TOP - USER_MAP_BASE - size) / align + 1;
  for (int i = 0; i < 16; i++) r[i] = USER_MAP_BASE + resv_random_u64() % slots * align;
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  reservation *slot = nullptr;
  for (uint32_t i = 0; i < TASK_MAX_RESERVATIONS && !slot; i++)
    if (!t->resv[i].size) slot = &t->resv[i];
  uint64_t at = 0;
  if (!t->root || !t->maps || t->ending) {
    st = VX_ERR_BAD_STATE;
  } else if (!slot) {
    st = VX_ERR_NO_SPACE;
  } else if (flags & VX_AS_FIXED) {
    uint64_t in_way = task_in_way(t, fixed, fixed + size);
    if (in_way) *va = in_way, st = VX_ERR_EXISTS;
    at = fixed;
  } else {
    for (int i = 0; i < 16 && !at; i++)
      if (!task_in_way(t, r[i], r[i] + size) && !(r[i] <= t->map_next && t->map_next < r[i] + size))
        at = r[i];
    if (!at) st = VX_ERR_NO_MEMORY; // a crowded address space: sixteen draws all hit something
  }
  if (st == VX_OK) *slot = (reservation){.va = at, .size = size}, *va = at;
  spin_unlock(&t->lock);
  return st;
}

// Whether addr lies in a mapping of a revoked lease: its page fault is
// REVOKED (ADR-0043).
static bool task_revoked_at(task *t, uint64_t addr) {
  bool revoked = false;
  spin_lock(&t->lock);
  for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS; i++) {
    const mapping *m = &t->maps[i];
    if (m->size && addr >= m->va && addr - m->va < m->size) revoked = vmo_revoked(m->vmo);
  }
  spin_unlock(&t->lock);
  return revoked;
}

// The protection key of the mapping holding addr (0 if none): a PROTECTION_KEY
// exception's.
static uint32_t task_key_at(task *t, uint64_t addr) {
  uint32_t key = 0;
  spin_lock(&t->lock);
  for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS; i++) {
    const mapping *m = &t->maps[i];
    if (m->size && addr >= m->va && addr - m->va < m->size) key = (m->flags & VX_MAP_KEY_MASK) >> 8;
  }
  spin_unlock(&t->lock);
  return key;
}

// as_key_alloc and as_key_free (ADR-0035): the task's keys, 1 to arch_keys().
static vx_status task_key_alloc(task *t, uint32_t *key) {
  uint32_t n = arch_keys();
  if (!n) return VX_ERR_UNSUPPORTED;
  spin_lock(&t->lock);
  uint32_t k = 1;
  while (k <= n && (t->keys & 1u << k)) k++;
  if (k <= n) t->keys |= (uint16_t)(1u << k);
  spin_unlock(&t->lock);
  if (k > n) return VX_ERR_NO_SPACE;
  *key = k;
  return VX_OK;
}

static vx_status task_key_free(task *t, uint32_t key) {
  uint32_t n = arch_keys();
  if (!n) return VX_ERR_UNSUPPORTED;
  if (key == 0 || key > n) return VX_ERR_INVALID;
  vx_status st = VX_OK;
  spin_lock(&t->lock);
  if (!(t->keys & 1u << key)) st = VX_ERR_INVALID; // not its
  for (uint32_t i = 0; st == VX_OK && t->maps && i < TASK_MAX_MAPPINGS; i++)
    if (t->maps[i].size && (t->maps[i].flags & VX_MAP_KEY_MASK) >> 8 == key) st = VX_ERR_BAD_STATE; // in use
  if (st == VX_OK) t->keys &= (uint16_t)~(1u << key);
  spin_unlock(&t->lock);
  return st;
}

// A thread of task t that has not started (thread_start, obj/process.c).
static vx_status thread_create(task *t, thread **out) {
  thread *th = pool_alloc(&thread_pool);
  if (!th) return VX_ERR_NO_MEMORY;
  uint64_t stack = kstack_alloc(), fp = phys_alloc(0); // the FP area page-aligned, as XSAVE wants 64
  if (!stack || !fp) {
    if (stack) kstack_free(stack);
    if (fp) phys_free(fp, 0);
    pool_free(&thread_pool, th);
    return VX_ERR_NO_MEMORY;
  }
  th->obj.type = OBJ_THREAD; // pool_alloc zeroed the rest
  atomic_store_explicit(&th->obj.refs, 1, memory_order_relaxed);
  th->task = t;
  spin_lock(&t->lock);
  th->id = ++t->thread_ids;
  spin_unlock(&t->lock);
  th->kstack = stack;
  th->intent = VX_INTENT_INTERACTIVE;
  th->core = -1;
  object_ref(&t->obj);
  th->kernel_sp = arch_thread_initial_sp(th);
  th->fp = phys_to_virt(fp);
  arch_fp_init(th->fp);
  *out = th;
  return VX_OK;
}

static uint64_t thread_kstack_top(const thread *th) { return th->kstack + KSTACK_SIZE; }
