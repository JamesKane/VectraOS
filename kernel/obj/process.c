// process.c: how threads and tasks start, end and are killed (docs/01 §2).
//
// A task runs while it has live threads. When the last one exits, or the task
// is killed, the task is EXITED: its handles are closed, its mappings dropped
// and its page tables freed, and its EXIT bindings fire with its exit status.
// The task object itself lives on while anything holds a handle to it, so its
// status can still be read.
//
// A thread cannot free the kernel stack it runs on, so a dead thread is reaped
// by the next thread to run on its CPU (sched.c), and the teardown of a task
// whose last thread died happens there too. By then that CPU has left the task's
// address space, as every CPU that ran its threads already has.
//
// Killing marks the task and kicks its threads (sched_kick). Each one
// exits the next time it heads back to user mode (user_return).

static constexpr int64_t EXIT_FAULT = -1; // the status of a task killed by a fault

static vx_status task_bind(task *t, binding *b) {
  if (b->trigger != VX_TRIGGER_EXIT) return VX_ERR_INVALID;
  spin_lock(&t->lock);
  if (t->state == VX_TASK_EXITED)
    binding_fire(b, (uint64_t)t->exit_status);
  else
    observers_add(&t->obs, b);
  spin_unlock(&t->lock);
  return VX_OK;
}

// Closes the task's handles, drops its mappings, frees its page tables and fires
// its EXIT bindings. Its threads are all dead and no CPU uses its address space.
static void task_teardown(task *t) {
  // The tables leave the task under its lock, so a handle_add or task_map on
  // another CPU (through a handle to this task) sees them gone, never freed.
  spin_lock(&t->lock);
  handle_entry *handles = t->handles;
  mapping *maps = t->maps;
  uint64_t root = t->root;
  struct port *exc_port = t->exc_port, *dbg_port = t->dbg_port;
  t->exc_port = t->dbg_port = nullptr;
  t->exc_handler = 0;
  t->handles = nullptr;
  t->maps = nullptr;
  t->root = 0;
  t->mapped = 0;
  spin_unlock(&t->lock);
  if (exc_port) object_drop((object *)exc_port);
  if (dbg_port) object_drop((object *)dbg_port);
  for (uint32_t i = 1; i < HANDLE_SLOTS; i++)
    if (handles[i].obj) object_drop(handles[i].obj);
  for (uint32_t i = 0; i < TASK_MAX_MAPPINGS; i++)
    if (maps[i].size) object_drop(&maps[i].vmo->obj);
  free_user_tables(root);
  phys_free((uint64_t)maps - boot.hhdm, 0);
  phys_free((uint64_t)handles - boot.hhdm, 0);
  spin_lock(&t->lock);
  t->state = VX_TASK_EXITED; // only now: an EXIT binding sees the task fully gone
  observers_fire(&t->obs, VX_TRIGGER_EXIT, (uint64_t)t->exit_status);
  spin_unlock(&t->lock);
}

// Starts a thread that has not started: user mode at entry, with sp and two
// arguments. The thread holds a reference to itself until it is reaped.
static vx_status thread_start(thread *th, uint64_t entry, uint64_t sp, uint64_t arg, uint64_t arg2) {
  // Both in the lower half: a non-canonical address would fault on the way
  // to user mode, in the kernel (x86_64's iretq), not in the task.
  if (entry >= USER_TOP || sp > USER_TOP) return VX_ERR_INVALID;
  task *t = th->task;
  spin_lock(&t->lock);
  vx_status st = VX_OK;
  if (th->state != THREAD_NEW || th->started || t->ending || t->killed) st = VX_ERR_BAD_STATE;

  if (st == VX_OK) {
    th->started = true; // under the task's lock: one start, even with entry 0
    th->user_entry = entry;
    th->user_sp = sp;
    th->user_arg = arg;
    th->user_arg2 = arg2;
    t->live_threads++;
    t->state = VX_TASK_RUNNING;
    th->task_next = t->threads;
    t->threads = th;
    object_ref(&th->obj);
  }
  spin_unlock(&t->lock);
  if (st == VX_OK) sched_start_thread(th);
  return st;
}

// Ends the current thread with an exit status; the last thread's status, or a
// kill's, becomes the task's.
[[noreturn]] static void thread_exit_current(int64_t status) {
  thread *th = this_cpu()->current;
  task *t = th->task;
  spin_lock(&t->lock);
  if (!t->killed && t->live_threads == 1) t->exit_status = status;
  th->last_of_task = --t->live_threads == 0;
  if (th->last_of_task) t->ending = true;
  spin_unlock(&t->lock);
  sched_exit_current();
}

// A dead thread's last rites, run by the next thread on its CPU (sched.c).
static void thread_reap(thread *th) {
  kstack_free(th->kstack);
  th->kstack = 0;
  task *t = th->task;
  spin_lock(&t->lock);
  for (thread **link = &t->threads; *link; link = &(*link)->task_next) {
    if (*link == th) {
      *link = th->task_next;
      break;
    }
  }
  spin_unlock(&t->lock);
  if (th->last_of_task) task_teardown(t);
  object_release(&th->obj); // the reference it held while running
}

// Kills a task: its exit status is `status`, and its threads exit when they
// next head for user mode. A task with no live threads ends at once.
static void task_kill(task *t, int64_t status) {
  spin_lock(&t->lock);
  if (t->ending || t->killed) {
    spin_unlock(&t->lock);
    return;
  }
  t->killed = true;
  t->exit_status = status;
  bool idle = t->live_threads == 0;
  if (idle) t->ending = true;
  for (thread *th = t->threads; th; th = th->task_next) sched_kick(th, VX_ERR_KILLED);
  spin_unlock(&t->lock);
  if (idle) task_teardown(t);
}

// Every trap from user mode ends here before returning to it: a killed task's
// thread exits, and a pending reschedule happens.
static void exception_check_interrupt(void); // obj/exception.c
static bool exception_check_suspend(void);

static void user_return(void) {
  object_drain(); // what this trap dropped
  for (;;) {
    cpu *c = this_cpu();
    task *t = c->current->task;
    if (t->killed) thread_exit_current(t->exit_status);
    if (exception_check_suspend()) continue; // parked until resumed: look at the kill again
    if (!c->resched) break;
    schedule(); // and look again: a kill may have come meanwhile
  }
  exception_check_interrupt(); // a thread_interrupt, to its handler
}

// A fault in user mode kills the whole task (01 §9: until exception ports, no
// one else could handle it).
[[noreturn]] static void task_fault_exit(void) {
  task_kill(this_cpu()->current->task, EXIT_FAULT);
  thread_exit_current(EXIT_FAULT);
}

// The last reference is gone. Threads hold references to their task, so it
// either never started a thread or has already ended; one that never started
// still has its address space and handle table to give back.
static void task_destroy(task *t) {
  if (t->root) {
    t->ending = true;
    task_teardown(t);
  }
  observers_free(t->obs.head); // none can be left once the task has ended, but be sure
  task_unlist(t);
  pool_free(&task_pool, t);
}

static void thread_destroy(thread *th) {
  if (th->kstack) kstack_free(th->kstack); // never started
  task *t = th->task;
  pool_free(&thread_pool, th);
  object_drop(&t->obj);
}
