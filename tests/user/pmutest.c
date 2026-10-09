// pmutest: a task's hardware counters through pmu_configure (ADR-0050, M7
// step 7a3b1), the pmu scenario's (tests/qemu/pmu.ndb). It counts cycles,
// and retired instructions where the PMU has them (QEMU's TCG counts them on
// aarch64 only with precise icount), over a spin of known length on this
// thread and on another, reads its own counter as a thread may (rdpmc,
// PMXEVCNTR), and is refused without INSPECT.

#include "../../lib/vx-rt/rt.c"

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

  // No sampling yet (7a3b2); none without INSPECT; off.
  vx_pmu_config sampled = c;
  sampled.sample_period[0] = 100'000;
  CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &sampled, sizeof sampled) == VX_ERR_UNSUPPORTED);
  vx_handle weak = VX_HANDLE_NONE;
  CHECK(vx_handle_dup(vx_self, VX_RIGHT_TRANSFER, &weak) == VX_OK);
  CHECK(vx_pmu_configure(weak, VX_PMU_SET, &c, sizeof c) == VX_ERR_ACCESS);
  vx_pmu_config off = {};
  CHECK(vx_pmu_configure(vx_self, VX_PMU_SET, &off, sizeof off) == VX_OK);
  CHECK(vx_pmu_configure(vx_self, VX_PMU_READ, after, sizeof after) == VX_OK && after[0] == 0);

  vx_printf("pmutest: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}
