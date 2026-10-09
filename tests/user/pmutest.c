// pmutest: a task's hardware counters through pmu_configure (ADR-0050, M7
// step 7a3b1), the pmu scenario's (tests/qemu/pmu.ndb). It counts cycles,
// and retired instructions where the PMU has them (QEMU's TCG counts them on
// aarch64 only with precise icount), over a spin of known length on this
// thread and on another, reads its own counter as a thread may (rdpmc,
// PMXEVCNTR), and is refused without INSPECT. Then overflow sampling
// (7a3b2): cycles sampled each 100,000 through /proc/trace (as adm), the
// samples the PMU's and nearly all in spin. With "own" (7a3c1, as an
// child of pmutest's): its own samples through /proc/N/prof, the tick's and
// then a counter's, and its counters' file.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("pmutest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static constexpr uint64_t SPIN = 10'000'000;

// n rounds of a few instructions each: at least 3 retired a round.
[[gnu::noinline]] static uint64_t spin(uint64_t n) {
  volatile uint64_t x = 1;
  for (uint64_t i = 0; i < n; i++) x = x * 6'364'136'223'846'793'005ull + 1;
  return x;
}

static const char *worker(void *arg) {
  (void)arg;
  spin(2 * SPIN);
  return nullptr;
}

// Counter i as the thread reads it itself.
static uint64_t own(uint32_t i) {
#ifdef __x86_64__
  uint32_t lo, hi;
  __asm__ volatile("rdpmc" : "=a"(lo), "=d"(hi) : "c"(i));
  return (uint64_t)hi << 32 | lo;
#else
  uint64_t v; // PMUSERENR_EL0.ER lets a thread select and read
  __asm__ volatile("msr pmselr_el0, %1\n\tisb\n\tmrs %0, pmxevcntr_el0" : "=r"(v) : "r"((uint64_t)i));
  return v;
#endif
}

static vx_status ctl(const char *cmd) { return vx_ctl(VX_STR("/proc/trace/ctl"), "%s", cmd); }

// Cycles sampled each `period` over a spin: how many of this task's
// samples the PMU wrote, and how many of those were in spin.
static void sampling(void) {
  static constexpr uint64_t PERIOD = 100'000;
  vx_pmu_config c = {.count = 1, .events = {VX_PMU_CYCLES}, .sample_period = {PERIOD}};
  vx_pmu_config tiny = c;
  tiny.sample_period[0] = 100;
  CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &tiny, sizeof tiny) == VX_ERR_RANGE); // an interrupt storm
  CHECK(ctl("start sample rate 1 size 4M") == VX_OK); // the tick's samples: next to none
  CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &c, sizeof c) == VX_OK);
  spin(SPIN);
  uint64_t v[VX_PMU_MAX];
  CHECK(vx_pmu_configure(vx_self, VX_PMU_READ, v, sizeof v) == VX_OK);
  CHECK(ctl("stop") == VX_OK);
  vx_pmu_config off = {};
  vx_pmu_configure(vx_self, VX_PMU_SET, &off, sizeof off);

  vx_arena *a = vx_arena_new(40 << 20);
  vx_trace_record *r = vx_push(a, 32 << 20, 32);
  vx_fd ev = vx_open(VX_STR("/proc/trace/events"), VX_OREAD);
  size_t bytes = 0;
  int64_t got;
  while (ev >= 0 && r && (got = vx_read(ev, (vx_bytes){(uint8_t *)r + bytes, (32 << 20) - bytes})) > 0)
    bytes += (size_t)got;
  vx_close(ev);
  vx_task_summary me;
  vx_task_info(vx_self, &me);
  uint64_t from = (uint64_t)(uintptr_t)&spin;
  uint32_t pmu = 0, inside = 0;
  for (size_t i = 0; r && i < bytes / sizeof *r; i++) {
    if (r[i].kind != VX_TK_SAMPLE || r[i].tid >> 12 != me.id || !(r[i].b >> 62 & 1)) continue;
    pmu++;
    inside += r[i].a >= from && r[i].a < from + 512 && (r[i].b >> 48 & 0xff) == VX_PMU_CYCLES;
  }
  vx_printf("pmutest: %llu cycles sampled, %u PMU samples, %u in spin\n", (unsigned long long)v[0], pmu,
            inside);
  CHECK(v[0] >= SPIN);
  // One a period on hardware and KVM; TCG's cycles run on virtual time and
  // its overflow interrupts come late on a loaded host, each late one a
  // period's start lost: a quarter, then.
  CHECK(pmu >= v[0] / PERIOD / 4);
  CHECK(inside * 10 >= pmu * 9);
  vx_arena_free(a);
}

