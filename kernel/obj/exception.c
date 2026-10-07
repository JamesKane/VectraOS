// exception.c: faults and interrupts in user mode, and who handles them
// (docs/01 §9, 05 §2; the calls are described in abi.h).
//
// A fault goes first to a debugger's port, if one is bound with FIRST_CHANCE:
// it may handle it, step the thread, kill it, or pass the fault on. Then to
// the task's in-task handler, if it has one: the kernel puts
// a vx_exception on the thread's own stack and diverts the thread to the
// handler, which resumes itself with exception_resume. If there is none, or
// the stack cannot take the frame, the fault goes to the task's exception
// port: the thread stops, a packet names it, and it waits until
// exception_resume continues it or kills it. Otherwise the arch code's default
// reports the fault and kills the task.
//
// thread_interrupt is the asynchronous kind: it posts a note (ADR-0010), which
// wakes whatever call the thread is blocked in with ERR_INTERRUPTED, and on
// its way back to user mode the thread is diverted to the in-task handler with
// the note. A task with no handler ends with the note as its exit string, as
// a Plan 9 process that has not called notify does.
//
// The user-mode registers are the frame at the top of the thread's kernel
// stack, which a stopped thread does not touch: thread_state reads and writes
// it there, and the arch code checks what a write may set.

static constexpr uint64_t RED_ZONE = 128; // x86_64's red zone; on aarch64 merely a margin

// Puts e on the current thread's user stack and starts it at the task's
// handler. False if there is no handler, or no room on that stack.
static bool exception_divert(struct trap_frame *f, const vx_exception *e) {
  task *t = this_cpu()->current->task;
  uint64_t handler = t->exc_handler;
#ifdef __x86_64__
  uint64_t sp = e->regs.rsp;
#else
  uint64_t sp = e->regs.sp;
#endif
  // Its note stack, if it has one and is not on it already (a handler that
  // faults nests below itself there): a fault on an overflowed stack still
  // finds room (ADR-0036).
  const thread *th = this_cpu()->current;
  uint64_t lo = th->note_stack, hi = lo + th->note_stack_size;
  if (th->note_stack_size && !(sp > lo && sp <= hi)) sp = hi;
  if (!handler || sp < RED_ZONE + sizeof *e + 64 || sp > USER_TOP) return false;
  uint64_t at = (sp - RED_ZONE - sizeof *e) & ~15ull;
  // The handler runs with key 0 opened, so it can use its stack and data; the
  // rights it interrupted go with the exception, and it writes them back as
  // it leaves (ADR-0035).
  vx_exception d = *e;
  d.rights = arch_rights_read();
  arch_rights_write(d.rights & ~3ull); // x86's PKRU: key 0's AD and WD bits
  if (copy_to_user(at, &d, sizeof d) != VX_OK) {
    arch_rights_write(d.rights);
    return false;
  }
  return arch_frame_divert(f, handler, at);
}

// Stops the current thread at a port: posts the packet that names it, and
// waits for exception_resume (or a kill). Returns the action; 0 if the packet
// could not be posted, or the task is being killed.
static uint32_t exception_stop(port *p, uint64_t key, bool first, const vx_exception *e) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  // Its TLS and FP/SIMD registers saved now, before the packet goes: a
  // debugger may read them at once, before this thread has switched out,
  // and what it sets is loaded when the thread goes on.
  arch_user_save(th);
  th->user_held = true;
  spin_lock(&t->lock);
  th->exc = *e;
  th->exc_stopped = true;
  th->exc_first = first;
  th->exc_action = 0;
  th->wait_token = th;
  spin_unlock(&t->lock);
  vx_packet pk = {.key = key, .value = th->id, .timestamp = clock_now(), .trigger = VX_TRIGGER_EXCEPTION};
  vx_status st = port_post(p, &pk);
  uint32_t action = 0;
  while (st == VX_OK && !t->killed) {
    thread_block(VX_INFINITE, 0); // until exception_resume, or a kill; an interrupt waits with it
    spin_lock(&t->lock);
    action = th->exc_action;
    if (!action) th->wait_token = th; // woken by an interrupt: wait again
    spin_unlock(&t->lock);
    if (action) break;
  }
  spin_lock(&t->lock);
  th->exc_stopped = false;
  th->exc_first = false;
  th->wait_token = nullptr;
  spin_unlock(&t->lock);
  arch_user_load(th); // what a debugger set, or what was saved
  th->user_held = false;
  return t->killed ? 0 : action;
}

// The task's port of one kind (the debugger's, or its own), with a reference.
static port *exception_port(task *t, bool first, uint64_t *key) {
  spin_lock(&t->lock);
  port *p = first ? t->dbg_port : t->exc_port;
  *key = first ? t->dbg_key : t->exc_key;
  if (p) object_ref(&p->obj);
  spin_unlock(&t->lock);
  return p;
}

