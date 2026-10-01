// sched.c: the v1 scheduler (docs/01 §8). Every CPU serves one shared ready
// queue round robin; each CPU keeps the threads that blocked on it, with a
// deadline, in its own sleep queue, and runs a user thread for at most a 10 ms
// slice while others wait. One lock covers all of it. Per-CPU ready queues,
// intents, priority bands and the realtime class come after M1.
//
// The kernel runs with interrupts off. They are on only in user mode and in an
// idle thread's wait. A CPU with nothing to run sleeps with no timer armed unless
// a sleeper needs one; a thread made ready while it sleeps reaches it as a
// reschedule interrupt (arch_send_resched).
//
// The lock is held across a context switch and released by whichever thread runs
// next, so a thread queued by one CPU cannot be picked up by another before its
// registers are saved.

static constexpr vx_duration TIME_SLICE = 10'000'000;

typedef struct cpu {
  uint32_t index;   // 0 is the boot CPU
  uint64_t arch_id; // local APIC ID, or MPIDR affinity
  thread *current;
  thread idle;      // runs when nothing else can; the boot context on CPU 0
  thread *sleepers; // blocked here with a deadline, earliest first
  vx_instant slice_end;
  bool resched;        // call schedule before returning to user mode
  thread *reap;        // a thread that died here, for whoever runs next to free
  uint64_t idle_stack; // direct-map address of the idle stack's base (not CPU 0)
} cpu;

static cpu cpus[MAX_CPUS];
static uint32_t cpu_total;           // CPUs the bootloader reported
static _Atomic uint32_t cpus_online; // CPUs that reached their idle loop

static struct {
  spinlock lock;
  thread *run_head, *run_tail;
  uint64_t idle_mask; // bit i: CPU i is running its idle thread
} sched;

static cpu *this_cpu(void) { return &cpus[arch_cpu_index()]; }

static void sched_arm_timer(cpu *c);
static void thread_reap(thread *t); // obj/process.c

// Run after every switch, by the thread switched to: free the thread that died
// on this CPU just before. It could not free the stack it was running on.
static void reap_after_switch(void) {
  cpu *c = this_cpu();
  thread *dead = c->reap;
  c->reap = nullptr;
  spin_unlock(&sched.lock);
  if (dead) thread_reap(dead);
}

static void run_enqueue(thread *t) {
  t->state = THREAD_READY;
  t->next = nullptr;
  if (sched.run_tail)
    sched.run_tail->next = t;
  else
    sched.run_head = t;
  sched.run_tail = t;
}

static thread *run_dequeue(void) {
  thread *t = sched.run_head;
  if (t) {
    sched.run_head = t->next;
    if (!sched.run_head) sched.run_tail = nullptr;
    t->next = nullptr;
  }
  return t;
}

static void sleep_remove(thread *t) {
  if (!t->sleep_cpu) return;
  for (thread **link = &t->sleep_cpu->sleepers; *link; link = &(*link)->sleep_next) {
    if (*link == t) {
      *link = t->sleep_next;
      break;
    }
  }
  t->sleep_next = nullptr;
  t->sleep_cpu = nullptr;
}

// Makes a blocked thread ready, and gets a CPU to it: this one if it is idle,
// otherwise an idle one, by interrupt. With none idle, the next slice to end
// picks it up. Called with the lock held.
static void make_ready(thread *t) {
  sleep_remove(t);
  run_enqueue(t);
  cpu *self = this_cpu();
  if (sched.idle_mask & (1ull << self->index)) {
    self->resched = true;
    return;
  }
  for (uint32_t i = 0; i < cpu_total; i++) {
    if (sched.idle_mask & (1ull << i)) {
      sched.idle_mask &= ~(1ull << i); // one interrupt per wake is enough
      arch_send_resched(&cpus[i]);
      return;
    }
  }
}

// Switches to the next ready thread, or to this CPU's idle thread. Called with
// the lock held; returns, with it released, when the current thread runs again.
// A running thread goes back on the queue; a blocked or dead one does not.
static void schedule_locked(void) {
  cpu *c = this_cpu();
  thread *prev = c->current;
  if (prev->state == THREAD_RUNNING && prev != &c->idle) run_enqueue(prev);
  thread *next = run_dequeue();
  if (!next) next = &c->idle;
  c->resched = false;
  if (next == &c->idle) {
    sched.idle_mask |= 1ull << c->index;
  } else {
    sched.idle_mask &= ~(1ull << c->index);
    c->slice_end = clock_now() + TIME_SLICE;
  }
  if (next != prev) {
    next->state = THREAD_RUNNING;
    next->cpu = c;
    c->current = next;
    if (next->task) arch_set_kernel_stack(thread_kstack_top(next));
    // Leave a task's address space even for the idle thread, so a dead task's
    // tables are on no CPU by the time its last thread is reaped.
    if (prev->task != next->task) {
      arch_switch_user_root(next->task ? next->task->root : 0);
      arch_io_switch(next->task);
    }
  } else {
    prev->state = THREAD_RUNNING;
  }
  sched_arm_timer(c);
  if (next == prev) {
    spin_unlock(&sched.lock);
    return;
  }
  arch_context_switch(&prev->kernel_sp, next->kernel_sp);
  reap_after_switch();
}

static void schedule(void) {
  spin_lock(&sched.lock);
  schedule_locked();
}

// A thread waits on a token: whatever it queued itself on, such as a port, a
// pending channel_call or a futex. It sets its token, joins that thing's list
// of waiters under the thing's own lock, and then blocks.

