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
// thread_interrupt is the asynchronous kind: it wakes whatever call the thread
// is blocked in with ERR_INTERRUPTED, and on its way back to user mode the
// thread is diverted to the in-task handler, as POSIX signals need (posixd).
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
  if (!handler || sp < RED_ZONE + sizeof *e + 64 || sp > USER_TOP) return false;
  uint64_t at = (sp - RED_ZONE - sizeof *e) & ~15ull;
  if (copy_to_user(at, e, sizeof *e) != VX_OK) return false;
  return arch_frame_divert(f, handler, at);
}

// Stops the current thread at a port: posts the packet that names it, and
// waits for exception_resume (or a kill). Returns the action; 0 if the packet
// could not be posted, or the task is being killed.
static uint32_t exception_stop(port *p, uint64_t key, bool first, const vx_exception *e) {
  thread *th = this_cpu()->current;
  task *t = th->task;
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
// perhaps changed; false for the default, which kills the task.
static bool exception_raise(struct trap_frame *f, uint32_t kind, uint32_t code, uint64_t address) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  if (kind == VX_EXCEPTION_STEP) arch_frame_step(f, false); // one instruction, done
  if (kind == VX_EXCEPTION_STEP) arch_frame_step(f, false); // one instruction, done
  vx_exception e = {.kind = kind, .code = code, .address = address, .thread = th->id};
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
  uint64_t value = th->interrupt_queue[0];
  if (pending) {
    th->interrupt_count--;
    for (uint32_t i = 0; i < th->interrupt_count; i++) th->interrupt_queue[i] = th->interrupt_queue[i + 1];
  }
  th->interrupt_pending = th->interrupt_count > 0; // the next goes when this one's handler resumes
  spin_unlock(&t->lock);
  if (!pending) return;
  // The wake that brought it here must not end its next wait as well.
  spin_lock(&sched.lock);
  if (th->wake_pending && th->pending_result == VX_ERR_INTERRUPTED) th->wake_pending = false;
  spin_unlock(&sched.lock);
  struct trap_frame *f = arch_user_frame(th);
  vx_exception e = {
      .kind = VX_EXCEPTION_INTERRUPT, .code = (uint32_t)value, .address = value, .thread = th->id};
  arch_frame_regs(f, &e.regs);
  if (!exception_divert(f, &e)) { // no handler now, or a stack that cannot take it: the end
    task_fault_start();
    kput(VX_STR("an interrupt it could not take\n"));
    task_fault_exit();
  }
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
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
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
  spin_lock(&tt->lock);
  bool debuggers = action == VX_RESUME_PASS || action == VX_RESUME_STEP; // from a debugger's port only
  if (!target->exc_stopped || target->exc_action || (debuggers && !target->exc_first)) {
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

static int64_t sys_thread_state(vx_handle th, uint64_t id, uint64_t op, uint64_t buf, uint64_t size) {
  if (op < VX_STATE_GET_EXCEPTION || op > VX_STATE_SET_TLS) return VX_ERR_INVALID;
  bool tls_op = op == VX_STATE_GET_TLS || op == VX_STATE_SET_TLS;
  uint64_t need = sizeof(vx_regs);
  if (op == VX_STATE_GET_EXCEPTION) need = sizeof(vx_exception);
  if (tls_op) need = sizeof(uint64_t);
  if (size < need) return VX_ERR_TOO_SMALL;
  if (tls_op && id == 0) return thread_tls_self(th, op, buf);
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
    tls = target->tls; // it is not running: arch_tls_switch saved it
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

static int64_t sys_thread_interrupt(vx_handle th, uint64_t id, uint64_t value) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  thread *target = nullptr;
  spin_lock(&t->lock);
  if (!t->exc_handler || t->ending) {
    st = VX_ERR_BAD_STATE; // nothing to deliver it to
  } else {
    for (thread *x = t->threads; x && !target; x = x->task_next)
      if (id ? x->id == id : !x->exc_stopped) target = x;
    if (target && target->interrupt_count == THREAD_MAX_INTERRUPTS) {
      st = VX_ERR_SHOULD_WAIT; // its queue is full: the caller may try again
      target = nullptr;
    } else if (target) {
      target->interrupt_queue[target->interrupt_count++] = value;
      target->interrupt_pending = true;
      object_ref(&target->obj);
    } else {
      st = VX_ERR_NOT_FOUND;
    }
  }
  spin_unlock(&t->lock);
  object_release(&t->obj);
  if (!target) return st;
  sched_kick(target, VX_ERR_INTERRUPTED); // out of a call it is blocked in,
  sched_poke(target);                     // or into the kernel from user code on another CPU
  object_release(&target->obj);
  return VX_OK;
}

// thread_suspend: counted; returns once the thread holds still (parked on its
// way to user mode, or blocked in a call), or after a second.
static int64_t sys_thread_suspend(vx_handle th, uint64_t id) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &st);
  if (!t) return st;
  thread *target = task_thread(t, id);
  object_release(&t->obj);
  if (!target) return VX_ERR_NOT_FOUND;
  task *tt = target->task;
  spin_lock(&tt->lock);
  target->suspend_count++;
  spin_unlock(&tt->lock);
  st = VX_OK;
  if (target != this_cpu()->current) { // the caller suspends itself on its own way out
    sched_poke(target);                // in user mode elsewhere: into the kernel, to park
    vx_instant give_up = clock_now() + 1'000'000'000;
    while (!(__atomic_load_n(&target->parked, __ATOMIC_ACQUIRE) || target->state == THREAD_BLOCKED ||
             target->state == THREAD_DEAD)) {
      if (clock_now() >= give_up) {
        st = VX_ERR_TIMED_OUT; // still counted: thread_resume undoes it
        break;
      }
      thread_block(clock_now() + 100'000, 0); // a tenth of a millisecond
    }
  }
  object_release(&target->obj);
  return st;
}

static int64_t sys_thread_resume(vx_handle th, uint64_t id) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_DEBUG, &st);
  if (!t) return st;
  thread *target = task_thread(t, id);
  object_release(&t->obj);
  if (!target) return VX_ERR_NOT_FOUND;
  task *tt = target->task;
  spin_lock(&tt->lock);
  st = target->suspend_count ? VX_OK : VX_ERR_BAD_STATE;
  bool wake = st == VX_OK && --target->suspend_count == 0;
  spin_unlock(&tt->lock);
  if (wake) thread_wake_token(target, &target->suspend_count, VX_OK);
  object_release(&target->obj);
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
    memcpy(phys_to_virt(copy->pages[off / 4096]), phys_to_virt(m->vmo->pages[(m->offset + off) / 4096]),
           4096);
    unmap_page(t->root, m->va + off);
    if (!map_range(t->root, m->va + off, copy->pages[off / 4096], 4096, mf)) st = VX_ERR_NO_MEMORY;
  }
  *old = m->vmo;
  m->vmo = copy;
  m->offset = 0;
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
    } else if (op->write && !(m->flags & VX_MAP_WRITE) && *released_count < 16) {
      st = mapping_privatize(t, m, &released[(*released_count)++]);
      *shoot = true;
    } else if (op->write && !(m->flags & VX_MAP_WRITE)) {
      st = VX_ERR_NO_MEMORY; // too many copies at once: the caller may try again
    }
    if (st == VX_OK) {
      uint8_t *page = (uint8_t *)phys_to_virt(m->vmo->pages[(m->offset + (at - m->va)) / 4096]) + (at & 4095);
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
  if (src->physical)
    st = VX_ERR_UNSUPPORTED;
  else if (!size || (offset | size) & 4095 || ckd_add(&end, offset, size) || end > src->size)
    st = VX_ERR_RANGE;
  else
    st = vmo_create(size, &copy);
  for (uint64_t p = 0; st == VX_OK && p < size / 4096; p++)
    memcpy(phys_to_virt(copy->pages[p]), phys_to_virt(src->pages[offset / 4096 + p]), 4096);
  object_release(&src->obj);
  if (st != VX_OK) return st;
  return return_handle(&copy->obj, ALL_RIGHTS & ~(uint32_t)VX_RIGHT_DEBUG, out); // as vmo_create
}