// A fault in user mode: true if the thread may go back to user mode, its frame
// perhaps changed; false for the default, which kills the task. *kind and
// *address are the exception's as everyone sees it (a pager's late page is
// PAGER_TIMEOUT at the page), so the default's exit string says the same.
static bool exception_raise(struct trap_frame *f, uint32_t *kindp, uint32_t code, uint64_t *addressp) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  if (*kindp == VX_EXCEPTION_PAGE_FAULT) { // a pager's page, perhaps: taken in before anyone sees a fault
    pager_result r = pager_fault(*addressp, code);
    if (r == PAGER_MAPPED || r == PAGER_KILLED) return true; // made again; or user_return ends it
    if (r == PAGER_TIMEOUT) *kindp = VX_EXCEPTION_PAGER_TIMEOUT, *addressp &= ~4095ull;
  }
  uint32_t kind = *kindp;
  uint64_t address = *addressp;
  if (kind == VX_EXCEPTION_STEP) arch_frame_step(f, false); // one instruction, done
  vx_exception e = {.kind = kind, .code = code, .address = address, .thread = th->id};
  if (kind == VX_EXCEPTION_PROTECTION_KEY) e.key = task_key_at(t, address);
  arch_frame_regs(f, &e.regs);
  uint64_t key;
  port *p = exception_port(t, true, &key);
  if (p) { // a debugger first: it may handle it, step, kill, or pass it on
    uint32_t action = exception_stop(p, key, true, &e);
    object_release(&p->obj);
    if (t->killed) return true; // user_return ends it
    if (action == VX_RESUME_STEP) arch_frame_step(f, true);
    if (action == VX_RESUME_CONTINUE || action == VX_RESUME_STEP) return true;
    if (action != VX_RESUME_PASS) return false;
    arch_frame_regs(f, &e.regs); // as the debugger left them
  }
  if (kind == VX_EXCEPTION_STEP) return true; // a step is the debugger's alone
  if (exception_divert(f, &e)) return true;
  p = exception_port(t, false, &key);
  if (!p) return false;
  uint32_t action = exception_stop(p, key, false, &e);
  object_release(&p->obj);
  if (t->killed) return true;
  return action == VX_RESUME_CONTINUE;
}

// On the way back to user mode (user_return): a suspended thread parks here,
// with its user registers where thread_state can reach them, until it is
// resumed or killed. True if it parked (the caller looks at the kill again).
static bool exception_check_suspend(void) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  if (!__atomic_load_n(&th->suspend_count, __ATOMIC_RELAXED)) return false;
  spin_lock(&t->lock);
  bool parked = false;
  while (th->suspend_count && !t->killed) {
    th->parked = parked = true;
    th->wait_token = &th->suspend_count;
    spin_unlock(&t->lock);
    thread_block(VX_INFINITE, 0); // thread_resume wakes it, as does a kill
    spin_lock(&t->lock);
  }
  th->parked = false;
  th->wait_token = nullptr;
  spin_unlock(&t->lock);
  return parked;
}

// On the way back to user mode (user_return): an interrupt pending on the
// current thread is delivered to its task's handler.
static void exception_check_interrupt(void) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  if (!__atomic_load_n(&th->interrupt_pending, __ATOMIC_RELAXED)) return;
  spin_lock(&t->lock);
  bool pending = th->interrupt_count > 0;
  vx_exception e = {.kind = VX_EXCEPTION_INTERRUPT, .code = th->notes[0].len, .thread = th->id};
  memcpy(e.note, th->notes[0].text, th->notes[0].len);
  if (pending) {
    th->interrupt_count--;
    for (uint32_t i = 0; i < th->interrupt_count; i++) th->notes[i] = th->notes[i + 1];
  }
  // The next goes on the thread's next way back to user mode, though this
  // one's handler may still be running: handlers nest, as POSIX's do (the
  // musl back end masks what must not). Holding it until exception_resume
  // would strand it when a handler leaves by longjmp, which never resumes.
  th->interrupt_pending = th->interrupt_count > 0;
  spin_unlock(&t->lock);
  if (!pending) return;
  // The wake that brought it here must not end its next wait as well.
  spin_lock(&sched.lock);
  if (th->wake_pending && th->pending_result == VX_ERR_INTERRUPTED) th->wake_pending = false;
  spin_unlock(&sched.lock);
  struct trap_frame *f = arch_user_frame(th);
  arch_frame_regs(f, &e.regs);
  if (!exception_divert(f, &e)) // no handler now, or a stack that cannot take it: the note ends it
    task_exit_with(e.note, e.code);
}

// The thread of task t with this id, with a reference; or null.
static thread *task_thread(task *t, uint64_t id) {
  thread *found = nullptr;
  spin_lock(&t->lock);
  for (thread *th = t->threads; th && !found; th = th->task_next)
    if (th->id == id) found = th;
  if (found) object_ref(&found->obj);
  spin_unlock(&t->lock);
  return found;
}

// --- The calls ---

