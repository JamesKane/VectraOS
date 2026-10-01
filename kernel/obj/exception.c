// exception.c: faults and interrupts in user mode, and who handles them
// (docs/01 §9, 05 §2; the calls are described in abi.h).
//
// A fault goes to the task's in-task handler, if it has one: the kernel puts
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

// A fault in user mode: true if the thread may go back to user mode, its frame
// perhaps changed; false for the default, which kills the task.
static bool exception_raise(struct trap_frame *f, uint32_t kind, uint32_t code, uint64_t address) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  vx_exception e = {.kind = kind, .code = code, .address = address, .thread = th->id};
  arch_frame_regs(f, &e.regs);
  if (exception_divert(f, &e)) return true;

  spin_lock(&t->lock);
  port *p = t->exc_port;
  uint64_t key = t->exc_key;
  if (p) {
    object_ref(&p->obj);
    th->exc = e;
    th->exc_stopped = true;
    th->exc_action = 0;
    th->wait_token = th;
  }
  spin_unlock(&t->lock);
  if (!p) return false;
  vx_packet pk = {.key = key, .value = th->id, .timestamp = clock_now(), .trigger = VX_TRIGGER_EXCEPTION};
  vx_status st = port_post(p, &pk);
  object_release(&p->obj);

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
  th->wait_token = nullptr;
  spin_unlock(&t->lock);
  if (t->killed) return true; // user_return ends it
  return st == VX_OK && action == VX_RESUME_CONTINUE;
}

// On the way back to user mode (user_return): an interrupt pending on the
// current thread is delivered to its task's handler.
static void exception_check_interrupt(void) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  if (!__atomic_load_n(&th->interrupt_pending, __ATOMIC_RELAXED)) return;
  spin_lock(&t->lock);
  bool pending = th->interrupt_pending;
  uint64_t value = th->interrupt_value;
  th->interrupt_pending = false;
  spin_unlock(&t->lock);
  if (!pending) return;
  // The wake that brought it here must not end its next wait as well.
  spin_lock(&sched.lock);
  if (th->wake_pending && th->wait_result == VX_ERR_INTERRUPTED) th->wake_pending = false;
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
  if (options & ~(uint64_t)VX_EXCEPTION_IN_TASK) return VX_ERR_INVALID;
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
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
  port *old = t->exc_port;
  if (t->root) { // a torn-down task keeps no port
    t->exc_port = p;
    t->exc_key = key;
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
  if (action != VX_RESUME_CONTINUE && action != VX_RESUME_KILL) return VX_ERR_INVALID;
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
  if (!target->exc_stopped || target->exc_action) {
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

static int64_t sys_thread_state(vx_handle th, uint64_t id, uint64_t op, uint64_t buf, uint64_t size) {
  if (op < VX_STATE_GET_EXCEPTION || op > VX_STATE_SET_REGS) return VX_ERR_INVALID;
  uint64_t need = op == VX_STATE_GET_EXCEPTION ? sizeof(vx_exception) : sizeof(vx_regs);
  if (size < need) return VX_ERR_TOO_SMALL;
  vx_regs regs;
  vx_status st = op == VX_STATE_SET_REGS ? copy_from_user(&regs, buf, sizeof regs) : VX_OK;
  if (st != VX_OK) return st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  thread *target = task_thread(t, id);
  object_release(&t->obj);
  if (!target) return VX_ERR_NOT_FOUND;
  task *tt = target->task;
  vx_exception e;
  spin_lock(&tt->lock);
  if (!target->exc_stopped) {
    st = VX_ERR_BAD_STATE; // running threads cannot be read or changed (thread_suspend: step 1c)
  } else if (op == VX_STATE_GET_EXCEPTION) {
    e = target->exc;
  } else if (op == VX_STATE_GET_REGS) {
    arch_frame_regs(arch_user_frame(target), &e.regs);
  } else {
    st = arch_frame_set_regs(arch_user_frame(target), &regs);
  }
  spin_unlock(&tt->lock);
  object_release(&target->obj);
  if (st != VX_OK || op == VX_STATE_SET_REGS) return st;
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
    if (target) {
      target->interrupt_pending = true;
      target->interrupt_value = value;
      object_ref(&target->obj);
    } else {
      st = VX_ERR_NOT_FOUND;
    }
  }
  spin_unlock(&t->lock);
  object_release(&t->obj);
  if (!target) return st;
  sched_kick(target, VX_ERR_INTERRUPTED);
  object_release(&target->obj);
  return VX_OK;
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
