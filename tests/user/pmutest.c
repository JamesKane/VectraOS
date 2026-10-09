// pmutest: a task's hardware counters through pmu_configure (ADR-0050, M7
// step 7a3b1), the pmu scenario's (tests/qemu/pmu.ndb). It counts cycles,
// and retired instructions where the PMU has them (QEMU's TCG counts them on
// aarch64 only with precise icount), over a spin of known length on this
// thread and on another, reads its own counter as a thread may (rdpmc,
// PMXEVCNTR), and is refused without INSPECT. Then overflow sampling
// (7a3b2): cycles sampled each 100,000 through /proc/trace (as adm), the
// samples the PMU's and nearly all in spin.

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

const char *vx_main(void) {
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

  vx_printf("pmutest: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}