// The samples in /proc/<me>/prof/samples: how many of them, how many in
// spin, how many the PMU's and how many of those in spin.
static void own_samples(vx_str path, uint32_t *all, uint32_t *inside, uint32_t *pmu, uint32_t *pmu_inside) {
  static uint8_t buf[1 << 20];
  vx_fd f = vx_open(path, VX_OREAD);
  size_t bytes = 0;
  int64_t got;
  while (f >= 0 && (got = vx_read(f, (vx_bytes){buf + bytes, sizeof buf - bytes})) > 0) bytes += (size_t)got;
  vx_close(f);
  *all = *inside = *pmu = *pmu_inside = 0;
  const vx_pmu_ring *h = (const vx_pmu_ring *)buf;
  CHECK(bytes >= sizeof *h && h->magic == VX_PMU_RING_MAGIC);
  uint64_t from = (uint64_t)(uintptr_t)&spin;
  for (size_t at = sizeof *h; at + sizeof(vx_trace_record) <= bytes; at += sizeof(vx_trace_record)) {
    vx_trace_record r;
    memcpy(&r, buf + at, sizeof r);
    if (r.kind != VX_TK_SAMPLE) continue;
    bool in = r.a >= from && r.a < from + 512, by_pmu = r.b >> 62 & 1;
    (*all)++, *inside += in, *pmu += by_pmu, *pmu_inside += in && by_pmu;
  }
}