static int64_t sys_exception_bind(vx_handle th, vx_handle ph, uint64_t key, uint64_t options) {
  if (options & ~(uint64_t)(VX_EXCEPTION_IN_TASK | VX_EXCEPTION_FIRST_CHANCE) || options == 3)
    return VX_ERR_INVALID;
  bool first = options & VX_EXCEPTION_FIRST_CHANCE;
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, first ? VX_RIGHT_DEBUG : VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  if (options & VX_EXCEPTION_IN_TASK) {
    st = key < USER_TOP ? VX_OK : VX_ERR_INVALID;
    if (st == VX_OK) {
      spin_lock(&t->lock);
      t->exc_handler = key;
      spin_unlock(&t->lock);
    }
    object_release(&t->obj);
    return st;
  }
  port *p = nullptr;
  if (ph != VX_HANDLE_NONE && !(p = (port *)handle_get(current_task(), ph, OBJ_PORT, VX_RIGHT_SIGNAL, &st))) {
    object_release(&t->obj);
    return st;
  }
  spin_lock(&t->lock);
  port *old = first ? t->dbg_port : t->exc_port;
  if (t->root) { // a torn-down task keeps no port
    *(first ? &t->dbg_port : &t->exc_port) = p;
    *(first ? &t->dbg_key : &t->exc_key) = key;
    p = nullptr;
  } else {
    old = nullptr;
    st = VX_ERR_BAD_STATE;
  }
  spin_unlock(&t->lock);
  if (old) object_release(&old->obj);
  if (p) object_release(&p->obj);
  object_release(&t->obj);
  return st;
}

static int64_t sys_exception_resume(vx_handle th, uint64_t id, uint64_t action, uint64_t regs_ptr) {
  if (action < VX_RESUME_CONTINUE || action > VX_RESUME_STEP) return VX_ERR_INVALID;
  vx_regs regs;
  vx_status st = regs_ptr ? copy_from_user(&regs, regs_ptr, sizeof regs) : VX_OK;
  if (st != VX_OK) return st;
  // Its own thread leaving its handler needs MANAGE on its own task; another
  // thread's stop is checked below, by whose stop it is.
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, id == 0 ? VX_RIGHT_MANAGE : 0, &st);
  if (!t) return st;
  if (id == 0) { // the caller, leaving its handler
    thread *self = this_cpu()->current;
    if (t != self->task || action != VX_RESUME_CONTINUE || !regs_ptr) {
      object_release(&t->obj);
      return VX_ERR_INVALID;
    }
    object_release(&t->obj);
    struct trap_frame *f = arch_user_frame(self);
    if ((st = arch_frame_set_regs(f, &regs)) != VX_OK) return st;
    // The dispatcher writes the result into the return register: give it the
    // value restored there.
#ifdef __x86_64__
    return (int64_t)regs.rax;
#else
    return (int64_t)regs.x[0];
#endif
  }
  thread *target = task_thread(t, id);
  object_release(&t->obj);
  if (!target) return VX_ERR_NOT_FOUND;
  task *tt = target->task;
  // A stop at the debugger's port is the debugger's to answer: DEBUG, as
  // binding that port takes; one at the task's exception port, MANAGE, as
  // binding that takes (M6 step 6b: MANAGE alone answered both).
  spin_lock(&tt->lock);
  bool first = target->exc_stopped && target->exc_first;
  spin_unlock(&tt->lock);
  task *auth =
      (task *)handle_get(current_task(), th, OBJ_TASK, first ? VX_RIGHT_DEBUG : VX_RIGHT_MANAGE, &st);
  if (!auth) {
    object_release(&target->obj);
    return st;
  }
  object_release(&auth->obj);
  spin_lock(&tt->lock);
  bool debuggers = action == VX_RESUME_PASS || action == VX_RESUME_STEP; // from a debugger's port only
  if (!target->exc_stopped || target->exc_action || target->exc_first != first ||
      (debuggers && !target->exc_first)) {
    st = VX_ERR_BAD_STATE;
  } else {
    if (regs_ptr) st = arch_frame_set_regs(arch_user_frame(target), &regs);
    if (st == VX_OK) target->exc_action = (uint32_t)action;
  }
  spin_unlock(&tt->lock);
  if (st == VX_OK) thread_wake_token(target, target, VX_OK);
  object_release(&target->obj);
  return st;
}

// A thread's own thread pointer, with a handle to its own task (any rights).
static int64_t thread_tls_self(vx_handle th, uint64_t op, uint64_t buf) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, 0, &st);
  if (!t) return st;
  bool own = t == current_task();
  object_release(&t->obj);
  if (!own) return VX_ERR_INVALID;
  uint64_t value = 0;
  if (op == VX_STATE_GET_TLS) {
    value = arch_tls_read();
    return copy_to_user(buf, &value, sizeof value);
  }
  st = copy_from_user(&value, buf, sizeof value);
  if (st != VX_OK) return st;
  if (value >= USER_TOP) return VX_ERR_RANGE; // x86_64's FS base must be canonical
  arch_tls_write(value);
  return VX_OK;
}

