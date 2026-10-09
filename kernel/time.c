// time.c: the monotonic clock and the one-shot deadline timer (docs/01 §4.4, §8).
//
// The clock is the CPU's cycle counter (TSC, or the aarch64 virtual counter),
// read without a syscall and converted to nanoseconds exactly (time_math.c).
// The timer is one-shot: arch_timer_arm programs the next deadline as a counter
// value and its interrupt calls timer_interrupt. Hardware that counts down
// rather than comparing with the counter may interrupt early, so an interrupt
// before the deadline only re-arms. The kernel is tickless (01 §8): nothing
// fires unless a deadline is armed.

static void sched_timer(bool from_user, uint64_t pc, uint64_t fp); // sched/sched.c

static struct {
  uint64_t hz;         // counter frequency, published in /sys/clock/info (02 §5.1)
  uint64_t boot_count; // the counter at kernel entry: log timestamps count from here
} clock;

// Each CPU arms its own timer.
static struct {
  uint64_t armed;         // the armed deadline as a counter value; 0 if none
  _Atomic uint64_t fired; // how many deadlines have passed here
} cpu_timer[MAX_CPUS];

static void clock_init(uint64_t hz, uint64_t boot_count) {
  if (!hz || hz > 18'000'000'000) panic(VX_STR("the cycle counter's frequency is unknown, or past 18 GHz"));
  clock.hz = hz;
  clock.boot_count = boot_count;
}

static uint64_t counter_to_ns(uint64_t count) { return time_counter_to_ns(count, clock.hz); }

static uint64_t ns_to_counter(uint64_t ns) { return time_ns_to_counter(ns, clock.hz); }

// Nanoseconds on the one monotonic clock (01 §4.4).
static vx_instant clock_now(void) { return (vx_instant)counter_to_ns(arch_counter()); }

// The wall clock: UTC's offset from the monotonic clock, set by clock_set
// (ADR-0031). Read with the flag, each atomically: a reader sees an offset
// that was set, or none.
static _Atomic int64_t utc_offset;
static _Atomic bool utc_set;

static void clock_set_utc(int64_t utc) {
  atomic_store(&utc_offset, utc - clock_now());
  atomic_store(&utc_set, true);
}

// Arms the timer for an absolute deadline on the monotonic clock.
static void timer_arm(vx_instant deadline) {
  uint64_t count = ns_to_counter((uint64_t)deadline);
  cpu_timer[arch_cpu_index()].armed = count ? count : 1;
  arch_timer_arm(cpu_timer[arch_cpu_index()].armed);
}

// Called by the architecture's timer interrupt, with the interrupt
// acknowledged; from_user: it came while the CPU was in user mode, at pc
// with frame pointer fp (for sampling, 20 §6).
static void timer_interrupt(bool from_user, uint64_t pc, uint64_t fp) {
  uint32_t i = arch_cpu_index();
  if (!cpu_timer[i].armed) return;
  if (arch_counter() < cpu_timer[i].armed) { // early: a countdown ran out first
    arch_timer_arm(cpu_timer[i].armed);
    return;
  }
  cpu_timer[i].armed = 0;
  cpu_timer[i].fired++;
  sched_timer(from_user, pc, fp);
}

// The log prefix: "[    s.mmm] ", seconds since kernel entry.
static void kput_stamp(void) {
  uint64_t ms = clock.hz ? counter_to_ns(arch_counter() - clock.boot_count) / 1000000 : 0;
  char buf[16] = "[    0.000] ";
  uint64_t s = ms / 1000;
  buf[7] = (char)('0' + ms % 1000 / 100);
  buf[8] = (char)('0' + ms % 100 / 10);
  buf[9] = (char)('0' + ms % 10);
  for (int i = 5; i >= 1 && (s || i == 5); i--, s /= 10) buf[i] = (char)('0' + s % 10);
  console_emit((vx_str){buf, 12});
}
