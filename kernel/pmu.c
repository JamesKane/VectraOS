// pmu.c: the hardware counters of a task's threads (ADR-0050, M7 step
// 7a3b1), user mode only, as Linux's per-task perf counters are and not as
// Fuchsia's perfmon is (system-wide, per CPU: lib/perfmon/perfmon.h). The
// architecture's code programs them (arch_pmu_*); this keeps each thread's
// counts across its switches: started where it left off (as far as the
// counter is wide, which is what the thread reads itself), and at each
// switch out what it counted is added to its task's totals.

static spinlock pmu_lock; // every task's configuration
static vx_pmu_info pmu_hw;
static bool pmu_probed;

static const vx_pmu_info *pmu_info(void) {
  if (!pmu_probed) arch_pmu_probe(&pmu_hw), pmu_probed = true; // the same on every CPU
  return &pmu_hw;
}

static uint64_t pmu_mask(void) { return pmu_hw.width >= 64 ? ~0ull : (1ull << pmu_hw.width) - 1; }

// t's counters stopped, what they counted added to its own and its task's.
static void pmu_out(thread *t) {
  if (!t->pmu_loaded) return;
  uint64_t now[VX_PMU_MAX];
  arch_pmu_read(t->pmu_loaded, now);
  arch_pmu_stop(t->pmu_loaded);
  for (uint32_t i = 0; i < t->pmu_loaded; i++) {
    uint64_t d = (now[i] - t->pmu_start[i]) & pmu_mask();
    t->pmu_value[i] += d;
    atomic_fetch_add_explicit(&t->task->pmu_total[i], d, memory_order_relaxed);
  }
  t->pmu_loaded = 0;
}

// t's counters started, if its task has them: from its counts, or from 0
// under a configuration it has not run with.
static void pmu_in(thread *t) {
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
  }
  spin_unlock(&pmu_lock);
  if (!n) return;
  for (uint32_t i = 0; i < n; i++) t->pmu_start[i] = t->pmu_value[i] & pmu_mask();
  arch_pmu_start(n, events, t->pmu_start, user_read);
  t->pmu_loaded = n;
}

static void pmu_switch(thread *prev, thread *next) {
  pmu_out(prev);
  pmu_in(next);
}

static vx_status pmu_set(task *k, const vx_pmu_config *c) {
  const vx_pmu_info *hw = pmu_info();
  if (!hw->counters) return VX_ERR_UNSUPPORTED;
  if (c->count > hw->counters || (c->flags & ~VX_PMU_USER_READ)) return VX_ERR_INVALID;
  for (uint32_t i = 0; i < c->count; i++) {
    if (c->events[i] < VX_PMU_CYCLES || c->events[i] > VX_PMU_BRANCH_MISSES) return VX_ERR_INVALID;
    if (!(hw->events & 1u << c->events[i]) || c->sample_period[i])
      return VX_ERR_UNSUPPORTED; // sampling: 7a3b2
  }
  thread *me = this_cpu()->current;
  bool mine = me->task == k;
  if (mine) pmu_out(me); // what it counted so far goes with the old configuration
  spin_lock(&pmu_lock);
  k->pmu.gen++;
  k->pmu.count = c->count, k->pmu.flags = c->flags;
  memcpy(k->pmu.events, c->events, sizeof k->pmu.events);
  for (uint32_t i = 0; i < VX_PMU_MAX; i++) atomic_store(&k->pmu_total[i], 0);
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
  default: st = VX_ERR_INVALID;
  }
  object_release(&k->obj);
  return st;
}