// GET_NOTE_STACK and SET_NOTE_STACK: the caller's own (ADR-0036).
static int64_t thread_note_stack(vx_handle th, uint64_t op, uint64_t buf) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, 0, &st);
  if (!t) return st;
  bool own = t == current_task();
  object_release(&t->obj);
  if (!own) return VX_ERR_INVALID;
  thread *me = this_cpu()->current;
  vx_note_stack ns = {.base = me->note_stack, .size = me->note_stack_size};
  if (op == VX_STATE_GET_NOTE_STACK) return copy_to_user(buf, &ns, sizeof ns);
  st = copy_from_user(&ns, buf, sizeof ns);
  if (st != VX_OK) return st;
  uint64_t end;
  if (ns.size == 0)
    ns.base = 0; // none: handlers run on the thread's own stack
  else if (ns.size < VX_NOTE_STACK_MIN || ckd_add(&end, ns.base, ns.size) || end > USER_TOP)
    return VX_ERR_RANGE;
  me->note_stack = ns.base, me->note_stack_size = ns.size; // only this thread changes them
  return VX_OK;
}

// The live thread of the task with the next id after `after`: NEXT_THREAD.
static int64_t thread_next(vx_handle th, uint64_t after, uint64_t buf) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  vx_thread_info info = {};
  spin_lock(&t->lock);
  for (const thread *x = t->threads; x; x = x->task_next) {
    if (x->id <= after || (info.id && x->id >= info.id) || x->state == THREAD_DEAD) continue;
    uint32_t state = VX_THREAD_RUNNING;
    if (x->exc_stopped)
      state = VX_THREAD_STOPPED;
    else if (x->suspend_count && x->parked)
      state = VX_THREAD_SUSPENDED;
    else if (x->state == THREAD_BLOCKED)
      state = VX_THREAD_BLOCKED;
    info = (vx_thread_info){
        .id = x->id, .state = state, .suspend_count = x->suspend_count, .first_chance = x->exc_first};
  }
  spin_unlock(&t->lock);
  object_release(&t->obj);
  return info.id ? copy_to_user(buf, &info, sizeof info) : VX_ERR_NOT_FOUND;
}

// FP/SIMD registers a debugger gives are made safe to load: x86_64's MXCSR
// with no reserved bit set (FXRSTOR would fault in the kernel), aarch64's
// FPCR and FPSR with only their defined bits.
static void fpregs_sanitize(vx_fpregs *f) {
#ifdef __x86_64__
  uint32_t mxcsr;
  memcpy(&mxcsr, f->fxsave + 24, sizeof mxcsr);
  mxcsr &= 0xffbf; // MXCSR_MASK's default: DAZ aside, every defined bit
  memcpy(f->fxsave + 24, &mxcsr, sizeof mxcsr);
#else
  f->fpcr &= 0x07ff9f00;
  f->fpsr &= 0xf800009f;
#endif
}

// The task's watchpoints: GET_WATCH and SET_WATCH. A set is checked whole:
// each slot off, or an aligned user address of 1, 2, 4 or 8 bytes, within the
// hardware's count.
static int64_t thread_watch(vx_handle th, uint64_t op, uint64_t buf) {
  vx_watches w = {};
  vx_status st = VX_OK;
  if (op == VX_STATE_SET_WATCH && (st = copy_from_user(&w, buf, sizeof w)) != VX_OK) return st;
  uint32_t count = arch_watch_count();
  bool any = false;
  for (uint32_t i = 0; op == VX_STATE_SET_WATCH && i < VX_WATCH_MAX; i++) {
    const vx_watch *s = &w.slot[i];
    if (s->kind == VX_WATCH_OFF) continue;
    bool len_ok = s->len == 1 || s->len == 2 || s->len == 4 || s->len == 8;
    if (i >= count || s->kind > VX_WATCH_RW || !len_ok || s->address % s->len || s->address >= USER_TOP)
      return VX_ERR_INVALID;
    any = true;
  }
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG,
                               &st); // both: a debugger's, as abi.h has it
  if (!t) return st;
  spin_lock(&t->lock);
  if (op == VX_STATE_SET_WATCH) {
    memcpy(t->watches, w.slot, sizeof t->watches);
    t->watching = any;
  } else {
    memcpy(w.slot, t->watches, sizeof w.slot);
  }
  spin_unlock(&t->lock);
  object_release(&t->obj);
  w.count = count;
  return op == VX_STATE_GET_WATCH ? copy_to_user(buf, &w, sizeof w) : VX_OK;
}

