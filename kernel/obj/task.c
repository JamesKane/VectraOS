// task.c: tasks, threads and address spaces (docs/01 §2).
//
// A task is an address space plus a handle table. Its user half is its own
// page tables; the kernel half is shared (arch_new_user_root). Tasks and
// threads are never destroyed in M1: nothing exits yet.

constexpr uint64_t USER_TOP        = 0x0000'8000'0000'0000;   // first address past the lower half
constexpr uint64_t USER_MAP_BASE   = 0x0000'1000'0000'0000;   // where as_map puts mappings it places
constexpr uint64_t USER_STACK_TOP  = 0x0000'7fff'ffff'0000;
constexpr uint64_t USER_STACK_SIZE = 64 * 1024;
constexpr unsigned KSTACK_ORDER    = 2;                       // 16 KiB kernel stacks

typedef struct task {
    object        obj;
    uint64_t      id;
    uint64_t      root;            // physical address of the address space's top table
    uint64_t      map_next;        // the next address as_map places at
    handle_entry *handles;         // HANDLE_SLOTS entries
    bool          may_debug_write; // the root task's debug capability, until there is a debug-log object
    char          name[24];
} task;

typedef enum thread_state : uint8_t {
    THREAD_READY = 1,
    THREAD_RUNNING,
    THREAD_BLOCKED,
    THREAD_DEAD,
} thread_state;

struct port;

struct thread {
    object        obj;
    task         *task;            // nullptr for the idle thread
    uint64_t      kernel_sp;       // saved by arch_context_switch
    uint64_t      kstack;          // direct-map address of the kernel stack's base
    thread_state  state;
    struct thread *next;           // in the run queue, or in a port's waiters
    struct thread *sleep_next;     // in the sleep queue, ordered by wake_at
    vx_instant    wake_at;         // the deadline it sleeps until
    vx_instant    wake_late;       // wake_at plus its leeway: the timer may wait until here
    struct port  *port;            // the port it waits on
    int64_t       wait_result;
    uint64_t      user_entry, user_sp, user_arg;
};

static pool task_pool   = POOL_FOR(task);
static pool thread_pool = POOL_FOR(thread);
static uint64_t next_task_id = 1;

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
    *t = (task){
        .obj = { .type = OBJ_TASK, .refs = 1 }, .id = next_task_id++, .root = root,
        .map_next = USER_MAP_BASE, .handles = phys_to_virt(handles),
    };
    for (size_t i = 0; name[i] && i < sizeof t->name - 1; i++) t->name[i] = name[i];
    *out = t;
    return VX_OK;
}

// Maps the whole of a VMO into a task's address space. With *va == 0 the kernel
// picks the address; otherwise *va is used and must be page-aligned and free.
// The mapping holds a reference on the VMO. W^X: never writable and executable.
static vx_status task_map(task *t, vmo *v, uint32_t flags, uint64_t *va) {
    if ((flags & VX_MAP_WRITE) && (flags & VX_MAP_EXEC)) return VX_ERR_ACCESS;
    uint64_t at = *va ? *va : t->map_next;
    uint64_t end;
    if ((at & 4095) || ckd_add(&end, at, v->size) || end > USER_TOP) return VX_ERR_RANGE;
    uint32_t mf = MAP_USER | (flags & VX_MAP_WRITE ? MAP_WRITE : 0) | (flags & VX_MAP_EXEC ? MAP_EXEC : 0);
    for (uint64_t off = 0; off < v->size; off += 4096)
        if (!map_range(t->root, at + off, v->pages[off / 4096], 4096, mf)) return VX_ERR_NO_MEMORY;
    v->obj.refs++;
    if (!*va) t->map_next = end + 4096;   // leave a guard page between placed mappings
    *va = at;
    return VX_OK;
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
    *th = (thread){
        .obj = { .type = OBJ_THREAD, .refs = 1 }, .task = t, .kstack = (uint64_t)phys_to_virt(stack),
        .user_entry = entry, .user_sp = sp, .user_arg = arg,
    };
    t->obj.refs++;
    th->kernel_sp = arch_thread_initial_sp(th);
    *out = th;
    return VX_OK;
}

static uint64_t thread_kstack_top(const thread *th) { return th->kstack + (4096ull << KSTACK_ORDER); }
