// pmu.h: the hardware counters (ADR-0050, M7 step 7a3b), declared before
// the scheduler, which calls pmu_switch as it switches threads; pmu.c,
// after the syscalls, has them.

struct thread;
static void pmu_switch(struct thread *prev, struct thread *next);
static int64_t sys_pmu_configure(vx_handle th, uint64_t op, uint64_t data, uint64_t len);
