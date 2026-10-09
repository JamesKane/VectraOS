// trace.h: the kernel's trace probes (20 §4, ADR-0049, M7 step 7a1),
// included before the code that uses them; trace.c, after the scheduler,
// writes the records.
//
// A probe is one relaxed load of the category mask and a branch; its
// arguments are evaluated only past it. Every kernel has them, and a
// disabled one costs nothing measurable (20 §8).

static _Atomic uint32_t trace_mask; // the categories being written (trace.c)

static void trace_write(uint16_t kind, uint64_t a, uint64_t b);

#define TRACE(cat, kind, a, b)                                                                               \
  do {                                                                                                       \
    if (atomic_load_explicit(&trace_mask, memory_order_relaxed) & (cat))                                     \
      trace_write((kind), (uint64_t)(a), (uint64_t)(b));                                                     \
  } while (0)

// Sampling (20 §6, M7 step 7a3a): with VX_TC_SAMPLE, the scheduler's timer
// calls trace_sample on a busy CPU every trace_sample_ns.
static _Atomic uint64_t trace_sample_ns;
static void trace_sample(bool from_user, uint64_t pc, uint64_t fp, uint64_t tag);
static uint32_t trace_walk(bool from_user, uint64_t fp, uint64_t ret[64]);

static int64_t sys_trace_configure(vx_handle rh, uint64_t op, uint64_t data, uint64_t len);

// A thread as a record names it: its task's id << 12 | its id in the task.
struct thread;
static uint32_t trace_tid(const struct thread *t);