static const char *own_mode(void) {
  vx_arena *a = vx_arena_new(1 << 20);
  unsigned long long me = vx_pid();
  vx_str ctlp = vx_fmt(a, "/proc/%llu/prof/ctl", me), samp = vx_fmt(a, "/proc/%llu/prof/samples", me);
  vx_str cntp = vx_fmt(a, "/proc/%llu/prof/counters", me);
  uint32_t all, inside, pmu, pmu_inside;

  // The tick's, at 2 kHz over a spin of some 200 ms.
  CHECK(vx_ctl(ctlp, "sample 2000") == VX_OK);
  vx_instant until = vx_now() + 200'000'000;
  while (vx_now() < until) spin(SPIN / 20);
  own_samples(samp, &all, &inside, &pmu, &pmu_inside);
  vx_printf("pmuown: %u tick samples, %u in spin\n", all, inside);
  CHECK(all >= 100 && inside * 10 >= all * 8 && pmu == 0);

  // A counter's, each 100,000 cycles, into a fresh ring (the tick's at 1 Hz).
  vx_pmu_info info = {};
  if (vx_pmu_configure(vx_self, VX_PMU_INFO, &info, sizeof info) == VX_OK && info.counters) {
    CHECK(vx_ctl(ctlp, "sample 1") == VX_OK);
    CHECK(vx_ctl(ctlp, "count cycles period 100000") == VX_OK);
    spin(SPIN);
    char text[256];
    vx_fd f = vx_open(cntp, VX_OREAD);
    int64_t n = f >= 0 ? vx_read(f, (vx_bytes){(uint8_t *)text, sizeof text - 1}) : -1;
    vx_close(f);
    CHECK(n > 0 && vx_str_find((vx_str){text, (size_t)n}, VX_STR("event=cycles count=")) == 0);
    CHECK(vx_ctl(ctlp, "count off") == VX_OK); // before the samples are read: not of the reading
    own_samples(samp, &all, &inside, &pmu, &pmu_inside);
    vx_printf("pmuown: %u PMU samples, %u in spin\n", pmu, pmu_inside);
    // TCG's overflow interrupts may come late on a loaded host, past spin's end.
    CHECK(pmu >= 20 && pmu_inside * 4 >= pmu * 3);
  }
  CHECK(vx_ctl(ctlp, "sample off") == VX_OK);
  CHECK(vx_ctl(ctlp, "sample 20000") == VX_ERR_INVALID); // past 10 kHz
  vx_arena_free(a);
  vx_printf("pmuown: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}

const char *vx_main(void) {
  if (vx_str_eq(vx_arg(1), VX_STR("own"))) return own_mode();
  vx_pmu_info info = {};
  CHECK(vx_pmu_configure(vx_self, VX_PMU_INFO, &info, sizeof info) == VX_OK);
  vx_printf("pmutest: %u counters of %u bits, events 0x%x\n", info.counters, info.width, info.events);
  if (!info.counters) { // no PMU: nothing to count, and SET says so
    vx_pmu_config none = {.count = 1, .events = {VX_PMU_CYCLES}};
    CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &none, sizeof none) == VX_ERR_UNSUPPORTED);
    vx_printf("pmutest: %u checks, %u failed\n", checks, failures);
    return failures ? "failed" : nullptr;
  }
  bool instr = info.events & 1u << VX_PMU_INSTRUCTIONS;
  uint64_t mask = info.width >= 64 ? ~0ull : (1ull << info.width) - 1;
  CHECK(info.events & 1u << VX_PMU_CYCLES);

  vx_pmu_config c = {
      .count = instr ? 2 : 1, .flags = VX_PMU_USER_READ, .events = {VX_PMU_CYCLES, VX_PMU_INSTRUCTIONS}};
  CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &c, sizeof c) == VX_OK);

  // This thread's spin, read as the thread reads its own.
  uint64_t c0 = own(0), i0 = instr ? own(1) : 0;
  spin(SPIN);
  uint64_t c1 = own(0), i1 = instr ? own(1) : 0;
  vx_printf("pmutest: own spin: %llu cycles, %llu instructions\n", (unsigned long long)((c1 - c0) & mask),
            (unsigned long long)((i1 - i0) & mask));
  CHECK(((c1 - c0) & mask) >= SPIN);
  CHECK(!instr || ((i1 - i0) & mask) >= 3 * SPIN);

  // Another thread's: the task's totals have it once it has ended.
  uint64_t before[VX_PMU_MAX], after[VX_PMU_MAX];
  CHECK(vx_pmu_configure(vx_self, VX_PMU_READ, before, sizeof before) == VX_OK);
  vx_thread *t = vx_thread_spawn(worker, nullptr, 0, 0);
  CHECK(t && vx_thread_join(t, nullptr, nullptr) == VX_OK);
  CHECK(vx_pmu_configure(vx_self, VX_PMU_READ, after, sizeof after) == VX_OK);
  vx_printf("pmutest: totals: %llu cycles, %llu instructions\n", (unsigned long long)after[0],
            (unsigned long long)after[1]);
  CHECK(after[0] - before[0] >= 2 * SPIN);
  CHECK(!instr || after[1] - before[1] >= 6 * SPIN);

  // None without INSPECT; off.
  vx_handle weak = VX_HANDLE_NONE;
  CHECK(vx_handle_dup(vx_self, VX_RIGHT_TRANSFER, &weak) == VX_OK);
  CHECK(vx_pmu_configure(weak, VX_PMU_SET, &c, sizeof c) == VX_ERR_ACCESS);
  vx_pmu_config off = {};
  CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &off, sizeof off) == VX_OK);
  CHECK(vx_pmu_configure(vx_self, VX_PMU_READ, after, sizeof after) == VX_OK && after[0] == 0);
  sampling();

  // One task's own samples (7a3c1): itself again, as a child, through its /proc/N/prof.
  vx_str args[] = {VX_STR("pmutest"), VX_STR("own")};
  vx_spawn_req req = {.path = vx_exe_path(), .args = {args, 2}};
  vx_proc kid = {};
  vx_arena *ka = vx_arena_new(1 << 16);
  vx_str why = VX_STR("unset");
  CHECK(vx_proc_spawn(&req, &kid) == VX_OK && vx_proc_wait(kid, VX_INFINITE, ka, &why) == VX_OK &&
        why.len == 0);
  vx_arena_free(ka);

  vx_printf("pmutest: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}