// GET_FPREGS, SET_FPREGS, GET_XSTATE and SET_XSTATE: the thread's saved
// FP/SIMD area, through a page of the kernel's (the area can be most of one).
// A read is the debugger's view (arch_fp_view); a write of the legacy part
// alone keeps the rest, and a whole one is checked as XRSTOR would.
static int64_t thread_fp(vx_handle th, uint64_t id, uint64_t op, uint64_t buf) {
  bool whole = op == VX_STATE_GET_XSTATE || op == VX_STATE_SET_XSTATE;
  bool set = op == VX_STATE_SET_FPREGS || op == VX_STATE_SET_XSTATE;
  uint32_t n = whole ? arch_fp_size() : (uint32_t)sizeof(vx_fpregs);
  uint64_t pa = phys_alloc(0);
  if (!pa) return VX_ERR_NO_MEMORY;
  uint8_t *area = phys_to_virt(pa);
  vx_status st = set ? copy_from_user(area, buf, n) : VX_OK;
  if (st == VX_OK && op == VX_STATE_SET_FPREGS) fpregs_sanitize((vx_fpregs *)area);
  task *t = st == VX_OK ? (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st) : nullptr;
  thread *target = nullptr;
  if (t) {
    vx_status ignored;
    task *as_debugger = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &ignored);
    bool debugger = as_debugger != nullptr;
    if (as_debugger) object_release(&as_debugger->obj);
    target = task_thread(t, id);
    object_release(&t->obj);
    if (!target) st = VX_ERR_NOT_FOUND;
    task *tt = target ? target->task : nullptr;
    if (tt) {
      spin_lock(&tt->lock);
      bool still = target->suspend_count && (target->parked || target->state == THREAD_BLOCKED);
      if (!target->exc_stopped && !(still && debugger)) {
        st = VX_ERR_BAD_STATE; // running: neither read nor changed
      } else if (!set) {
        static_assert(sizeof(vx_fpregs) <= ARCH_FP_MAX);
        uint8_t *view = area + ARCH_FP_MAX / 2; // the copy for user memory in the page's top half,
        if (whole) view = area;                 // or all of it for the whole area
        arch_fp_view(target->fp, view);
        if (!whole) memmove(area, view, sizeof(vx_fpregs));
      } else if (op == VX_STATE_SET_XSTATE && (st = arch_fp_check(area)) == VX_OK) {
        memcpy(target->fp, area, n); // loaded when it next runs
      } else if (op == VX_STATE_SET_FPREGS) {
        memcpy(target->fp, area, n);
        arch_fp_legacy_set(target->fp);
      }
      spin_unlock(&tt->lock);
    }
    if (target) object_release(&target->obj);
  }
  if (st == VX_OK && !set) st = copy_to_user(buf, area, n);
  phys_free(pa, 0);
  return st;
}

// GET_CPU (ADR-0035): what the kernel saves, and lets user code use.
static int64_t thread_cpu(uint64_t buf) {
  vx_cpu_info info;
  arch_cpu_info(&info);
  return copy_to_user(buf, &info, sizeof info);
}

// GET_SCHED: a thread's scheduling (ADR-0038), id 0 the caller's own.
static int64_t thread_sched_get(vx_handle th, uint64_t id, uint64_t buf) {
  vx_sched_info info;
  if (!id) {
    sched_info(this_cpu()->current, &info);
    return copy_to_user(buf, &info, sizeof info);
  }
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_INSPECT, &st);
  if (!t) return st;
  thread *target = task_thread(t, id);
  object_release(&t->obj);
  if (!target) return VX_ERR_NOT_FOUND;
  sched_info(target, &info);
  object_release(&target->obj);
  return copy_to_user(buf, &info, sizeof info);
}

// GET_TIMES (ADR-0041): a thread's ticks, or with id 0 its task's, those of
// threads reaped and of the rest, as nanoseconds. With INSPECT on the task.
static int64_t thread_times(vx_handle th, uint64_t id, uint64_t buf) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_INSPECT, &st);
  if (!t) return st;
  uint64_t ticks[2] = {};
  bool found = !id;
  spin_lock(&t->lock);
  if (!id) ticks[0] = t->gone_ticks[0], ticks[1] = t->gone_ticks[1];
  for (thread *x = t->threads; x; x = x->task_next) {
    if (id && x->id != id) continue;
    found = true;
    for (int k = 0; k < 2; k++) ticks[k] += atomic_load_explicit(&x->ticks[k], memory_order_relaxed);
  }
  spin_unlock(&t->lock);
  object_release(&t->obj);
  if (!found) return VX_ERR_NOT_FOUND;
  vx_cpu_times out = {.user = (vx_duration)(ticks[0] * TICK), .sys = (vx_duration)(ticks[1] * TICK)};
  return copy_to_user(buf, &out, sizeof out);
}

