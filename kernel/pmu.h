// pmu.h: the hardware counters (ADR-0050, M7 step 7a3b), declared before
// the scheduler, which calls pmu_switch as it switches threads; pmu.c,
// after the syscalls, has them.

struct thread;
static inline void pmu_switch(struct thread *prev, struct thread *next);
static void pmu_out(struct thread *t); // its counters stopped and taken: at a switch, and at its exit
static void pmu_overflow(bool from_user, uint64_t pc, uint64_t fp); // the PMU's interrupt
// A task's own samples (7a3c1): its period if it takes them (0: not), and one
// written into its ring (the scheduler's tick, the PMU's overflow).
struct task;
static uint64_t pmu_sample_ns(const struct task *k);
static void pmu_task_sample(struct task *k, bool from_user, uint64_t pc, uint64_t fp, uint64_t tag);
static int64_t sys_pmu_configure(vx_handle th, uint64_t op, uint64_t data, uint64_t len);