// Wakes t with `result` if it still waits on `token`, and not if it has stopped
// waiting (its deadline passed first, or it is being killed). A thread between
// joining a list and blocking keeps the wake for thread_block to find. Returns
// whether it woke.
static bool thread_wake_token(thread *t, const void *token, int64_t result) {
  spin_lock(&sched.lock);
  bool woke = token && t->wait_token == token;
  if (woke) {
    t->wait_token = nullptr;
    t->wait_result = result;
    if (t->state == THREAD_BLOCKED) {
      make_ready(t);
    } else {
      t->wake_pending = true;
    }
  }
  spin_unlock(&sched.lock);
  return woke;
}

// Blocks the current thread until it is woken, or until the deadline (plus up
// to `leeway`, which lets one timer interrupt serve several waits). Returns the
// wait's result: VX_ERR_TIMED_OUT if the deadline passed.
static int64_t thread_block(vx_instant deadline, vx_duration leeway) {
  cpu *c = this_cpu();
  thread *t = c->current;
  spin_lock(&sched.lock);
  if (t->wake_pending) { // woken before it got here
    t->wake_pending = false;
    spin_unlock(&sched.lock);
    return t->wait_result;
  }
  t->state = THREAD_BLOCKED;
  if (deadline != VX_INFINITE) {
    t->wake_at = deadline;
    t->wake_late = leeway > 0 && deadline <= VX_INFINITE - leeway ? deadline + leeway : deadline;
    t->sleep_cpu = c;
    thread **link = &c->sleepers;
    while (*link && (*link)->wake_at <= deadline) link = &(*link)->sleep_next;
    t->sleep_next = *link;
    *link = t;
  }
  schedule_locked();
  return t->wait_result;
}

// Arms this CPU's timer for the next thing that needs it: its earliest
// sleeper's latest acceptable wake-up, or the end of the running thread's slice.
static void sched_arm_timer(cpu *c) {
  vx_instant next = VX_INFINITE;
  for (thread *t = c->sleepers; t; t = t->sleep_next)
    if (t->wake_late < next) next = t->wake_late;
  if (c->current != &c->idle && c->slice_end < next) next = c->slice_end;
  if (next != VX_INFINITE) timer_arm(next);
}

// This CPU's timer fired (time.c): wake its sleepers whose deadlines have passed,
// and end the slice if others are waiting.
static void sched_timer(void) {
  cpu *c = this_cpu();
  if (!c->current) return; // before the scheduler runs on this CPU
  spin_lock(&sched.lock);
  vx_instant now = clock_now();
  while (c->sleepers && c->sleepers->wake_at <= now) {
    thread *t = c->sleepers;
    t->wait_token = nullptr; // a waker that finds it later skips it
    t->wait_result = VX_ERR_TIMED_OUT;
    make_ready(t);
  }
  if (now >= c->slice_end) {
    // The slice is over: switch if someone is waiting, else give the running
    // thread another one. (Re-arming the old, expired end would fire at once,
    // forever, and the thread would never get back to user mode.)
    if (sched.run_head)
      c->resched = true;
    else
      c->slice_end = now + TIME_SLICE;
  }
  sched_arm_timer(c);
  spin_unlock(&sched.lock);
}

// A CPU's idle loop: run whatever is ready, else sleep until an interrupt.
[[noreturn]] static void sched_idle_loop(void) {
  cpu *c = this_cpu();
  for (;;) {
    schedule();
    if (!c->resched) arch_wait();
  }
}

// Makes the calling context this CPU's idle thread.
static void sched_enter_cpu(void) {
  cpu *c = this_cpu();
  c->idle.state = THREAD_RUNNING;
  c->current = &c->idle;
}

static void sched_start_thread(thread *t) {
  spin_lock(&sched.lock);
  make_ready(t);
  spin_unlock(&sched.lock);
}

// The first time a thread runs, arch_context_switch returns into the
// architecture's trampoline, which calls this with the lock still held from the
// switch. It never returns: it enters user mode.
[[noreturn]] void thread_entry(thread *t) {
  reap_after_switch();
  arch_enter_user(t->user_entry, t->user_sp, t->user_arg, t->user_arg2, thread_kstack_top(t));
}

// Starts the report of a fault that kills the current thread:
// "vx: task 1 (svcd) killed: " and whatever the caller adds.
static void task_fault_start(void) {
  task *t = this_cpu()->current->task;
  kput(VX_STR("vx: task "));
  kput_u64(t->id);
  kput(VX_STR(" ("));
  kput_cstr(t->name);
  kput(VX_STR(") killed: "));
}

// Ends the current thread: it is never scheduled again, and the next thread to
// run on this CPU reaps it. The caller has already accounted for it in its task
// (obj/process.c).
[[noreturn]] static void sched_exit_current(void) {
  spin_lock(&sched.lock);
  cpu *c = this_cpu();
  c->current->state = THREAD_DEAD;
  c->reap = c->current;
  schedule_locked();
  panic(VX_STR("a dead thread was scheduled"));
}

// Gets a thread of a task being killed to notice (obj/process.c): a blocked
// thread wakes with ERR_KILLED, wherever it waits; one running user code on
// another CPU gets an interrupt, and checks on its way back to user mode.
static void sched_kick_for_kill(thread *t) {
  spin_lock(&sched.lock);
  if (t->state == THREAD_BLOCKED) {
    t->wait_token = nullptr;
    t->wait_result = VX_ERR_KILLED;
    make_ready(t);
  } else if (t->state != THREAD_DEAD) {
    // Ready, or running here or elsewhere: if it is about to block, the block
    // returns at once; if it is in user mode on another CPU, interrupt it.
    t->wake_pending = true;
    t->wait_result = VX_ERR_KILLED;
    if (t->state == THREAD_RUNNING && t->cpu && t->cpu != this_cpu()) arch_send_resched(t->cpu);
  }
  spin_unlock(&sched.lock);
}