static int64_t sys_thread_state(vx_handle th, uint64_t id, uint64_t op, uint64_t buf, uint64_t size) {
  if (op < VX_STATE_GET_EXCEPTION || op > VX_STATE_GET_TIMES) return VX_ERR_INVALID;
  bool ns_op = op == VX_STATE_GET_NOTE_STACK || op == VX_STATE_SET_NOTE_STACK;
  bool tls_op = op == VX_STATE_GET_TLS || op == VX_STATE_SET_TLS;
  bool fp_op = op == VX_STATE_GET_FPREGS || op == VX_STATE_SET_FPREGS;
  bool x_op = op == VX_STATE_GET_XSTATE || op == VX_STATE_SET_XSTATE;
  uint64_t need = sizeof(vx_regs);
  if (op == VX_STATE_GET_EXCEPTION) need = sizeof(vx_exception);
  if (tls_op) need = sizeof(uint64_t);
  if (fp_op) need = sizeof(vx_fpregs);
  if (x_op) need = arch_fp_size();
  if (op == VX_STATE_GET_CPU) need = sizeof(vx_cpu_info);
  if (op == VX_STATE_NEXT_THREAD) need = sizeof(vx_thread_info);
  if (op == VX_STATE_GET_WATCH || op == VX_STATE_SET_WATCH) need = sizeof(vx_watches);
  if (ns_op) need = sizeof(vx_note_stack);
  if (op == VX_STATE_GET_SCHED) need = sizeof(vx_sched_info);
  if (op == VX_STATE_GET_TIMES) need = sizeof(vx_cpu_times);
  if (size < need) return VX_ERR_TOO_SMALL;
  if (op == VX_STATE_GET_TIMES) return thread_times(th, id, buf);
  if (op == VX_STATE_GET_SCHED) return thread_sched_get(th, id, buf);
  if (op == VX_STATE_NEXT_THREAD) return thread_next(th, id, buf);
  if (op == VX_STATE_GET_CPU) return id ? VX_ERR_INVALID : thread_cpu(buf);
  if (fp_op || x_op) return thread_fp(th, id, op, buf);
  if (op == VX_STATE_GET_WATCH || op == VX_STATE_SET_WATCH)
    return id ? VX_ERR_INVALID : thread_watch(th, op, buf);
  if (tls_op && id == 0) return thread_tls_self(th, op, buf);
  if (ns_op) return id ? VX_ERR_INVALID : thread_note_stack(th, op, buf);
  vx_regs regs;
  uint64_t tls = 0;
  vx_status st = VX_OK;
  if (op == VX_STATE_SET_REGS) st = copy_from_user(&regs, buf, sizeof regs);
  if (op == VX_STATE_SET_TLS) st = copy_from_user(&tls, buf, sizeof tls);
  if (st != VX_OK) return st;
  if (op == VX_STATE_SET_TLS && tls >= USER_TOP) return VX_ERR_RANGE;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  vx_status ignored;
  task *as_debugger = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &ignored);
  bool debugger = as_debugger != nullptr;
  if (as_debugger) object_release(&as_debugger->obj);
  thread *target = task_thread(t, id);
  object_release(&t->obj);
  if (!target) return VX_ERR_NOT_FOUND;
  task *tt = target->task;
  vx_exception e;
  spin_lock(&tt->lock);
  // A suspended thread's registers hold still once it has parked, or while it
  // is blocked in a call (which will park it on the way out).
  bool still = target->suspend_count && (target->parked || target->state == THREAD_BLOCKED);
  if (!target->exc_stopped && !(still && debugger && op != VX_STATE_GET_EXCEPTION)) {
    st = VX_ERR_BAD_STATE; // running: neither read nor changed
  } else if (op == VX_STATE_GET_EXCEPTION) {
    e = target->exc;
  } else if (op == VX_STATE_GET_REGS) {
    arch_frame_regs(arch_user_frame(target), &e.regs);
  } else if (op == VX_STATE_SET_REGS) {
    st = arch_frame_set_regs(arch_user_frame(target), &regs);
  } else if (op == VX_STATE_GET_TLS) {
    tls = target->tls; // saved: by exception_stop, or as it switched out
  } else {
    target->tls = tls; // loaded when it next runs
  }
  spin_unlock(&tt->lock);
  object_release(&target->obj);
  if (st != VX_OK || op == VX_STATE_SET_REGS || op == VX_STATE_SET_TLS) return st;
  if (op == VX_STATE_GET_TLS) return copy_to_user(buf, &tls, sizeof tls);
  return op == VX_STATE_GET_EXCEPTION ? copy_to_user(buf, &e, sizeof e)
                                      : copy_to_user(buf, &e.regs, sizeof e.regs);
}

static int64_t sys_thread_interrupt(vx_handle th, uint64_t id, uint64_t note_ptr, uint64_t len) {
  if (len == 0 || len > VX_ERRMAX) return VX_ERR_INVALID;
  char note[VX_ERRMAX];
  vx_status st = copy_from_user(note, note_ptr, len);
  if (st != VX_OK) return st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  thread *target = nullptr;
  spin_lock(&t->lock);
  bool handled = t->exc_handler != 0;
  if (t->ending || t->killed) {
    st = VX_ERR_BAD_STATE; // ending already
  } else if (!handled) {
    st = VX_OK; // no one to take it: it ends the task, below
  } else {
    for (thread *x = t->threads; x && !target; x = x->task_next) // a thread that will take it
      if (!x->exited && (id ? x->id == id : !x->exc_stopped)) target = x;
    if (target && target->interrupt_count == THREAD_MAX_INTERRUPTS) {
      st = VX_ERR_SHOULD_WAIT; // its queue is full: the caller may try again
      target = nullptr;
    } else if (target) {
      target->notes[target->interrupt_count].len = (uint8_t)len;
      memcpy(target->notes[target->interrupt_count++].text, note, len);
      target->interrupt_pending = true;
      object_ref(&target->obj);
    } else {
      st = VX_ERR_NOT_FOUND;
    }
  }
  spin_unlock(&t->lock);
  if (st == VX_OK && !handled) task_kill(t, note, len);
  object_release(&t->obj);
  if (!target) return st;
  sched_kick(target, VX_ERR_INTERRUPTED); // out of a call it is blocked in,
  sched_poke(target);                     // or into the kernel from user code on another CPU
  object_release(&target->obj);
  return VX_OK;
}

