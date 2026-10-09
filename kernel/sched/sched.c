// sched.c: the v1 scheduler (docs/01 §8). Every CPU serves one shared ready
// queue, one band of it for each intent, highest first, round robin within a
// band; each CPU keeps the threads that blocked on it, with a deadline, in
// its own sleep queue, and runs a user thread for at most a 10 ms slice while
// others of its band wait. One lock covers all of it. Per-CPU ready queues
// come when measurements show the lock contended.
//
// Scheduling contexts (M6 step 6d6c, ADR-0038): a thread bound to one runs
// with its intent; a realtime one is a constant-bandwidth server, its budget
// charged for the time its threads run and, spent, its threads not run again
// until its next period fills it. Contexts are admitted or refused, at most
// 80% of the CPUs between them. A context's reserved CPUs run its threads
// bound to them and nothing else; one CPU, the first, is never reserved.
// A thread made ready in a band above one running preempts it.
//
// Donation (M6 step 6d6c2, 01 §4.5): a thread in channel_call lends its
// scheduling, its intent and its context, to the thread serving the call, as
// seL4 MCS does and as Zircon's channel calls make the port waiter they wake
// the owner of the caller's wait (object/channel_dispatcher.rs, write_self_
// locked's queue_to_own). The loan goes first to the port waiter the request
// wakes, then to the thread that reads it, and ends with the call; a thread
// runs on a loan only if it is above its own. The thread woken goes on the
// caller's CPU, which the caller is about to leave, and the reply's caller on
// the replier's: each switches straight to the other. Answered, the server
// keeps the loan until it next blocks, or its slice ends, so that it gets back
// to its wait for the next call: seL4's reply and receive are one call, ours
// two, and between them a server of a lower band would wait behind every
// thread above it.
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
// CPU time is sampled as 9front's is (ADR-0041): while a CPU runs a thread,
// not its idle one, a tick every 10 ms charges the thread a tick of user or
// system time, by where it found it. An idle CPU stays tickless (01 §8).
static constexpr vx_duration TICK = 10'000'000;

// The bands, highest first: realtime, interactive-frame, interactive,
// throughput, background (enum vx_intent's order).
static constexpr uint32_t BANDS = 5;

typedef struct sched_ctx {
  object obj;
  uint32_t intent;            // enum vx_intent
  vx_duration period, budget; // realtime's
  uint64_t ppm;               // its admitted share, in millionths of a CPU
  // Under the scheduler's lock:
  vx_duration left;          // of its budget, this period
  vx_instant period_end;     // when it is filled again
  bool throttled;            // spent: its threads wait for period_end
  uint64_t exhausted;        // periods it ran out of budget in
  uint64_t reserved;         // the CPUs it reserved, by index
  struct sched_ctx *th_next; // on the list of throttled contexts
} sched_ctx;

static pool sched_ctx_pool = POOL_FOR(sched_ctx);

typedef struct cpu {
  uint32_t index;   // 0 is the boot CPU
  uint64_t arch_id; // local APIC ID, or MPIDR affinity
  thread *current;
  thread idle;      // runs when nothing else can; the boot context on CPU 0
  thread *sleepers; // blocked here with a deadline, earliest first
  vx_instant slice_end;
  vx_instant run_start; // when current began running, for charging its context
  vx_instant tick_at;   // the next CPU-time tick, while it runs a thread (ADR-0041)
  vx_instant sample_at; // the next sample, while it runs a thread and the trace samples (20 §6)
  sched_ctx *reserved;  // the context that reserved this CPU, or none
  bool resched;         // call schedule before returning to user mode
  thread *lending;      // a channel_call delivering its request: the port waiter it wakes is lent to
  thread *reap;         // a thread that died here, for whoever runs next to free
  uint64_t idle_stack;  // the idle stack's lowest address (mm/kstack.c)
  // Which task tables this CPU has loaded (0: none), and how many times it has
  // loaded tables: a shootdown waits only for CPUs that may cache the pages.
  _Atomic uint64_t user_root, root_loads;
  _Atomic uint64_t tlb_asked, tlb_done; // x86_64's shootdowns (arch.c)
} cpu;

static cpu cpus[MAX_CPUS];
static uint32_t cpu_total;           // CPUs the bootloader reported
static _Atomic uint32_t cpus_online; // CPUs that reached their idle loop

