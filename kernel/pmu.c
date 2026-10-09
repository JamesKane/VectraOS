// pmu.c: the hardware counters of a task's threads (ADR-0050, M7 step
// 7a3b), user mode only, as Linux's per-task perf counters are and not as
// Fuchsia's perfmon is (system-wide, per CPU: lib/perfmon/perfmon.h). The
// architecture's code programs them (arch_pmu_*); this keeps each thread's
// counts across its switches: started where it left off (as far as the
// counter is wide, which is what the thread reads itself), and at each
// switch out what it counted is added to its task's totals.
//
// A sampled counter (a sample_period) starts instead at minus the events
// left of its period, and interrupts as it overflows: pmu_overflow adds what
// it counted, writes a sample into the trace while the trace samples (the
// tick's records, tagged as the PMU's: ADR-0049 item 9), and starts it at
// minus a whole period again. Overflow is judged by the count, not by the
// vendors' status bits, so AMD's, Intel's and Arm's are alike.

static spinlock pmu_lock; // every task's configuration
static vx_pmu_info pmu_hw;
static bool pmu_probed;

// The shortest period: an interrupt every 10,000 events at most, so a
// period cannot turn a thread's time into interrupts.
static constexpr uint64_t PMU_MIN_PERIOD = 10'000;

static const vx_pmu_info *pmu_info(void) {
  if (!pmu_probed) arch_pmu_probe(&pmu_hw), pmu_probed = true; // the same on every CPU
  return &pmu_hw;
}

static uint64_t pmu_mask(void) { return pmu_hw.width >= 64 ? ~0ull : (1ull << pmu_hw.width) - 1; }

// What counter i of t counted since it started (now: the counter as read),
// added to t's and its task's; for a sampled counter, what is left of its
// period (a whole one again past an overflow not yet taken).
static uint64_t pmu_take(thread *t, uint32_t i, uint64_t now) {
  uint64_t d = (now - t->pmu_start[i]) & pmu_mask();
  t->pmu_value[i] += d;
  atomic_fetch_add_explicit(&t->task->pmu_total[i], d, memory_order_relaxed);
  t->pmu_start[i] = now & pmu_mask();
  if (t->pmu_period[i]) t->pmu_left[i] = d < t->pmu_left[i] ? t->pmu_left[i] - d : t->pmu_period[i];
  return d;
}

// Where counter i of t starts: its count, or minus what is left of its period.
static uint64_t pmu_origin(const thread *t, uint32_t i) {
  return (t->pmu_period[i] ? 0 - t->pmu_left[i] : t->pmu_value[i]) & pmu_mask();
}

// t's counters stopped, what they counted added to its own and its task's.
// Out of line, as pmu_in is: schedule calls pmu_switch deep in the kernel's
// paths, and their frames are reserved only when a task counts.
[[gnu::noinline]] static void pmu_out(thread *t) {
  if (!t->pmu_loaded) return;
  uint64_t now[VX_PMU_MAX];
  arch_pmu_read(t->pmu_loaded, now);
  arch_pmu_stop(t->pmu_loaded);
  for (uint32_t i = 0; i < t->pmu_loaded; i++) pmu_take(t, i, now[i]);
  t->pmu_loaded = 0;
}

// t's counters started, if its task has them: from its counts, or from 0
// under a configuration it has not run with.
[[gnu::noinline]] static void pmu_in(thread *t) {
  task *k = t->task;
  if (!k || !__atomic_load_n(&k->pmu.count, __ATOMIC_RELAXED)) return;
  uint32_t events[VX_PMU_MAX];
  spin_lock(&pmu_lock);
  uint32_t n = k->pmu.count;
  bool user_read = k->pmu.flags & VX_PMU_USER_READ;
  memcpy(events, k->pmu.events, sizeof events);
  if (t->pmu_gen != k->pmu.gen) {
    t->pmu_gen = k->pmu.gen;
    memset(t->pmu_value, 0, sizeof t->pmu_value);
    memcpy(t->pmu_period, k->pmu.period, sizeof t->pmu_period);
    memcpy(t->pmu_left, k->pmu.period, sizeof t->pmu_left);
  }
  spin_unlock(&pmu_lock);
  if (!n) return;
  uint32_t sampled = 0;
  for (uint32_t i = 0; i < n; i++) {
    t->pmu_start[i] = pmu_origin(t, i);
    if (t->pmu_period[i]) sampled |= 1u << i;
  }
  arch_pmu_start(n, events, t->pmu_start, sampled, user_read);
  t->pmu_loaded = n;
}