// Up to cap of task t's threads, each with a reference: the one with this id,
// or with id 0, every one (a process stops as a whole: procfs's ctl stop), a
// batch at a time, the cap lowest ids above `after` in each. By id, not by
// place in the list, which threads join and leave between batches: one would
// be missed, or taken twice (the Rust port's finding).
static uint32_t task_threads(task *t, uint64_t id, uint32_t after, thread **out, uint32_t cap) {
  uint32_t n = 0;
  spin_lock(&t->lock);
  for (thread *th = t->threads; th; th = th->task_next) {
    if ((id && th->id != id) || th->id <= after) continue;
    if (n == cap && th->id >= out[n - 1]->id) continue;
    uint32_t at = n < cap ? n++ : n - 1; // in order of id: the highest falls off when full
    while (at > 0 && out[at - 1]->id > th->id) out[at] = out[at - 1], at--;
    out[at] = th;
  }
  for (uint32_t i = 0; i < n; i++) object_ref(&out[i]->obj);
  spin_unlock(&t->lock);
  return n;
}

static constexpr uint32_t SUSPEND_MAX = 64; // threads taken at once by thread_suspend(0)

// One thread's suspension: counted; returns once it holds still (parked on
// its way to user mode, or blocked in a call), or after a second.
static vx_status thread_suspend_one(thread *target) {
  task *tt = target->task;
  spin_lock(&tt->lock);
  target->suspend_count++;
  spin_unlock(&tt->lock);
  if (target == this_cpu()->current) return VX_OK; // the caller suspends itself on its own way out
  vx_instant give_up = clock_now() + 1'000'000'000;
  while (!(__atomic_load_n(&target->parked, __ATOMIC_ACQUIRE) || target->state == THREAD_BLOCKED ||
           target->state == THREAD_DEAD)) {
    if (clock_now() >= give_up) return VX_ERR_TIMED_OUT; // still counted: thread_resume undoes it
    // In user mode elsewhere: into the kernel, to park. Each time round, as a
    // thread that was ready, not running, at first (one just started) may be
    // in user mode now, where nothing else would stop it.
    sched_poke(target);
    thread_block(clock_now() + 100'000, 0); // a tenth of a millisecond
  }
  return VX_OK;
}

static vx_status thread_resume_one(thread *target) {
  task *tt = target->task;
  spin_lock(&tt->lock);
  vx_status st = target->suspend_count ? VX_OK : VX_ERR_BAD_STATE;
  bool wake = st == VX_OK && --target->suspend_count == 0;
  spin_unlock(&tt->lock);
  if (wake) thread_wake_token(target, &target->suspend_count, VX_OK);
  return st;
}

// thread_suspend(task, thread) and thread_resume: the thread with that id,
// or with 0, every thread the task has.
static int64_t sys_thread_suspend(vx_handle th, uint64_t id) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &st);
  if (!t) return st;
  thread *targets[SUSPEND_MAX];
  uint32_t n = 0, done = 0;
  st = VX_ERR_NOT_FOUND;
  do { // a batch at a time: every thread, however many
    n = task_threads(t, id, done, targets, SUSPEND_MAX);
    uint32_t last = n ? targets[n - 1]->id : done; // before they are let go
    if (n && st == VX_ERR_NOT_FOUND) st = VX_OK;
    for (uint32_t i = 0; i < n; i++) {
      vx_status one = thread_suspend_one(targets[i]);
      if (st == VX_OK) st = one;
      object_release(&targets[i]->obj);
    }
    done = last; // the batch's highest: the next starts above it
  } while (n == SUSPEND_MAX);
  object_release(&t->obj);
  return st;
}

static int64_t sys_thread_resume(vx_handle th, uint64_t id) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &st);
  if (!t) return st;
  thread *targets[SUSPEND_MAX];
  uint32_t n = 0, done = 0;
  st = VX_ERR_NOT_FOUND;
  do {
    n = task_threads(t, id, done, targets, SUSPEND_MAX);
    uint32_t last = n ? targets[n - 1]->id : done; // before they are let go
    if (n && st == VX_ERR_NOT_FOUND) st = VX_OK;
    for (uint32_t i = 0; i < n; i++) {
      vx_status one = thread_resume_one(targets[i]);
      if (st == VX_OK) st = one;
      object_release(&targets[i]->obj);
    }
    done = last; // the batch's highest: the next starts above it
  } while (n == SUSPEND_MAX);
  object_release(&t->obj);
  return st;
}

// Gives a mapping a private copy of its VMO's range, so that a write to it
// (a breakpoint in code) reaches nobody else and needs no writable mapping:
// the pages are mapped again from the copy, with the same permissions. Under
// the task's lock; the old VMO is returned for the caller to release once
// the old translations are shot down.
static vx_status mapping_privatize(task *t, mapping *m, vmo **old) {
  vmo *copy;
  vx_status st = vmo_create(m->size, &copy);
  if (st != VX_OK) return st;
  uint32_t mf =
      MAP_USER | (m->flags & VX_MAP_WRITE ? MAP_WRITE : 0) | (m->flags & VX_MAP_EXEC ? MAP_EXEC : 0);
  for (uint64_t off = 0; off < m->size; off += 4096) {
    arch_page_copy(phys_to_virt(copy->pages[off / 4096]),
                   phys_to_virt(m->vmo->pages[(m->offset + off) / 4096]), 4096);
    unmap_page(t->root, m->va + off);
    if (!map_range(t->root, m->va + off, copy->pages[off / 4096], 4096, mf)) st = VX_ERR_NO_MEMORY;
  }
  *old = m->vmo;
  m->vmo = copy;
  m->offset = 0;
  m->privatized = true; // written in place from now on: copied once, not for each page
  return st;
}