static struct {
  spinlock lock;
  thread *run_head[BANDS], *run_tail[BANDS];
  uint64_t idle_mask;    // bit i: CPU i is running its idle thread
  uint64_t admitted_ppm; // the realtime budgets admitted, in millionths of a CPU
  sched_ctx *throttled;  // contexts waiting for their next period
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

// A thread's own intent: its context's, or its own.
static uint32_t own_intent(const thread *t) { return t->ctx ? t->ctx->intent : t->intent; }

static uint32_t intent_band(uint32_t i) {
  return i >= VX_INTENT_REALTIME && i <= VX_INTENT_BACKGROUND ? i - VX_INTENT_REALTIME : 2;
}

// Loans go at most this deep: a server calling a server calling a server.
static constexpr int LEND_DEPTH = 8;

// The thread whose scheduling t runs on: itself, or the highest of the
// callers lending to it, along the chain, above its own.
static const thread *sched_source(const thread *t) {
  const thread *best = t;
  const thread *o = t->donor;
  for (int i = 0; i < LEND_DEPTH && o; i++, o = o->donor)
    if (intent_band(own_intent(o)) < intent_band(own_intent(best))) best = o;
  return best;
}

// A thread's intent: its own, or a loan's.
static uint32_t thread_intent(const thread *t) { return own_intent(sched_source(t)); }

// The context t's time is charged to: its own, or a loan's.
static sched_ctx *ctx_of(const thread *t) { return sched_source(t)->ctx; }

static uint32_t band_of(const thread *t) { return intent_band(thread_intent(t)); }

// The CPU a thread is bound to, if its context still reserves it; or -1.
static int32_t bound_cpu(const thread *t) {
  return t->core >= 0 && t->ctx && t->ctx->reserved >> t->core & 1 ? t->core : -1;
}

// Whether t may run on c now: a reserved CPU runs its context's threads bound
// to it alone, a bound thread runs there alone, and a spent context's
// threads wait for its next period.
static bool may_run(const thread *t, const cpu *c) {
  const sched_ctx *x = ctx_of(t);
  if (x && x->throttled) return false;
  int32_t b = bound_cpu(t);
  if (b >= 0) return (uint32_t)b == c->index;
  return !c->reserved;
}

static void run_enqueue(thread *t) {
  t->state = THREAD_READY;
  t->next = nullptr;
  uint32_t b = band_of(t);
  if (sched.run_tail[b])
    sched.run_tail[b]->next = t;
  else
    sched.run_head[b] = t;
  sched.run_tail[b] = t;
}

// Queues t first in its band: a hand-off, run next.
static void run_push(thread *t) {
  t->state = THREAD_READY;
  uint32_t b = band_of(t);
  t->next = sched.run_head[b];
  sched.run_head[b] = t;
  if (!sched.run_tail[b]) sched.run_tail[b] = t;
}

// The first ready thread of the highest band that may run on c, taken off the queue.
static thread *run_dequeue(const cpu *c) {
  for (uint32_t b = 0; b < BANDS; b++) {
    thread *prev = nullptr;
    for (thread *t = sched.run_head[b]; t; prev = t, t = t->next) {
      if (!may_run(t, c)) continue;
      *(prev ? &prev->next : &sched.run_head[b]) = t->next;
      if (sched.run_tail[b] == t) sched.run_tail[b] = prev;
      t->next = nullptr;
      return t;
    }
  }
  return nullptr;
}

// Whether a thread that may run on c waits in band b or above.
static bool ready_for(const cpu *c, uint32_t b) {
  for (uint32_t k = 0; k <= b && k < BANDS; k++)
    for (thread *t = sched.run_head[k]; t; t = t->next)
      if (may_run(t, c)) return true;
  return false;
}

// --- Budgets ---

// A spent context's threads may run again: off the throttled list.
static void unthrottle_locked(sched_ctx *x) {
  if (!x->throttled) return;
  x->throttled = false;
  for (sched_ctx **link = &sched.throttled; *link; link = &(*link)->th_next)
    if (*link == x) {
      *link = x->th_next;
      break;
    }
  x->th_next = nullptr;
}

// Gets this CPU and every idle one to look at the ready queue again: threads
// that could not run may now.
static void kick_idle(void) {
  this_cpu()->resched = true;
  for (uint32_t i = 0; i < cpu_total; i++)
    if (&cpus[i] != this_cpu() && (sched.idle_mask & (1ull << i))) arch_send_resched(&cpus[i]);
}

// A realtime context whose period has ended is filled again.
static void ctx_refill(sched_ctx *x, vx_instant now) {
  if (x->intent != VX_INTENT_REALTIME || now < x->period_end) return;
  x->left = x->budget;
  vx_instant next = x->period_end + x->period;
  x->period_end = next > now ? next : now + x->period; // far behind: from now
  unthrottle_locked(x);
}

// Charges c's running thread's context for the time since it last was; true
// if that spent its budget (the thread must stop).
static bool charge(cpu *c, vx_instant now) {
  thread *t = c->current;
  sched_ctx *x = t ? ctx_of(t) : nullptr;
  vx_duration ran = now - c->run_start;
  c->run_start = now;
  if (!x || x->intent != VX_INTENT_REALTIME || x->throttled) return false;
  ctx_refill(x, now);
  x->left -= ran;
  if (x->left > 0) return false;
  x->throttled = true;
  x->exhausted++;
  x->th_next = sched.throttled;
  sched.throttled = x;
  for (uint32_t i = 0; i < cpu_total; i++) // its threads on other CPUs stop too
    if (&cpus[i] != c && cpus[i].current && ctx_of(cpus[i].current) == x) arch_send_resched(&cpus[i]);
  return true;
}

// Fills the throttled contexts whose periods have ended: their threads may run
// again, on any CPU that will take them.
static void refill_due(vx_instant now) {
  bool any = false;
  for (sched_ctx *x = sched.throttled, *next; x; x = next) {
    next = x->th_next;
    if (now >= x->period_end) ctx_refill(x, now), any = true;
  }
  if (any) kick_idle();
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
static void kick_for(thread *t);

static void make_ready(thread *t) {
  sleep_remove(t);
  run_enqueue(t);
  kick_for(t);
}

// Makes t ready to run next here, where the current thread is about to block
// or to fall below it: a hand-off, if this CPU may run it; else as make_ready.
static void make_ready_here(thread *t) {
  cpu *self = this_cpu();
  if (!may_run(t, self) || (self->current != &self->idle && band_of(self->current) < band_of(t))) {
    make_ready(t);
    return;
  }
  sleep_remove(t);
  run_push(t);
  self->resched = true;
}

// Gets a CPU to a thread just queued: this one if it is idle and may run it,
// else an idle one that may, by interrupt, else the one running the lowest
// band below the thread's that may run it there. With none, the next slice
// to end picks it up.
static void kick_for(thread *t) {
  cpu *self = this_cpu();
  if ((sched.idle_mask & (1ull << self->index)) && may_run(t, self)) {
    self->resched = true;
    return;
  }
  for (uint32_t i = 0; i < cpu_total; i++) {
    if ((sched.idle_mask & (1ull << i)) && may_run(t, &cpus[i])) {
      sched.idle_mask &= ~(1ull << i); // one interrupt per wake is enough
      arch_send_resched(&cpus[i]);
      return;
    }
  }
  // None idle: the CPU running the lowest band below t's, if it may run t there.
  uint32_t b = band_of(t), worst = b;
  cpu *victim = nullptr;
  for (uint32_t i = 0; i < cpu_total; i++) {
    cpu *c = &cpus[i];
    if (!c->current || c->current == &c->idle || !may_run(t, c)) continue;
    uint32_t cb = band_of(c->current);
    if (cb > worst) worst = cb, victim = c;
  }
  if (!victim) return; // the next slice to end picks it up
  if (victim == self)
    self->resched = true;
  else
    arch_send_resched(victim);
}

// --- Scheduling contexts (ADR-0038) ---

static constexpr vx_duration RT_MIN_PERIOD = 1'000'000, RT_MAX_PERIOD = 10'000'000'000,
                             RT_MIN_BUDGET = 100'000;
static constexpr uint64_t RT_LIMIT_PPM = 800'000; // of each CPU online

static vx_status params_check(const vx_sched_params *p, bool own) {
  if (p->flags || p->intent < VX_INTENT_REALTIME || p->intent > VX_INTENT_BACKGROUND) return VX_ERR_INVALID;
  if (p->intent != VX_INTENT_REALTIME) return p->period || p->budget ? VX_ERR_INVALID : VX_OK;
  if (own) return VX_ERR_INVALID; // a thread's own intent is never realtime: that needs a context
  if (p->period < RT_MIN_PERIOD || p->period > RT_MAX_PERIOD || p->budget < RT_MIN_BUDGET ||
      p->budget > p->period)
    return VX_ERR_INVALID;
  return VX_OK;
}

static uint64_t params_ppm(const vx_sched_params *p) {
  if (p->intent != VX_INTENT_REALTIME) return 0;
  return (uint64_t)p->budget * 1'000'000 / (uint64_t)p->period; // at most 1e16: no overflow
}

// Admits a share of `ppm`, given back `old` it had: false if they do not fit.
// Under the scheduler's lock.
static bool admit(uint64_t ppm, uint64_t old) {
  uint64_t limit = RT_LIMIT_PPM * atomic_load_explicit(&cpus_online, memory_order_relaxed);
  return sched.admitted_ppm - old + ppm <= limit;
}

static void ctx_apply(sched_ctx *x, const vx_sched_params *p, uint64_t ppm, vx_instant now) {
  x->intent = p->intent, x->period = p->period, x->budget = p->budget, x->ppm = ppm;
  x->left = p->budget, x->period_end = now + p->period;
}

static vx_status sched_ctx_new(const vx_sched_params *p, sched_ctx **out) {
  vx_status st = params_check(p, false);
  if (st != VX_OK) return st;
  sched_ctx *x = pool_alloc(&sched_ctx_pool);
  if (!x) return VX_ERR_NO_MEMORY;
  x->obj.type = OBJ_SCHED_CTX;
  atomic_store_explicit(&x->obj.refs, 1, memory_order_relaxed);
  uint64_t ppm = params_ppm(p);
  spin_lock(&sched.lock);
  bool fits = admit(ppm, 0);
  if (fits) sched.admitted_ppm += ppm, ctx_apply(x, p, ppm, clock_now());
  spin_unlock(&sched.lock);
  if (!fits) {
    pool_free(&sched_ctx_pool, x);
    return VX_ERR_REFUSED;
  }
  *out = x;
  return VX_OK;
}

// Gives back the CPUs x reserved: what ran there may run anywhere again.
static void unreserve_locked(sched_ctx *x) {
  for (uint32_t i = 0; i < cpu_total; i++)
    if (x->reserved >> i & 1) {
      cpus[i].reserved = nullptr;
      if (&cpus[i] != this_cpu()) arch_send_resched(&cpus[i]);
    }
  x->reserved = 0;
}

static void sched_ctx_destroy(sched_ctx *x) { // its last handle and its last bound thread gone
  spin_lock(&sched.lock);
  sched.admitted_ppm -= x->ppm;
  unreserve_locked(x);
  for (sched_ctx **link = &sched.throttled; *link; link = &(*link)->th_next)
    if (*link == x) {
      *link = x->th_next;
      break;
    }
  spin_unlock(&sched.lock);
  pool_free(&sched_ctx_pool, x);
}

static vx_status sched_ctx_set(sched_ctx *x, const vx_sched_params *p) {
  vx_status st = params_check(p, false);
  if (st != VX_OK) return st;
  uint64_t ppm = params_ppm(p);
  spin_lock(&sched.lock);
  bool fits = admit(ppm, x->ppm);
  if (fits) {
    sched.admitted_ppm = sched.admitted_ppm - x->ppm + ppm;
    bool was = x->throttled;
    ctx_apply(x, p, ppm, clock_now()); // filled, whatever its intent now
    // Spent, it is let go at once: a refill would fill only a realtime one,
    // and one reconfigured to another intent stayed throttled for ever (the
    // Odin port's finding).
    if (was) unthrottle_locked(x), kick_idle();
  }
  spin_unlock(&sched.lock);
  return fits ? VX_OK : VX_ERR_REFUSED;
}

// The calling thread's own intent (vx_intent_set): anything but realtime.
static vx_status sched_set_own(thread *t, const vx_sched_params *p) {
  vx_status st = params_check(p, true);
  if (st != VX_OK) return st;
  spin_lock(&sched.lock);
  t->intent = p->intent;
  spin_unlock(&sched.lock);
  return VX_OK;
}

// Binds t to x (none: unbinds it), on a CPU of x's reservation or none (-1).
// The thread holds a reference to its context while bound.
static vx_status sched_bind(thread *t, sched_ctx *x, int32_t core) {
  if (core >= 0 && (!x || core >= (int32_t)cpu_total)) return VX_ERR_INVALID;
  if (x) object_ref(&x->obj);
  spin_lock(&sched.lock);
  if (core >= 0 && !(x->reserved >> core & 1)) {
    spin_unlock(&sched.lock);
    object_release(&x->obj);
    return VX_ERR_INVALID; // not a CPU it reserved
  }
  sched_ctx *old = t->ctx;
  t->ctx = x, t->core = core;
  // A thread bound elsewhere moves: on its next switch, or now if it runs here.
  if (t->state == THREAD_RUNNING && t->cpu && !may_run(t, t->cpu)) {
    if (t->cpu == this_cpu())
      t->cpu->resched = true;
    else
      arch_send_resched(t->cpu);
  }
  spin_unlock(&sched.lock);
  if (old) object_release(&old->obj);
  return VX_OK;
}

// A dying thread's context, taken from it: its caller drops the reference
// (object_drop in a destructor, object_release elsewhere).
static sched_ctx *sched_unbind_dead(thread *t) {
  spin_lock(&sched.lock);
  sched_ctx *x = t->ctx;
  t->ctx = nullptr, t->core = -1;
  spin_unlock(&sched.lock);
  return x;
}

// Reserves `count` whole CPUs for x, or with 0 gives back its own: all or
// REFUSED. The first CPU is never reserved; nor is one another context has.
static vx_status sched_reserve_cpus(sched_ctx *x, uint32_t count, vx_core_set *out) {
  spin_lock(&sched.lock);
  unreserve_locked(x);
  uint64_t got = 0;
  uint32_t n = 0, online = atomic_load_explicit(&cpus_online, memory_order_relaxed);
  for (uint32_t i = online; i-- > 1 && n < count;) // from the last, keeping the first shared
    if (!cpus[i].reserved) got |= 1ull << i, n++;
  if (n < count) {
    spin_unlock(&sched.lock);
    *out = (vx_core_set){};
    return VX_ERR_REFUSED;
  }
  x->reserved = got;
  for (uint32_t i = 0; i < cpu_total; i++)
    if (got >> i & 1) {
      cpus[i].reserved = x;
      if (&cpus[i] == this_cpu())
        cpus[i].resched = true;
      else
        arch_send_resched(&cpus[i]); // what runs there leaves
    }
  spin_unlock(&sched.lock);
  *out = (vx_core_set){.mask = got, .count = n};
  return VX_OK;
}

// GET_CPU's counts (ADR-0045): the CPUs online, those reserved, and of them
// the ones t's process may run on: the unreserved, and its context's own.
static void sched_cpus(const thread *t, vx_cpu_info *info) {
  spin_lock(&sched.lock);
  uint32_t online = atomic_load_explicit(&cpus_online, memory_order_relaxed);
  uint64_t reserved = 0;
  for (uint32_t i = 0; i < online; i++)
    if (cpus[i].reserved) reserved |= 1ull << i;
  uint64_t own = t->ctx ? t->ctx->reserved : 0;
  spin_unlock(&sched.lock);
  uint64_t all = online >= 64 ? ~0ull : (1ull << online) - 1;
  info->cpus_online = online;
  info->cpus_reserved = reserved;
  info->cpus_usable = (uint32_t)__builtin_popcountll((all & ~reserved) | (own & all));
}

// What /proc/N/threads/T/sched shows (thread_state GET_SCHED).
static void sched_info(const thread *t, vx_sched_info *out) {
  spin_lock(&sched.lock);
  const thread *from = sched_source(t);
  const sched_ctx *x = from->ctx; // what it runs on: its own, or a loan's
  *out = (vx_sched_info){.intent = thread_intent(t),
                         .core = bound_cpu(t),
                         .bound = t->ctx != nullptr,
                         .period = x ? x->period : 0,
                         .budget = x ? x->budget : 0,
                         .exhausted = x ? x->exhausted : 0,
                         .reserved = t->ctx ? t->ctx->reserved : 0};
  if (x && x->intent == VX_INTENT_REALTIME && x->left > 0) out->left = x->left;
  if (from != t) out->lent_task = from->task ? from->task->id : 0, out->lent_thread = from->id;
  out->reserved_count = (uint32_t)__builtin_popcountll(out->reserved);
  spin_unlock(&sched.lock);
}

// --- Donation (6d6c2) ---

// Ends the loan t, a caller, made: its call is over. Under the lock.
static void unlend_locked(thread *t) {
  TRACE(VX_TC_IPC, VX_TK_RETURN, trace_tid(t), 0);
  if (!t->donee) return;
  if (t->donee->donor == t) t->donee->donor = nullptr, t->donee->lend_tail = false;
  t->donee = nullptr;
}

// Ends the loan t runs on, if its call was answered: t has blocked, or used
// its slice, since.
static void tail_end(thread *t) {
  if (!t->lend_tail) return;
  t->lend_tail = false;
  if (t->donor && t->donor->donee == t) t->donor->donee = nullptr;
  t->donor = nullptr;
}

// from, in channel_call, lends its scheduling to to, which serves its call:
// moved from where it was, and kept from to's loan if that is higher. Never
// in a loop: from lending to a thread lending, along its chain, to from.
static void lend_locked(thread *from, thread *to) {
  TRACE(VX_TC_IPC, VX_TK_DONATE, trace_tid(to), trace_tid(from));
  if (from == to || from->donee == to) return;
  unlend_locked(from);
  const thread *o = from->donor;
  for (int i = 0; i < LEND_DEPTH && o; i++, o = o->donor)
    if (o == to) return;
  if (to->donor) {
    if (band_of(to->donor) <= band_of(from)) return; // what it has is as high
    to->donor->donee = nullptr;
  }
  to->donor = from, from->donee = to, to->lend_tail = false;
}

// A thread's intent, as a channel message carries it: its loan chain read
// under the lock, as a donor ending its loan or dying changes it.
static uint32_t sched_thread_intent(const thread *t) {
  spin_lock(&sched.lock);
  uint32_t i = thread_intent(t);
  spin_unlock(&sched.lock);
  return i;
}

static void sched_lend(thread *from, thread *to) {
  spin_lock(&sched.lock);
  lend_locked(from, to);
  spin_unlock(&sched.lock);
}

// t's call is over. Unanswered, its loan ends; answered, the server keeps it
// as a tail until it blocks (tail_end), which a new call of t's, or t's end,
// cuts short.
static void sched_unlend(thread *t) {
  spin_lock(&sched.lock);
  if (!t->donee || t->donee->donor != t || !t->donee->lend_tail) unlend_locked(t);
  spin_unlock(&sched.lock);
}

// While a channel_call delivers its request: the port waiter it wakes is lent
// to (thread_wake_token). Under the channel's lock, interrupts off.
static void sched_lending(thread *caller) { this_cpu()->lending = caller; }

// Wakes a channel_call caller with its reply: its loan ended, and run next
// here, in the replier's place, if this CPU may.
static bool thread_wake_reply(thread *t, const void *token, int64_t result) {
  spin_lock(&sched.lock);
  if (t->donee && t->donee->donor == t) t->donee->lend_tail = true; // until it blocks
  bool woke = token && t->wait_token == token;
  if (woke) {
    t->wait_token = nullptr;
    TRACE(VX_TC_SCHED, VX_TK_WAKE, trace_tid(t), trace_tid(this_cpu()->current));
    if (t->state == THREAD_BLOCKED) {
      t->wait_result = result;
      make_ready_here(t);
    } else {
      t->pending_result = result;
      t->wake_pending = true;
    }
  }
  spin_unlock(&sched.lock);
  return woke;
}

// Switches to the next ready thread, or to this CPU's idle thread. Called with
// the lock held; returns, with it released, when the current thread runs again.
// A running thread goes back on the queue; a blocked or dead one does not.
static void schedule_locked(void) {
  cpu *c = this_cpu();
  thread *prev = c->current;
  vx_instant now = clock_now();
  if (prev != &c->idle) charge(c, now);
  if (prev->state == THREAD_RUNNING && prev != &c->idle) {
    run_enqueue(prev);
    if (!may_run(prev, c))
      kick_for(prev); // bound elsewhere since, or this CPU reserved: another must take it
  }
  thread *next = run_dequeue(c);
  if (!next) next = &c->idle;
  c->run_start = now;
  c->resched = false;
  if (next == &c->idle) {
    sched.idle_mask |= 1ull << c->index;
  } else {
    sched.idle_mask &= ~(1ull << c->index);
    c->slice_end = now + TIME_SLICE;
    if (c->tick_at <= now) c->tick_at = now + TICK; // leaving idle: ticks start again
    if (c->sample_at <= now) c->sample_at = now + (vx_instant)atomic_load(&trace_sample_ns); // samples too
    if (ctx_of(next)) ctx_refill(ctx_of(next), now);
  }
  if (next != prev) {
    TRACE(VX_TC_SCHED, VX_TK_SWITCH, trace_tid(prev) | (uint64_t)prev->state << 32, trace_tid(next));
    arch_user_switch(prev, next);
    next->state = THREAD_RUNNING;
    next->cpu = c;
    c->current = next;
    if (next->task) arch_set_kernel_stack(thread_kstack_top(next));
    // Leave a task's address space even for the idle thread, so a dead task's
    // tables are on no CPU by the time its last thread is reaped.
    if (prev->task != next->task) {
      uint64_t root = next->task ? next->task->root : 0;
      atomic_store_explicit(&c->user_root, root, memory_order_relaxed);
      arch_switch_user_root(root);
      atomic_fetch_add_explicit(&c->root_loads, 1, memory_order_release);
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
    TRACE(VX_TC_SCHED, VX_TK_WAKE, trace_tid(t), trace_tid(this_cpu()->current));
    thread *caller = this_cpu()->lending;
    if (caller) lend_locked(caller, t), this_cpu()->lending = nullptr; // the first woken serves the call
    if (t->state == THREAD_BLOCKED) {
      t->wait_result = result;
      if (caller && t->donor == caller)
        make_ready_here(t); // the caller is about to block: run the server in its place
      else
        make_ready(t);
    } else {
      t->pending_result = result; // for its block, which returns at once
      t->wake_pending = true;
    }
  }
  spin_unlock(&sched.lock);
  return woke;
}

// Blocks the current thread until it is woken, or until the deadline (plus up
// to `leeway`, which lets one timer interrupt serve several waits). Returns the
// wait's result: VX_ERR_TIMED_OUT if the deadline passed.
static int64_t thread_block(uint32_t reason, uint64_t obj, vx_instant deadline, vx_duration leeway) {
  cpu *c = this_cpu();
  thread *t = c->current;
  spin_lock(&sched.lock);
  if (t->wake_pending) { // woken before it got here
    t->wake_pending = false;
    t->wait_result = t->pending_result;
    // This wait is over: a waker that comes later (a channel reply before
    // the caller has left the list) must not end the next one, which may
    // use the same token, a record at the same place on this stack.
    t->wait_token = nullptr;
    spin_unlock(&sched.lock);
    return t->wait_result;
  }
  tail_end(t); // an answered call's loan ends as its server waits again
  TRACE(VX_TC_SCHED, VX_TK_BLOCK, reason, obj);
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

// vx.hangdump=N (a debugging aid): N seconds after boot, CPU 0 prints every
// thread: its state, what it waits on, where it is in user mode, and the
// kernel stack it is blocked on.
static vx_instant hangdump_at = -1; // -1: the command line not read yet
static _Atomic bool hangdump_done;

static void hang_dump(void) {
  kput(VX_STR("vx: hangdump\n"));
  spin_lock(&all_tasks_lock);
  for (task *t = all_tasks; t; t = t->all_next) {
    for (thread *th = t->threads; th; th = th->task_next) {
      kput(VX_STR("  task "));
      kput_u64(t->id);
      kput(VX_STR(" ("));
      kput_cstr(t->name);
      kput(VX_STR(") thread "));
      kput_u64(th->id);
      kput(VX_STR(" state "));
      kput_u64(th->state);
      kput(VX_STR(" token "));
      kput_hex((uint64_t)th->wait_token);
      kput(VX_STR(" pending "));
      kput_u64(th->wake_pending);
      kput(VX_STR(" suspend "));
      kput_u64(th->suspend_count);
      vx_regs r;
      arch_frame_regs(arch_user_frame(th), &r);
#ifdef __aarch64__
      kput(VX_STR(" pc "));
      kput_hex(r.pc);
      kput(VX_STR("\n"));
      if (th->state == THREAD_BLOCKED) {
        const uint64_t *saved = (const uint64_t *)th->kernel_sp; // arch_context_switch's frame
        backtrace(saved[11], saved[10]);
      }
#else
      kput(VX_STR(" pc "));
      kput_hex(r.rip);
      kput(VX_STR("\n"));
#endif
    }
  }
  spin_unlock(&all_tasks_lock);
}

// Arms this CPU's timer for the next thing that needs it: its earliest
// sleeper's latest acceptable wake-up, or the end of the running thread's slice.
static void sched_arm_timer(cpu *c) {
  vx_instant next = VX_INFINITE;
  for (thread *t = c->sleepers; t; t = t->sleep_next)
    if (t->wake_late < next) next = t->wake_late;
  if (c->current != &c->idle && c->slice_end < next) next = c->slice_end;
  if (c->current != &c->idle && c->tick_at < next) next = c->tick_at;
  if (c->current != &c->idle && (atomic_load_explicit(&trace_mask, memory_order_relaxed) & VX_TC_SAMPLE) &&
      c->sample_at < next)
    next = c->sample_at;
  const sched_ctx *x = c->current ? ctx_of(c->current) : nullptr;
  if (c->current != &c->idle && x && x->intent == VX_INTENT_REALTIME && !x->throttled &&
      c->run_start + x->left < next)
    next = c->run_start + x->left; // its budget runs out
  for (const sched_ctx *t = sched.throttled; t; t = t->th_next)
    if (t->period_end < next) next = t->period_end; // a spent context fills again
  if (hangdump_at < 0) {
    uint64_t s = 0;
    vx_str v = cmdline_value(VX_STR("vx.hangdump"));
    for (size_t i = 0; i < v.len && v.ptr[i] >= '0' && v.ptr[i] <= '9'; i++)
      s = s * 10 + (uint64_t)(v.ptr[i] - '0');
    hangdump_at = s ? (vx_instant)(s * 1'000'000'000) : VX_INFINITE;
  }
  if (c->index == 0 && !hangdump_done && hangdump_at < next) next = hangdump_at;
  if (next != VX_INFINITE) timer_arm(next);
}

// This CPU's timer fired (time.c): wake its sleepers whose deadlines have passed,
// and end the slice if others are waiting.
static void sched_timer(bool from_user, uint64_t pc, uint64_t fp) {
  cpu *c = this_cpu();
  if (!c->current) return; // before the scheduler runs on this CPU
  spin_lock(&sched.lock);
  vx_instant now = clock_now();
  TRACE(VX_TC_IRQ, VX_TK_TIMER, now, 0);
  if (c->current != &c->idle && now >= c->tick_at) { // the ticks due, all to where it was found
    uint64_t n = 1 + (uint64_t)((now - c->tick_at) / TICK);
    atomic_fetch_add_explicit(&c->current->ticks[from_user ? 0 : 1], n, memory_order_relaxed);
    c->tick_at += (vx_instant)(n * TICK);
  }
  if (c->current != &c->idle && now >= c->sample_at &&
      (atomic_load_explicit(&trace_mask, memory_order_relaxed) & VX_TC_SAMPLE)) {
    trace_sample(from_user, pc, fp); // what it was doing: one sample, however late
    c->sample_at = now + (vx_instant)atomic_load_explicit(&trace_sample_ns, memory_order_relaxed);
  }
  while (c->sleepers && c->sleepers->wake_at <= now) {
    thread *t = c->sleepers;
    t->wait_token = nullptr; // a waker that finds it later skips it
    t->wait_result = VX_ERR_TIMED_OUT;
    TRACE(VX_TC_SCHED, VX_TK_WAKE, trace_tid(t), 0); // its deadline: no waker
    make_ready(t);
  }
  refill_due(now);
  if (c->current != &c->idle && charge(c, now)) c->resched = true; // its context's budget is spent
  if (now >= c->slice_end) {
    // The slice is over: switch if someone of its band or above is waiting,
    // else give the running thread another one. (Re-arming the old, expired
    // end would fire at once, forever, and the thread would never get back to
    // user mode.)
    if (c->current != &c->idle && c->current->lend_tail) tail_end(c->current), c->resched = true;
    if (c->current == &c->idle || ready_for(c, band_of(c->current)))
      c->resched = true;
    else
      c->slice_end = now + TIME_SLICE;
  }
  // A thread running on a CPU reserved since, or on one it may run on no more, leaves it.
  if (c->current != &c->idle && !may_run(c->current, c)) c->resched = true;
  bool dump = c->index == 0 && !hangdump_done && now >= hangdump_at;
  if (dump) hangdump_done = true;
  sched_arm_timer(c);
  spin_unlock(&sched.lock);
  if (dump) hang_dump();
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

[[noreturn]] static void thread_exit_current(void); // obj/process.c

// The first time a thread runs, arch_context_switch returns into the
// architecture's trampoline, which calls this with the lock still held from the
// switch. It never returns: it enters user mode. One suspended before it ever
// ran parks on its first way back to the kernel, its user registers in place
// (thread_suspend pokes it until it does); one whose task was killed
// meanwhile ends here.
[[noreturn]] void thread_entry(thread *t) {
  reap_after_switch();
  if (t->task->killed) thread_exit_current();
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
  unlend_locked(c->current);
  c->current->lend_tail = true, tail_end(c->current); // and any loan it runs on
  c->current->state = THREAD_DEAD;
  c->reap = c->current;
  schedule_locked();
  panic(VX_STR("a dead thread was scheduled"));
}

// Gets a thread to notice a kill (obj/process.c) or an interrupt
// (obj/exception.c): a blocked thread wakes with `why`, wherever it waits; one
// running user code on another CPU gets an interrupt, and checks on its way
// back to user mode. A kill is never downgraded to an interrupt.
// Gets a thread running user code on another CPU into the kernel, to notice
// something on its way back (a suspension); a thread anywhere else needs nothing.
static void sched_poke(thread *t) {
  spin_lock(&sched.lock);
  if (t->state == THREAD_RUNNING && t->cpu && t->cpu != this_cpu()) arch_send_resched(t->cpu);
  spin_unlock(&sched.lock);
}

static void sched_kick(thread *t, vx_status why) {
  spin_lock(&sched.lock);
  if (t->wake_pending && t->pending_result == VX_ERR_KILLED) why = VX_ERR_KILLED; // a kill outranks the rest
  if (t->state == THREAD_BLOCKED) {
    t->wait_token = nullptr;
    t->wait_result = why;
    make_ready(t);
  } else if (t->state != THREAD_DEAD) {
    // Ready, or running here or elsewhere: if it is about to block, the block
    // returns at once; if it is in user mode on another CPU, interrupt it.
    // Its next block's result is pending_result, never wait_result: a wait
    // that has already ended (a reply handed to it, say) keeps its own. A
    // wake already pending with a result (thread_wake_token's, a packet
    // taken, a futex woken) stands, but against a kill: the waker counted it
    // as woken, and the interrupt is not lost, as the thread takes it on its
    // way back to user mode.
    if (!t->wake_pending || t->pending_result < 0 || why == VX_ERR_KILLED) t->pending_result = why;
    t->wake_pending = true;
    if (t->state == THREAD_RUNNING && t->cpu && t->cpu != this_cpu()) arch_send_resched(t->cpu);
  }
  spin_unlock(&sched.lock);
}