static inline void pmu_switch(thread *prev, thread *next) {
  if (prev->pmu_loaded) pmu_out(prev);
  if (next->task && __atomic_load_n(&next->task->pmu.count, __ATOMIC_RELAXED)) pmu_in(next);
}

// A counter overflowed (the architecture's interrupt, acknowledged after):
// the interrupted thread's sampled counters that did each give a sample,
// interrupted at pc with frame pointer fp, and start a period again.
[[gnu::noinline]] static void pmu_overflow(bool from_user, uint64_t pc, uint64_t fp) {
  thread *t = this_cpu()->current;
  if (t && t->pmu_loaded) {
    uint64_t now[VX_PMU_MAX];
    arch_pmu_read(t->pmu_loaded, now);
    for (uint32_t i = 0; i < t->pmu_loaded; i++) {
      if (!t->pmu_period[i] || ((now[i] - t->pmu_start[i]) & pmu_mask()) < t->pmu_left[i]) continue;
      pmu_take(t, i, now[i]);
      t->pmu_left[i] = t->pmu_period[i];
      t->pmu_start[i] = pmu_origin(t, i);
      arch_pmu_write(i, t->pmu_start[i]);
      uint64_t tag = 1ull << 62 | (uint64_t)t->task->pmu.events[i] << 48;
      if (atomic_load_explicit(&trace_mask, memory_order_relaxed) & VX_TC_SAMPLE)
        trace_sample(from_user, pc, fp, tag);
      if (t->task->samples) pmu_task_sample(t->task, from_user, pc, fp, tag);
    }
  }
  arch_pmu_ack();
}

// --- A task's own samples (7a3c1) ---
//
// The tick's, at the task's own rate on a CPU running one of its threads,
// and its counters' overflows, into a ring of its own: a VMO procfs gives
// (/proc/N/prof/samples), its pages committed, written through the direct
// map under the task's sample lock, so a SAMPLE's FRAMES follow it whatever
// CPU its other threads run on.

static uint64_t pmu_sample_ns(const task *k) {
  return k && k->samples ? atomic_load_explicit(&k->sample_ns, memory_order_relaxed) : 0;
}

static void pmu_ring_write(task *k, vx_pmu_ring *h, uint16_t kind, uint64_t a, uint64_t b) {
  uint64_t head = atomic_load_explicit(&h->head, memory_order_relaxed), at = 64 + (head % h->cap) * 32;
  uint64_t pa = vmo_page(k->samples, at / 4096);
  if (!pa) return; // not committed: refused when it was given, so never
  thread *t = this_cpu()->current;
  *(vx_trace_record *)((uint8_t *)phys_to_virt(pa) + at % 4096) =
      (vx_trace_record){.time = arch_counter(),
                        .kind = kind,
                        .cpu = (uint16_t)arch_cpu_index(),
                        .tid = trace_tid(t),
                        .a = a,
                        .b = b};
  atomic_store_explicit(&h->head, head + 1, memory_order_release);
}

[[gnu::noinline]] static void pmu_task_sample(task *k, bool from_user, uint64_t pc, uint64_t fp,
                                              uint64_t tag) {
  uint64_t ret[64];
  uint32_t n = trace_walk(from_user, fp, ret); // before the lock: it may fault, and recover
  spin_lock(&k->sample_lock);
  if (k->samples) {
    vx_pmu_ring *h = (vx_pmu_ring *)phys_to_virt(vmo_page(k->samples, 0));
    pmu_ring_write(k, h, VX_TK_SAMPLE, pc, n | tag | (from_user ? 1ull << 63 : 0));
    for (uint32_t i = 0; i < n; i += 2)
      pmu_ring_write(k, h, VX_TK_FRAMES, ret[i], i + 1 < n ? ret[i + 1] : 0);
  }
  spin_unlock(&k->sample_lock);
}