// One op of task_mem_rw, a page at a time, under the task's lock so no page
// can go while it is copied.
static vx_status mem_op(task *t, const vx_mem_op *op, bool *shoot, vmo **released, uint32_t *released_count) {
  uint64_t end;
  if (ckd_add(&end, op->address, op->size) || end > USER_TOP || op->size > (1u << 20)) return VX_ERR_RANGE;
  vx_status st = VX_OK;
  for (uint64_t done = 0; st == VX_OK && done < op->size;) {
    uint64_t at = op->address + done, n = 4096 - (at & 4095);
    if (n > op->size - done) n = op->size - done;
    spin_lock(&t->lock);
    mapping *m = nullptr;
    for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS && !m; i++)
      if (t->maps[i].size && at >= t->maps[i].va && at < t->maps[i].va + t->maps[i].size) m = &t->maps[i];
    if (!m || m->vmo->physical) {
      st = m ? VX_ERR_UNSUPPORTED : VX_ERR_INVALID; // device memory, or nothing there
    } else if (m->vmo->pager && (op->write || !vmo_page(m->vmo, (m->offset + (at - m->va)) / 4096))) {
      st =
          op->write ? VX_ERR_UNSUPPORTED : VX_ERR_SHOULD_WAIT; // a pager's pages: read only those it supplied
    } else if (op->write && !(m->flags & VX_MAP_WRITE) && !m->privatized && *released_count < 16) {
      st = mapping_privatize(t, m, &released[(*released_count)++]);
      *shoot = true;
    } else if (op->write && !(m->flags & VX_MAP_WRITE) && !m->privatized) {
      st = VX_ERR_NO_MEMORY; // too many copies at once: the caller may try again
    }
    if (st == VX_OK) {
      uint8_t *page =
          (uint8_t *)phys_to_virt(vmo_page(m->vmo, (m->offset + (at - m->va)) / 4096)) + (at & 4095);
      st = op->write ? copy_from_user(page, op->buffer + done, n) : copy_to_user(op->buffer + done, page, n);
      if (st == VX_OK && op->write && (m->flags & VX_MAP_EXEC)) arch_sync_icache(page, n);
    }
    spin_unlock(&t->lock);
    done += n;
  }
  return st;
}

static int64_t sys_task_mem_rw(vx_handle th, uint64_t ops_ptr, uint64_t count) {
  static constexpr uint64_t MAX_OPS = 16;
  if (!count || count > MAX_OPS) return VX_ERR_INVALID;
  vx_mem_op ops[MAX_OPS];
  vx_status st = copy_from_user(ops, ops_ptr, count * sizeof ops[0]);
  if (st != VX_OK) return st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &st);
  if (!t) return st;
  bool shoot = false;
  vmo *released[16];
  uint32_t released_count = 0;
  for (uint64_t i = 0; i < count; i++) ops[i].status = mem_op(t, &ops[i], &shoot, released, &released_count);
  uint64_t root = t->root;
  object_release(&t->obj);
  if (shoot && root) arch_tlb_shootdown(root, 0, USER_TOP); // the old pages are cached nowhere now
  for (uint32_t i = 0; i < released_count; i++) object_release(&released[i]->obj);
  return copy_to_user(ops_ptr, ops, count * sizeof ops[0]);
}

// vmo_clone: a copy, made now and charged in full (01 §5). Pages shared until
// written is an optimization for later, behind the same call.
static int64_t sys_vmo_clone(vx_handle h, uint64_t offset, uint64_t size, uint64_t options, uint64_t out) {
  if (options) return VX_ERR_INVALID;
  vx_status st;
  vmo *src = (vmo *)handle_get(current_task(), h, OBJ_VMO, VX_RIGHT_READ, &st);
  if (!src) return st;
  uint64_t end;
  vmo *copy = nullptr;
  if (src->physical || src->pager) // device memory, or pages a pager has not all supplied
    st = VX_ERR_UNSUPPORTED;
  else if (!size || (offset | size) & 4095 || ckd_add(&end, offset, size) || end > src->size)
    st = VX_ERR_RANGE;
  else
    st = vmo_create(size, &copy);
  for (uint64_t p = 0; st == VX_OK && p < size / 4096; p++)
    arch_page_copy(phys_to_virt(copy->pages[p]), phys_to_virt(src->pages[offset / 4096 + p]), 4096);
  object_release(&src->obj);
  if (st != VX_OK) return st;
  return return_handle(&copy->obj, ALL_RIGHTS & ~(uint32_t)VX_RIGHT_DEBUG, out); // as vmo_create
}