// VX_PMU_SAMPLES: the task's ring, or none.
static vx_status pmu_samples(task *k, const vx_pmu_samples *s) {
  vmo *v = nullptr;
  if (s->vmo != VX_HANDLE_NONE) {
    vx_status st;
    if (s->hz > 10'000) return VX_ERR_INVALID;
    v = (vmo *)handle_get(current_task(), s->vmo, OBJ_VMO, VX_RIGHT_WRITE, &st);
    if (!v) return st;
    bool ok =
        v->size >= 8192 && v->size <= 4ull << 20 && !v->physical && !v->pager && !v->lazy && !v->resizable;
    for (uint64_t i = 0; ok && i < v->size / 4096; i++) ok = vmo_page(v, i) != 0;
    if (!ok) {
      object_release(&v->obj);
      return VX_ERR_INVALID; // plain memory, all of it there, written through the direct map
    }
    vx_pmu_ring *h = (vx_pmu_ring *)phys_to_virt(vmo_page(v, 0));
    *h = (vx_pmu_ring){.magic = VX_PMU_RING_MAGIC,
                       .hz = s->hz ? s->hz : 1000,
                       .cap = (v->size - 64) / 32,
                       .counter_hz = clock.hz};
    atomic_store(&k->sample_ns, 1'000'000'000ull / h->hz);
  }
  spin_lock(&k->sample_lock);
  vmo *old = k->samples;
  k->samples = v; // the handle's reference, kept
  spin_unlock(&k->sample_lock);
  if (old) object_release(&old->obj);
  return VX_OK;
}

static vx_status pmu_set(task *k, const vx_pmu_config *c) {
  const vx_pmu_info *hw = pmu_info();
  if (!hw->counters) return VX_ERR_UNSUPPORTED;
  if (c->count > hw->counters || (c->flags & ~VX_PMU_USER_READ)) return VX_ERR_INVALID;
  for (uint32_t i = 0; i < c->count; i++) {
    if (c->events[i] < VX_PMU_CYCLES || c->events[i] > VX_PMU_BRANCH_MISSES) return VX_ERR_INVALID;
    if (!(hw->events & 1u << c->events[i])) return VX_ERR_UNSUPPORTED;
    uint64_t p = c->sample_period[i];
    if (p && (p < PMU_MIN_PERIOD || p > pmu_mask() / 2)) return VX_ERR_RANGE;
  }
  thread *me = this_cpu()->current;
  bool mine = me->task == k;
  if (mine) pmu_out(me); // what it counted so far goes with the old configuration
  spin_lock(&pmu_lock);
  k->pmu.gen++;
  k->pmu.count = c->count, k->pmu.flags = c->flags;
  memcpy(k->pmu.events, c->events, sizeof k->pmu.events);
  for (uint32_t i = 0; i < VX_PMU_MAX; i++) {
    k->pmu.period[i] = i < c->count ? c->sample_period[i] : 0;
    atomic_store(&k->pmu_total[i], 0);
  }
  spin_unlock(&pmu_lock);
  if (mine) pmu_in(me); // from now
  return VX_OK;
}

// pmu_configure(task, op, data, len): the task handle needs INSPECT.
static int64_t sys_pmu_configure(vx_handle th, uint64_t op, uint64_t data, uint64_t len) {
  vx_status st;
  task *k = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_INSPECT, &st);
  if (!k) return st;
  switch (op) {
  case VX_PMU_INFO:
    st = len == sizeof(vx_pmu_info) ? copy_to_user(data, pmu_info(), sizeof(vx_pmu_info)) : VX_ERR_INVALID;
    break;
  case VX_PMU_SET: {
    vx_pmu_config c;
    st = len == sizeof c ? copy_from_user(&c, data, sizeof c) : VX_ERR_INVALID;
    if (st == VX_OK) st = pmu_set(k, &c);
    break;
  }
  case VX_PMU_READ: {
    thread *me = this_cpu()->current;
    if (me->task == k && me->pmu_loaded) pmu_out(me), pmu_in(me); // the caller's own, up to now
    uint64_t v[VX_PMU_MAX];
    for (uint32_t i = 0; i < VX_PMU_MAX; i++)
      v[i] = atomic_load_explicit(&k->pmu_total[i], memory_order_relaxed);
    st = len == sizeof v ? copy_to_user(data, v, sizeof v) : VX_ERR_INVALID;
    break;
  }
  case VX_PMU_SAMPLES: {
    vx_pmu_samples s;
    st = len == sizeof s ? copy_from_user(&s, data, sizeof s) : VX_ERR_INVALID;
    if (st == VX_OK) st = pmu_samples(k, &s);
    break;
  }
  default: st = VX_ERR_INVALID;
  }
  object_release(&k->obj);
  return st;
}
